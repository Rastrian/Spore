defmodule Spore.Active do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, 0, name: __MODULE__)

  @impl true
  def init(count), do: {:ok, count}

  def allow? do
    GenServer.call(__MODULE__, :allow)
  end

  def dec do
    GenServer.cast(__MODULE__, :dec)
  end

  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @impl true
  def handle_call(:allow, _from, count) do
    max = Application.get_env(:spore, :max_active, :infinity)
    allow = max == :infinity or count < max
    count2 = if allow, do: count + 1, else: count
    {:reply, allow, count2}
  end

  @impl true
  def handle_cast(:dec, count) do
    {:noreply, if(count > 0, do: count - 1, else: 0)}
  end

  @impl true
  def handle_call(:snapshot, _from, count) do
    {:reply, count, count}
  end
end
