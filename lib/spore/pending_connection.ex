defmodule Spore.PendingConnection do
  @moduledoc false
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    socket = Keyword.fetch!(opts, :socket)
    ttl_ms = Keyword.get(opts, :ttl_ms, 10_000)

    Registry.register(Spore.Pending.Registry, id, :pending)
    Process.send_after(self(), :expire, ttl_ms)
    {:ok, %{id: id, socket: socket}}
  end

  @impl true
  def handle_call(:take, _from, %{socket: socket} = state) when is_port(socket) do
    {:stop, :normal, {:ok, socket}, %{state | socket: nil}}
  end

  @impl true
  def handle_call(:take, _from, state) do
    {:reply, {:error, :gone}, state}
  end

  @impl true
  def handle_info(:expire, %{socket: socket, id: id} = state) do
    if is_port(socket) do
      :gen_tcp.close(socket)
      Logger.warning("removed stale connection #{id}")
    end
    {:stop, :normal, %{state | socket: nil}}
  end

  @impl true
  def terminate(_reason, _state), do: :ok
end
