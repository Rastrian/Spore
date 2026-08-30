defmodule Spore.ReleaseServer do
  @moduledoc false
  # Runs the bore server inside the `mix release` supervision tree, started
  # from Spore.Application when SPORE_ARGS asks for a server.
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Task.start_link(fn ->
      case Spore.Server.listen(opts) do
        :ok ->
          :ok

        {:error, err} ->
          Logger.error("release server exited: " <> inspect(err))
          exit({:server_error, err})
      end
    end)

    {:ok, %{}}
  end
end
