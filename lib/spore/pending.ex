defmodule Spore.Pending do
  @moduledoc false
  use GenServer

  alias Spore.PendingConnection

  def start_link(_args) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    {:ok, :ok}
  end

  def insert(id, socket, ttl_ms \\ 10_000) do
    maxp = Application.get_env(:spore, :max_pending, :infinity)

    if maxp != :infinity do
      %{active: active} = DynamicSupervisor.count_children(Spore.Pending.Supervisor)

      if active >= maxp do
        :gen_tcp.close(socket)
        Spore.Metrics.inc(:spore_connections_pending_dropped_total, 1)
        throw({:error, :too_many_pending})
      end
    end

    child_spec = %{
      id: {PendingConnection, id},
      start: {PendingConnection, :start_link, [[id: id, socket: socket, ttl_ms: ttl_ms]]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(Spore.Pending.Supervisor, child_spec)
    :ok
  end

  def take(id) do
    case Registry.lookup(Spore.Pending.Registry, id) do
      [{pid, :pending}] -> GenServer.call(pid, :take, 2_000)
      _ -> {:error, :not_found}
    end
  end
end
