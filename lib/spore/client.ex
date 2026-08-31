defmodule Spore.Client do
  @moduledoc """
  Client implementation for the `bore` protocol in Elixir.
  """

  require Logger
  alias Spore.Shared
  alias Spore.Shared.Delimited
  alias Spore.Auth

  @default_retry_delay_ms 5_000
  @max_retry_delay_ms 60_000
  # The server heartbeats every 500ms (see hello_loop/2 in Spore.Server), so
  # the default tolerates ten missed heartbeats before a control connection
  # is presumed dead.
  @default_heartbeat_timeout_ms 5_000

  defstruct [:to, :local_host, :local_port, :remote_port, :auth, :conn]

  @type t :: %__MODULE__{
          to: String.t(),
          local_host: String.t(),
          local_port: non_neg_integer(),
          remote_port: non_neg_integer(),
          auth: map() | nil,
          conn: Delimited.t() | nil
        }

  @doc "Create a new client and perform the initial handshake."
  @spec new(String.t(), non_neg_integer(), String.t(), non_neg_integer(), String.t() | nil) ::
          {:ok, t} | {:error, term()}
  def new(local_host, local_port, to, port, secret) do
    with {:ok, socket} <- Shared.connect(to, Shared.control_port(), Shared.network_timeout_ms()) do
      d = Delimited.new(socket, Shared.transport_mod())
      auth = if secret, do: Auth.new(secret), else: nil

      d =
        case auth do
          nil ->
            d

          %{} = a ->
            case Auth.client_handshake(a, d) do
              {:ok, d2} ->
                d2

              {{:error, reason}, _} ->
                :gen_tcp.close(socket)
                throw({:error, reason})
            end
        end

      # The Rust bore server decodes ClientMessage as a closed serde enum and
      # drops the connection on an unrecognized variant such as HelloEx, so the
      # legacy Hello must go first; the extended hello is only attempted when
      # the server clearly could not decode the legacy frame.
      case hello(d, port, false) do
        {:ok, remote_port, d2} ->
          Logger.info("listening at #{to}:#{remote_port}")

          {:ok,
           %__MODULE__{
             to: to,
             local_host: local_host,
             local_port: local_port,
             remote_port: remote_port,
             auth: auth,
             conn: d2
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  catch
    {:error, reason} -> {:error, reason}
  end

  # Exchange one hello variant and map the server's reply. `extended?` selects
  # the outgoing frame and bounds the retry: a frame the server fails to decode
  # (or an unrecognized reply) gets exactly one retry with the extended hello.
  # Transport errors and :eof are terminal because the connection is gone.
  defp hello(d, port, extended?) do
    message =
      if extended?,
        do: %{
          "HelloEx" => %{
            "port" => port,
            "version" => "spore/1",
            "features" => hello_ex_features()
          }
        },
        else: %{"Hello" => port}

    with {:ok, d2} <- Delimited.send(d, message) do
      case Delimited.recv_timeout(d2) do
        {%{"Hello" => remote_port}, d_after} ->
          Logger.info("connected to server (legacy Hello)")
          {:ok, remote_port, d_after}

        {%{"HelloEx" => %{"port" => remote_port}}, d_after} ->
          Logger.info("connected to server (HelloEx)")
          Logger.info("server is a Spore server")
          {:ok, remote_port, d_after}

        {%{"Error" => message}, _} ->
          {:error, {:server_error, message}}

        {"Challenge", _} ->
          {:error, :server_requires_authentication}

        {:eof, _} ->
          {:error, :eof}

        {{:error, {:decode_error, _} = reason}, d_after} ->
          retry(d_after, port, extended?, reason)

        {{:error, reason}, _} ->
          {:error, reason}

        {other, d_after} ->
          retry(d_after, port, extended?, {:unexpected_initial_message, other})
      end
    end
  end

  defp retry(_d, _port, true, reason), do: {:error, reason}
  defp retry(d, port, false, _reason), do: hello(d, port, true)

  defp hello_ex_features do
    if Application.get_env(:spore, :tls, false), do: ["tls"], else: []
  end

  @doc "Return the publicly available remote port."
  def remote_port(%__MODULE__{remote_port: p}), do: p

  @doc """
  Start the client control loop. With `retry: true` (or a positive
  `retry_delay_ms`) the loop reconnects automatically instead of returning:
  connection loss and failed (re)connects back off exponentially from
  `retry_delay_ms` up to `max_retry_delay_ms`, indefinitely.

  Reads are bounded by `heartbeat_timeout_ms` (default
  `#{@default_heartbeat_timeout_ms}ms`): the server heartbeats every 500ms, so
  a control connection that stops delivering them — dead without a FIN/RST
  ever reaching us, e.g. after a NAT/conntrack flush — is declared lost and
  reconnects (or returns `{:error, :heartbeat_timeout}` without retry)
  instead of blocking forever.
  """
  @spec listen(t) :: :ok | {:error, term()}
  def listen(%__MODULE__{conn: d} = state) when not is_nil(d) do
    retry? = Application.get_env(:spore, :retry, false)
    delay = retry_delay_ms()
    loop(d, %{state | conn: nil}, retry?, delay)
  end

  defp retry_delay_ms do
    case Application.get_env(:spore, :retry_delay_ms) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_retry_delay_ms
    end
  end

  defp max_retry_delay_ms do
    case Application.get_env(:spore, :max_retry_delay_ms) do
      n when is_integer(n) and n > 0 -> n
      _ -> @max_retry_delay_ms
    end
  end

  # How long a read on the control connection may block before the connection
  # is presumed dead. Well above the server's 500ms heartbeat cadence, and
  # low enough that a zombie connection is dropped in seconds, not hours.
  defp heartbeat_timeout_ms do
    case Application.get_env(:spore, :heartbeat_timeout_ms) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_heartbeat_timeout_ms
    end
  end

  defp close_conn(%Delimited{socket: socket, io_mod: io_mod}), do: io_mod.close(socket)

  # Control loop. `retry?` and `delay` are carried in the tail calls; `delay`
  # is the next backoff value and resets on every successful (re)connection.
  # Reads are bounded by the heartbeat timeout: without it, a connection that
  # died without delivering a FIN/RST (NAT/conntrack flush, silent host loss)
  # blocks recv forever and `--retry` never gets a chance to fire.
  defp loop(d, state, retry?, delay) do
    case Delimited.recv(d, heartbeat_timeout_ms()) do
      {"Heartbeat", d2} ->
        loop(d2, state, retry?, delay)

      {%{"Connection" => id}, d2} ->
        Task.start(fn ->
          case handle_connection(id, state) do
            :ok -> Logger.info("connection exited")
            {:error, err} -> Logger.warning("connection exited with error: #{inspect(err)}")
          end
        end)

        loop(d2, state, retry?, delay)

      {%{"Error" => err}, _d2} ->
        Logger.error("server error: #{err}")

        if retry?, do: reconnect(state, retry?, delay), else: :ok

      {:eof, _} ->
        if retry?, do: reconnect(state, retry?, delay), else: :ok

      {{:error, :timeout}, d} ->
        # The socket looks healthy but the server has been silent for far
        # longer than its heartbeat interval: treat it as gone, exactly like
        # an error, closing it ourselves since no FIN is coming.
        Logger.warning(
          "spore client: no heartbeat within #{heartbeat_timeout_ms()}ms; " <>
            "control connection presumed dead"
        )

        close_conn(d)

        if retry?, do: reconnect(state, retry?, delay), else: {:error, :heartbeat_timeout}

      {{:error, _}, _} ->
        if retry?, do: reconnect(state, retry?, delay), else: :ok

      _ ->
        loop(d, state, retry?, delay)
    end
  end

  # Reconnect loop: re-handshake (which re-requests the remote port), then
  # re-enter the control loop. Backoff grows exponentially up to
  # :max_retry_delay_ms and resets to :retry_delay_ms after a success.
  defp reconnect(state, retry?, delay) do
    Logger.warning(
      "spore client: control connection lost; retrying in #{delay}ms (to #{state.to})"
    )

    Process.sleep(delay)

    case new(state.local_host, state.local_port, state.to, state.remote_port, secret(state)) do
      {:ok, client} ->
        Logger.info("spore client: reconnected; listening at #{state.to}:#{client.remote_port}")
        loop(client.conn, %{client | conn: nil}, retry?, retry_delay_ms())

      {:error, err} ->
        Logger.error("spore client reconnect failed: #{inspect(err)}")
        reconnect(state, retry?, next_delay(delay))
    end
  end

  defp secret(%{auth: nil}), do: nil

  defp secret(%{auth: %{key: key}}) do
    # The authenticator only keeps the hashed key; the retry path needs the
    # original secret, kept in application env by the CLI/daemon boot.
    case Application.get_env(:spore, :last_secret) do
      s when is_binary(s) ->
        if Auth.new(s).key == key, do: s, else: nil

      _ ->
        nil
    end
  end

  defp next_delay(delay), do: min(delay * 2, max_retry_delay_ms())

  defp handle_connection(id, %__MODULE__{} = state) do
    with {:ok, remote_conn} <-
           Shared.connect(state.to, Shared.control_port(), Shared.network_timeout_ms()) do
      d = Delimited.new(remote_conn, Shared.transport_mod())

      d =
        case state.auth do
          nil ->
            d

          %{} = a ->
            case Auth.client_handshake(a, d) do
              {:ok, d2} -> d2
              {{:error, _}, d2} -> d2
            end
        end

      _ = Delimited.send(d, %{"Accept" => id})

      case Shared.connect(state.local_host, state.local_port, Shared.network_timeout_ms()) do
        {:ok, local_conn} ->
          # Any data already buffered in `d` is intentionally not forwarded; see Rust note
          Shared.pipe_bidirectional(remote_conn, Shared.transport_mod(), local_conn, :gen_tcp)

        {:error, reason} ->
          :gen_tcp.close(remote_conn)
          {:error, reason}
      end
    end
  end
end
