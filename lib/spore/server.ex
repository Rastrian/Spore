defmodule Spore.Server do
  @moduledoc """
  Server implementation for the `bore` protocol in Elixir.
  """

  require Logger

  alias Spore.Shared
  alias Spore.Shared.Delimited
  alias Spore.Auth

  @type opts :: [
          {:min_port, non_neg_integer()},
          {:max_port, non_neg_integer()},
          {:secret, String.t() | nil},
          {:bind_addr, :inet.ip_address() | String.t()},
          {:bind_tunnels, :inet.ip_address() | String.t() | nil}
        ]

  @default_min 1024
  @default_max 65535
  @heartbeat_ms 500

  @doc "Start listening for control connections and serve tunnels."
  @spec listen(opts) :: :ok | {:error, term()}
  def listen(opts) do
    min_port = Keyword.get(opts, :min_port, @default_min)
    max_port = Keyword.get(opts, :max_port, @default_max)
    if min_port > max_port, do: raise(ArgumentError, "port range is empty")

    auth =
      case Keyword.get(opts, :secret) do
        nil ->
          nil

        secret ->
          case Spore.Auth.new_many(secret) do
            [one] -> one
            many when is_list(many) -> {:many, many}
          end
      end

    bind_addr = Keyword.get(opts, :bind_addr, {0, 0, 0, 0}) |> normalize_ip()

    bind_tunnels =
      Keyword.get(opts, :bind_tunnels)
      |> case do
        nil -> bind_addr
        x -> normalize_ip(x)
      end

    # pending connections managed by Spore.Pending

    control_opts =
      [
        :binary,
        {:ip, bind_addr},
        active: false,
        packet: 0,
        reuseaddr: true,
        nodelay: true
      ] ++ Shared.socket_tune_opts()

    with {:ok, listen_socket} <- listen_socket(control_opts) do
      Logger.info("server listening on #{:inet.ntoa(bind_addr)}:#{Shared.control_port()}")
      accept_loop(listen_socket, min_port..max_port, auth, bind_tunnels)
    end
  end

  defp accept_loop(listen_socket, port_range, auth, bind_tunnels) do
    {:ok, socket} = accept_conn(listen_socket)
    {:ok, {ip, _}} = :inet.peername(socket)
    Logger.info("incoming connection from #{:inet.ntoa(ip)}")

    if Spore.ACL.allow?(ip) and Spore.Banlist.allow?(ip) and Spore.Limits.can_open?(ip) do
      Task.start(fn ->
        try do
          handle_connection(socket, port_range, auth, bind_tunnels)
        after
          Spore.Limits.close(ip)
        end
      end)
    else
      :gen_tcp.close(socket)
    end

    accept_loop(listen_socket, port_range, auth, bind_tunnels)
  end

  defp handle_connection(socket, port_range, auth, bind_tunnels) do
    {:ok, {ip, _}} = :inet.peername(socket)
    d = Delimited.new(socket, Shared.transport_mod())

    d =
      case auth do
        nil ->
          d

        %{} = a ->
          case Auth.server_handshake(a, d) do
            {:ok, d2} ->
              d2

            {{:error, reason}, d2} ->
              _ = Delimited.send(d2, %{"Error" => to_string(reason)})
              if {:ok, {ip, _}} = :inet.peername(socket), do: Spore.Banlist.note_failure(ip)
              :gen_tcp.close(socket)
              exit(:normal)
          end

        {:many, list} ->
          case Auth.server_handshake_many(list, d) do
            {:ok, d2, auth_id} ->
              if not Spore.SecretQuota.allow?(auth_id) do
                _ = Delimited.send(d2, %{"Error" => "quota exceeded"})
                :gen_tcp.close(socket)
                exit(:normal)
              end

              Process.put({:spore_auth_id}, auth_id)
              d2

            {{:error, reason}, d2} ->
              _ = Delimited.send(d2, %{"Error" => to_string(reason)})
              if {:ok, {ip, _}} = :inet.peername(socket), do: Spore.Banlist.note_failure(ip)
              :gen_tcp.close(socket)
              exit(:normal)
          end
      end

    Spore.Tracing.with_span(
      "spore.control_connection",
      %{"peer.ip" => :inet.ntoa(ip) |> to_string()},
      fn ->
        case Delimited.recv_timeout(d) do
          {%{"HelloEx" => %{"port" => req_port}}, d2} ->
            case create_listener(req_port, port_range, bind_tunnels) do
              {:ok, listener} ->
                {:ok, {_ip, actual}} = :inet.sockname(listener)
                Logger.info("new client on port #{actual}")

                {:ok, d3} =
                  Delimited.send(d2, %{
                    "HelloEx" => %{"port" => actual, "version" => "spore/1", "features" => []}
                  })

                hello_loop(d3, listener)

              {:error, message} ->
                _ = Delimited.send(d2, %{"Error" => message})
            end

          {%{"Hello" => req_port}, d2} ->
            case create_listener(req_port, port_range, bind_tunnels) do
              {:ok, listener} ->
                {:ok, {_ip, actual}} = :inet.sockname(listener)
                Logger.info("new client on port #{actual}")
                {:ok, d3} = Delimited.send(d2, %{"Hello" => actual})
                hello_loop(d3, listener)

              {:error, message} ->
                _ = Delimited.send(d2, %{"Error" => message})
            end

          {%{"Accept" => id}, d2} ->
            case Spore.Pending.take(id) do
              {:ok, stream2} ->
                Spore.Metrics.note_accept(id)
                # Forward traffic bidirectionally between control socket and stored tunnel conn
                # buffer intentionally unused
                _ = d2
                Shared.pipe_bidirectional(socket, Shared.transport_mod(), stream2, :gen_tcp)

              :error ->
                Logger.warning("missing connection #{id}")
            end

          {%{"Authenticate" => _}, _d2} ->
            Logger.warning("unexpected authenticate")
            :ok

          {:eof, _} ->
            :ok

          {{:error, _}, _} ->
            :ok

          {_, _d2} ->
            :ok
        end
      end
    )
  rescue
    e ->
      if auth_id = Process.get({:spore_auth_id}), do: Spore.SecretQuota.dec(auth_id)
      Logger.warning("connection exited with error: #{inspect(e)}")
  end

  defp listen_socket(control_opts) do
    case Shared.transport_mod() do
      :gen_tcp ->
        :gen_tcp.listen(Shared.control_port(), control_opts)

      :ssl ->
        ssl_opts = ssl_server_opts(control_opts)
        apply(:ssl, :listen, [Shared.control_port(), ssl_opts])
    end
  end

  defp accept_conn(listen_socket) do
    case Shared.transport_mod() do
      :gen_tcp ->
        :gen_tcp.accept(listen_socket)

      :ssl ->
        with {:ok, sock} <- apply(:ssl, :transport_accept, [listen_socket]) do
          apply(:ssl, :ssl_accept, [sock])
        end
    end
  end

  defp ssl_server_opts(control_opts) do
    certfile = Application.get_env(:spore, :certfile)
    keyfile = Application.get_env(:spore, :keyfile)
    cacertfile = Application.get_env(:spore, :cacertfile)

    base = [active: false]

    base =
      if is_binary(certfile) and is_binary(keyfile),
        do: [
          {:certfile, String.to_charlist(certfile)},
          {:keyfile, String.to_charlist(keyfile)} | base
        ],
        else: base

    base =
      if is_binary(cacertfile),
        do: [
          {:cacertfile, String.to_charlist(cacertfile)},
          {:verify, :verify_peer},
          {:fail_if_no_peer_cert, true} | base
        ],
        else: base

    base ++ control_opts
  end

  defp hello_loop(d, listener) do
    case :gen_tcp.accept(listener, 0) do
      {:ok, stream2} ->
        _ = Shared.tune_socket(stream2)
        id = Auth.generate_uuid_v4()
        Spore.Pending.insert(id, stream2, 10_000)
        Spore.Metrics.note_pending(id)
        _ = Delimited.send(d, %{"Connection" => id})
        hello_loop(send_heartbeat(d), listener)

      {:error, :timeout} ->
        :timer.sleep(@heartbeat_ms)
        hello_loop(send_heartbeat(d), listener)

      {:error, _} ->
        :ok
    end
  end

  defp send_heartbeat(d) do
    case Delimited.send(d, "Heartbeat") do
      {:ok, d2} -> d2
      _ -> d
    end
  end

  defp create_listener(port, range, bind_ip) do
    min = range.first
    max = range.last

    cond do
      is_integer(port) and port > 0 ->
        if port < min or port > max do
          {:error, "client port number not in allowed range"}
        else
          bind_tunnel(bind_ip, port)
        end

      true ->
        # Try 150 random ports within range
        attempts = 150
        try_random(attempts, range, bind_ip)
    end
  end

  defp try_random(0, _range, _ip), do: {:error, "failed to find an available port"}

  defp try_random(n, range, ip) do
    min = range.first
    max = range.last
    port = min + :rand.uniform(max - min + 1) - 1

    case bind_tunnel(ip, port) do
      {:ok, l} -> {:ok, l}
      {:error, _} -> try_random(n - 1, range, ip)
    end
  end

  defp bind_tunnel(ip, port) do
    case :gen_tcp.listen(port, [
           :binary,
           {:ip, ip},
           {:backlog, 1024},
           {:send_timeout_close, true},
           active: false,
           packet: 0,
           reuseaddr: true,
           nodelay: true
         ]) do
      {:ok, l} -> {:ok, l}
      {:error, :eaddrinuse} -> {:error, "port already in use"}
      {:error, :eacces} -> {:error, "permission denied"}
      {:error, _} -> {:error, "failed to bind to port"}
    end
  end

  # Accept connection branch: a new control connection will send {"Accept": id}
  def handle_accept_connection(socket, auth) do
    d = Delimited.new(socket, Shared.transport_mod())

    d =
      case auth do
        nil ->
          d

        %{} = a ->
          case Auth.client_handshake(a, d) do
            {:ok, d2} -> d2
            {{:error, _}, d2} -> d2
          end
      end

    case Delimited.recv_timeout(d) do
      {%{"Accept" => id}, d2} ->
        case Spore.Pending.take(id) do
          {:ok, stream2} ->
            # Any buffered bytes already in d2.buffer are not handled here by design, as most cases buffer is empty
            {:ok, parts} = :inet.getopts(socket, [:active])
            _ = parts
            # Switch to raw piping between sockets
            Shared.pipe_bidirectional(socket, stream2)

          :error ->
            Logger.warning("missing connection #{id}")
            :ok
        end

        _ = d2

      _ ->
        :ok
    end
  end

  # pending connection management moved to Spore.Pending

  defp normalize_ip({_, _, _, _} = ip), do: ip
  defp normalize_ip({_, _, _, _, _, _, _, _} = ip), do: ip

  defp normalize_ip(str) when is_binary(str) do
    case :inet.parse_address(String.to_charlist(str)) do
      {:ok, ip} -> ip
      _ -> {0, 0, 0, 0}
    end
  end
end
