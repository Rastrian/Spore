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
      d = Delimited.new(socket)
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

      {:ok, d} = Delimited.send(d, %{"Hello" => port})

      case Delimited.recv_timeout(d) do
        {%{"Hello" => remote_port}, d_after} ->
          Logger.info("connected to server")
          Logger.info("listening at #{to}:#{remote_port}")

          {:ok,
           %__MODULE__{
             to: to,
             local_host: local_host,
             local_port: local_port,
             remote_port: remote_port,
             auth: auth,
             conn: d_after
           }}

        {%{"Error" => message}, _} ->
          {:error, {:server_error, message}}

        {"Challenge", _} ->
          {:error, :server_requires_authentication}

        {:eof, _} ->
          {:error, :eof}

        {{:error, reason}, _} ->
          {:error, reason}

        _ ->
          {:error, :unexpected_initial_message}
      end
    end
  catch
    {:error, reason} -> {:error, reason}
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
      d = Delimited.new(remote_conn)

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
          Shared.pipe_bidirectional(remote_conn, local_conn)

        {:error, reason} ->
          :gen_tcp.close(remote_conn)
          {:error, reason}
      end
    end
  end
end
