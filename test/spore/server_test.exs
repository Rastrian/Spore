defmodule Spore.ServerTest do
  @moduledoc """
  Socket-cleanup tests for `Spore.Server` control connections.

  `handle_connection/4` used to return `:ok` on its failure paths (eof,
  timeout, decode error, unexpected message, refused Hello) without closing
  the control socket, leaving cleanup to port GC. Under a storm of doomed
  connections — clients retrying against a server that dropped their tunnel —
  that piles sockets up in CLOSE-WAIT and leaks FDs (observed 3844 in
  production on 2026-08-31, after repeated {:error, :emfile} from accept).

  The observable contract tested here: from the moment the server gives up on
  a control connection, the peer must see a FIN — `recv/3` on the client side
  returns {:error, :closed} instead of timing out. Everything runs against a
  real server over loopback, one `:gen_tcp` socket per scenario.
  """

  use ExUnit.Case, async: false

  alias Spore.Shared.Delimited

  setup do
    Application.stop(:spore)

    start_supervised!({Registry, keys: :unique, name: Spore.Pending.Registry})

    start_supervised!({DynamicSupervisor, name: Spore.Pending.Supervisor, strategy: :one_for_one})

    start_supervised!(Spore.Pending)
    start_supervised!(Spore.Limits)
    start_supervised!(Spore.Banlist)
    start_supervised!(Spore.SecretQuota)
    start_supervised!(Spore.Active)
    start_supervised!(Spore.Metrics)

    {:ok, probe} = :gen_tcp.listen(0, [:binary, active: false, packet: 0, reuseaddr: true])
    {:ok, port} = :inet.port(probe)
    :gen_tcp.close(probe)

    Application.put_env(:spore, :control_port, port)
    on_exit(fn -> Application.delete_env(:spore, :control_port) end)

    server =
      Task.async(fn ->
        Spore.Server.listen(bind_addr: "127.0.0.1", min_port: 10_000, max_port: 20_000)
      end)

    # on_exit runs outside the test process, so Task.shutdown/2 is not allowed
    # (ownership); kill the server task by pid instead — a process blocked in
    # :gen_tcp.accept/1 is interruptible.
    on_exit(fn -> Process.exit(server.pid, :kill) end)

    {:ok, port: port}
  end

  # The server task binds its port asynchronously, so retry briefly until the
  # listen socket is up instead of racing it.
  defp connect(port, tries \\ 40)

  defp connect(_port, 0), do: flunk("server did not start listening")

  defp connect(port, tries) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: 0], 200) do
      {:ok, sock} ->
        sock

      {:error, _reason} ->
        Process.sleep(50)
        connect(port, tries - 1)
    end
  end

  # A FIN from the server is the whole assertion: {:error, :closed} means the
  # socket was really closed (no CLOSE-WAIT); {:error, :timeout} means it was
  # abandoned to GC — the leak.
  defp assert_closed_by_server(sock) do
    assert {:error, :closed} = :gen_tcp.recv(sock, 0, 2_000)
  end

  describe "handle_connection/4 cleanup" do
    test "closes the socket when the first message is not JSON", %{port: port} do
      sock = connect(port)

      :ok = :gen_tcp.send(sock, "this is not json\x00")
      assert_closed_by_server(sock)
    end

    test "closes the socket when the client sends nothing at all", %{port: port} do
      sock = connect(port)

      # The server's handshake read times out (network_timeout_ms = 3000);
      # that return path must close the socket, not leak it.
      assert {:error, :closed} = :gen_tcp.recv(sock, 0, 5_000)
    end

    test "closes the socket after refusing an out-of-range Hello", %{port: port} do
      sock = connect(port)
      d = Delimited.new(sock, :gen_tcp)

      {:ok, d2} = Delimited.send(d, %{"Hello" => 55_555})

      assert {%{"Error" => message}, _d3} = Delimited.recv(d2, 2_000)
      assert message =~ "not in allowed range"

      # The Error frame is sent, then the connection must be torn down —
      # this is the path the storm of retrying clients hammers.
      assert_closed_by_server(sock)
    end

    test "keeps accepting after a run of doomed connections", %{port: port} do
      for _ <- 1..5 do
        sock = connect(port)
        :ok = :gen_tcp.send(sock, ~s({"Unknown": 1}\x00))
        assert_closed_by_server(sock)
      end

      # The accept loop survived the garbage, and the 6th connection is
      # served by a fresh handler just like the first.
      sock = connect(port)
      :ok = :gen_tcp.send(sock, "also not json\x00")
      assert_closed_by_server(sock)
    end
  end

  describe "a healthy control session" do
    test "still hands out a tunnel port, heartbeats, and releases the listener", %{port: port} do
      sock = connect(port)
      d = Delimited.new(sock, :gen_tcp)

      # Port 0 asks the server to pick one inside 10_000..20_000.
      {:ok, d2} = Delimited.send(d, %{"Hello" => 0})
      {%{"Hello" => tunnel_port}, d3} = Delimited.recv(d2, 2_000)
      assert tunnel_port in 10_000..20_000

      # The control connection must stay warm: heartbeats every 500ms.
      assert {"Heartbeat", _d4} = Delimited.recv(d3, 2_000)

      # The tunnel listener is live...
      {:ok, data_sock} =
        :gen_tcp.connect(~c"127.0.0.1", tunnel_port, [:binary, active: false, packet: 0], 2_000)

      :ok = :gen_tcp.close(data_sock)

      # ...and is released again once the control connection goes away.
      :ok = :gen_tcp.close(sock)
      assert eventually_refused(~c"127.0.0.1", tunnel_port, 5_000)
    end

    test "Accept pipes a claimed tunnel connection end to end", %{port: port} do
      # Control connection A registers the tunnel and is told about the
      # incoming data connection (the id it must claim).
      sock_a = connect(port)
      d = Delimited.new(sock_a, :gen_tcp)
      {:ok, d2} = Delimited.send(d, %{"Hello" => 0})
      {%{"Hello" => tunnel_port}, d3} = Delimited.recv(d2, 2_000)

      {:ok, data_sock} =
        :gen_tcp.connect(~c"127.0.0.1", tunnel_port, [:binary, active: false, packet: 0], 2_000)

      assert id = recv_until_connection(d3, 2_000)

      # A second control connection claims it with Accept; from then on the
      # two sockets are piped together.
      sock_b = connect(port)
      db = Delimited.new(sock_b, :gen_tcp)
      {:ok, _db2} = Delimited.send(db, %{"Accept" => id})

      assert ping_roundtrip(sock_b, data_sock, 5)

      # Dropping the claiming control connection tears the pipe down on both
      # sides — including the server-side close of the control socket.
      :ok = :gen_tcp.close(sock_b)
      assert {:error, :closed} = :gen_tcp.recv(data_sock, 0, 5_000)
    end
  end

  # Heartbeats (every 500ms) race against the Connection frame announcing an
  # accepted tunnel connection; skip them until it arrives.
  defp recv_until_connection(d, timeout) do
    case Delimited.recv(d, timeout) do
      {"Heartbeat", d2} ->
        recv_until_connection(d2, timeout)

      {%{"Connection" => id}, _d2} ->
        id
    end
  end

  # The Accept frame and the ping behind it must not be merged into the same
  # read on the server (anything buffered behind Accept is dropped by
  # design), so retry the ping until the pipe is up.
  defp ping_roundtrip(_sock_b, _data_sock, 0), do: flunk("pipe never forwarded the ping")

  defp ping_roundtrip(sock_b, data_sock, tries) do
    :ok = :gen_tcp.send(sock_b, "ping")

    case :gen_tcp.recv(data_sock, 4, 400) do
      {:ok, "ping"} ->
        true

      {:error, :timeout} ->
        ping_roundtrip(sock_b, data_sock, tries - 1)
    end
  end

  # Poll until connecting to host:port is refused — the listener was closed.
  defp eventually_refused(host, port, timeout) do
    poll_until_refused(host, port, System.monotonic_time(:millisecond) + timeout)
  end

  defp poll_until_refused(host, port, deadline) do
    case :gen_tcp.connect(host, port, [:binary, active: false, packet: 0], 200) do
      {:ok, sock} ->
        :gen_tcp.close(sock)

        if System.monotonic_time(:millisecond) >= deadline do
          false
        else
          Process.sleep(100)
          poll_until_refused(host, port, deadline)
        end

      {:error, :econnrefused} ->
        true
    end
  end
end
