defmodule Spore.ClientRetryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Spore.Shared.Delimited

  @moduledoc """
  Functional tests for the client retry loop, against a real TCP server.

  The fake server implements just enough of the bore control protocol to run
  a client: it answers Hello with an assigned port and keeps the control
  connection warm with heartbeats. The test sends it :drop to kill the
  connection; after each successful handshake the server notifies the test
  with {:hello_served, n}, which is how reconnections are proven.
  """

  @assigned_port 40_123

  setup do
    on_exit(fn ->
      Application.delete_env(:spore, :retry)
      Application.delete_env(:spore, :retry_delay_ms)
      Application.delete_env(:spore, :max_retry_delay_ms)
      Application.delete_env(:spore, :last_secret)
      Application.delete_env(:spore, :control_port)
    end)

    {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, packet: 0, reuseaddr: true])
    {:ok, port} = :inet.port(lsock)

    # The client dials Shared.control_port(); point it at the fake server.
    Application.put_env(:spore, :control_port, port)

    parent = self()
    server = Task.async(fn -> fake_server(lsock, parent) end)

    on_exit(fn ->
      send(server.pid, :stop)
    end)

    %{port: port, server: server.pid}
  end

  # Accept loop: one control connection at a time, forever (until :stop).
  defp fake_server(lsock, owner) do
    receive do
      :stop -> :ok
    after
      0 -> :ok
    end

    case :gen_tcp.accept(lsock, 5_000) do
      {:ok, sock} ->
        _ = serve_control(sock, owner)
        fake_server(lsock, owner)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        fake_server(lsock, owner)
    end
  end

  defp serve_control(sock, owner) do
    d = Delimited.new(sock, :gen_tcp)

    case answer_hello(d) do
      {:ok, _d} ->
        send(owner, {:hello_served, make_ref()})

        case wait_for_drop(sock) do
          :dropped ->
            :gen_tcp.close(sock)
            :dropped

          :stop ->
            :gen_tcp.close(sock)
            :stopped
        end

      :error ->
        :gen_tcp.close(sock)
        :error
    end
  end

  defp wait_for_drop(sock) do
    receive do
      :drop ->
        :dropped

      :stop ->
        :stop
    after
      150 ->
        _ = :gen_tcp.send(sock, ~s("Heartbeat"\x00))
        wait_for_drop(sock)
    end
  end

  defp answer_hello(d) do
    case Delimited.recv(d, 2_000) do
      {%{"Hello" => _port}, d2} ->
        {:ok, d3} = Delimited.send(d2, %{"Hello" => @assigned_port})
        {:ok, d3}

      {%{"HelloEx" => _}, d2} ->
        {:ok, d3} = Delimited.send(d2, %{"HelloEx" => %{"port" => @assigned_port}})
        {:ok, d3}

      _ ->
        :error
    end
  end

  describe "--retry application env" do
    test "CLI --retry and --retry-delay-ms set the application env" do
      Spore.CLI.apply_local_opts(["3000", "--to", "h", "--retry", "--retry-delay-ms", "750"])

      assert Application.get_env(:spore, :retry) == true
      assert Application.get_env(:spore, :retry_delay_ms) == 750
    end

    test "the CLI stores the secret for the reconnect path" do
      Spore.CLI.apply_local_opts(["3000", "--to", "h", "--secret", "topsecret"])

      assert Application.get_env(:spore, :last_secret) == "topsecret"
    end
  end

  describe "listen/1" do
    test "with retry: reconnects after the server drops the control connection", %{
      server: server
    } do
      Application.put_env(:spore, :retry, true)
      Application.put_env(:spore, :retry_delay_ms, 20)
      Application.put_env(:spore, :max_retry_delay_ms, 60)

      {:ok, client} = Spore.Client.new("127.0.0.1", 25565, "127.0.0.1", 0, nil)
      assert client.remote_port == @assigned_port

      # First handshake was served by the fake server.
      assert_receive {:hello_served, _}, 2_000

      task =
        Task.async(fn ->
          capture_log(fn -> Spore.Client.listen(client) end)
        end)

      Process.sleep(80)
      send(server, :drop)

      # The reconnect must complete a NEW handshake against the fresh
      # connection — this is the actual proof the retry loop works.
      assert_receive {:hello_served, _}, 3_000

      # ...and the control loop must still be running (listen never returned).
      ref = Process.monitor(task.pid)
      refute_receive {:DOWN, ^ref, :process, _, _}, 300

      Task.shutdown(task, :brutal_kill)
    end

    test "without retry: returns on connection loss", %{server: server} do
      Application.delete_env(:spore, :retry)

      {:ok, client} = Spore.Client.new("127.0.0.1", 25565, "127.0.0.1", 0, nil)
      assert_receive {:hello_served, _}, 2_000

      task =
        Task.async(fn ->
          capture_log(fn -> Spore.Client.listen(client) end)
        end)

      Process.sleep(80)
      send(server, :drop)

      # listen/1 returns and the task finishes normally.
      assert is_binary(Task.await(task, 3_000))
    end
  end
end
