defmodule Spore.ClientHeartbeatTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Spore.Shared.Delimited

  @moduledoc """
  Heartbeat-liveness tests for the client control loop.

  A control connection that dies without a FIN/RST ever reaching the client
  (NAT/conntrack flush, silent host loss) looks perfectly healthy locally:
  `recv` just blocks forever, so neither the eof nor the error clause that
  trigger `reconnect/3` can ever fire — `--retry` becomes a no-op in exactly
  the scenario it exists for.

  These tests reproduce that half-open state with a fake server that answers
  the Hello handshake and then goes SILENT: the socket stays open, nothing is
  ever written to it. The real server heartbeats every 500ms, so the client
  must treat sustained silence as a dead connection and either reconnect
  (retry on) or return an error (retry off) instead of blocking forever.
  """

  @assigned_port 40_321

  setup do
    on_exit(fn ->
      Application.delete_env(:spore, :retry)
      Application.delete_env(:spore, :retry_delay_ms)
      Application.delete_env(:spore, :max_retry_delay_ms)
      Application.delete_env(:spore, :heartbeat_timeout_ms)
      Application.delete_env(:spore, :control_port)
    end)

    {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, packet: 0, reuseaddr: true])
    {:ok, port} = :inet.port(lsock)

    # The client dials Shared.control_port(); point it at the fake server.
    Application.put_env(:spore, :control_port, port)

    parent = self()
    server = Task.async(fn -> fake_server(lsock, parent) end)

    on_exit(fn -> send(server.pid, :stop) end)

    %{port: port, server: server.pid}
  end

  # Accept loop: answer every Hello, then hold the connection open without
  # ever sending a heartbeat — the client side cannot distinguish this from a
  # NAT-flushed server.
  defp fake_server(lsock, owner) do
    receive do
      :stop -> :ok
    after
      0 -> :ok
    end

    case :gen_tcp.accept(lsock, 5_000) do
      {:ok, sock} ->
        d = Delimited.new(sock, :gen_tcp)

        case Delimited.recv(d, 2_000) do
          {%{"Hello" => _port}, d2} ->
            {:ok, _d3} = Delimited.send(d2, %{"Hello" => @assigned_port})
            send(owner, {:hello_served, make_ref()})

          # Deliberately no heartbeats and no close: stay silent forever.

          {%{"HelloEx" => _}, d2} ->
            {:ok, _d3} = Delimited.send(d2, %{"HelloEx" => %{"port" => @assigned_port}})
            send(owner, {:hello_served, make_ref()})

          _ ->
            :gen_tcp.close(sock)
        end

        fake_server(lsock, owner)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        fake_server(lsock, owner)
    end
  end

  describe "listen/1 with a silent (half-open) control connection" do
    test "with retry: detects the dead connection and reconnects" do
      Application.put_env(:spore, :retry, true)
      Application.put_env(:spore, :retry_delay_ms, 20)
      Application.put_env(:spore, :max_retry_delay_ms, 60)
      Application.put_env(:spore, :heartbeat_timeout_ms, 150)

      {:ok, client} = Spore.Client.new("127.0.0.1", 25565, "127.0.0.1", 0, nil)
      assert client.remote_port == @assigned_port

      # First handshake was served by the fake server.
      assert_receive {:hello_served, _}, 2_000

      task =
        Task.async(fn ->
          capture_log(fn -> Spore.Client.listen(client) end)
        end)

      # The fake server never sends a heartbeat, so the initial connection
      # must be declared dead and a NEW handshake completed against a fresh
      # connection — this is the proof the retry loop handles half-open
      # sockets, not just ones that produce an eof/error.
      assert_receive {:hello_served, _}, 3_000

      # ...and the control loop must still be running (listen never returned).
      ref = Process.monitor(task.pid)
      refute_receive {:DOWN, ^ref, :process, _, _}, 300

      Task.shutdown(task, :brutal_kill)
    end

    test "without retry: returns {:error, :heartbeat_timeout} instead of hanging" do
      Application.delete_env(:spore, :retry)
      Application.put_env(:spore, :heartbeat_timeout_ms, 150)

      {:ok, client} = Spore.Client.new("127.0.0.1", 25565, "127.0.0.1", 0, nil)
      assert_receive {:hello_served, _}, 2_000

      parent = self()

      task =
        Task.async(fn ->
          # capture_log/1 only returns the log, so forward the actual return
          # value of listen/1 out of the fun.
          capture_log(fn -> send(parent, {:listen_result, Spore.Client.listen(client)}) end)
        end)

      # Without --retry the loop must RETURN with an error once heartbeats
      # stop, not block forever on a socket that will never speak again.
      assert_receive {:listen_result, {:error, :heartbeat_timeout}}, 3_000

      Task.shutdown(task)
    end
  end
end
