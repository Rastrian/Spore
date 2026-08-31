defmodule Spore.ReleaseClient do
  @moduledoc false
  # Runs the bore-protocol client inside the `mix release` supervision tree,
  # started from Spore.Application when SPORE_ARGS asks for a local tunnel.
  #
  # With --retry (application env :spore, :retry), Spore.Client.listen/1
  # reconnects internally with backoff and only returns if it gives up, which
  # currently never happens — the in-client retry runs indefinitely. Without
  # it, every termination path exits NON-clean so the supervisor restarts the
  # tunnel (crash-restart fallback kept for compatibility).
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(%{} = args) do
    Task.start_link(fn -> run(args) end)
    {:ok, %{}}
  end

  defp run(args) do
    case Spore.Client.new(args.local_host, args.local_port, args.to, args.port, args.secret) do
      {:ok, client} ->
        case Spore.Client.listen(client) do
          :ok ->
            Logger.warning("spore client: control connection closed; restarting")
            exit({:client_disconnected, :eof})

          {:error, err} ->
            Logger.error("spore client exited: #{inspect(err)}")
            exit({:client_error, err})
        end

      {:error, err} ->
        Logger.error("spore client failed to connect: #{inspect(err)}")
        exit({:client_connect_failed, err})
    end
  end
end
