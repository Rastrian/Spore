defmodule Spore.Client do
  @moduledoc """
  Client implementation for the `bore` protocol in Elixir.
  """

  require Logger
  alias Spore.Shared
  alias Spore.Shared.Delimited
  alias Spore.Auth

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

  @doc "Start the client control loop."
  @spec listen(t) :: :ok | {:error, term()}
  def listen(%__MODULE__{conn: d} = state) when not is_nil(d) do
    loop(d, %{state | conn: nil})
  end

  defp loop(d, state) do
    case Delimited.recv(d) do
      {"Heartbeat", d2} ->
        loop(d2, state)

      {%{"Connection" => id}, d2} ->
        Task.start(fn ->
          case handle_connection(id, state) do
            :ok -> Logger.info("connection exited")
            {:error, err} -> Logger.warning("connection exited with error: #{inspect(err)}")
          end
        end)

        loop(d2, state)

      {%{"Error" => err}, _d2} ->
        Logger.error("server error: #{err}")

      {:eof, _} ->
        :ok

      {{:error, _}, _} ->
        :ok

      _ ->
        loop(d, state)
    end
  end

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
