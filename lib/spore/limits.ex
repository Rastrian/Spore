defmodule Spore.Limits do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  def can_open?(ip) do
    GenServer.call(__MODULE__, {:can_open, ip})
  end

  def close(ip) do
    GenServer.cast(__MODULE__, {:close, ip})
  end

  @impl true
  def handle_call({:can_open, ip}, _from, state) do
    max = Application.get_env(:spore, :max_conns_per_ip, :infinity)
    {count, state2} = Map.get_and_update(state, ip, fn v -> {v || 0, (v || 0) + 1} end)
    allow = case max do
      :infinity -> true
      n when is_integer(n) and n > 0 -> count < n
      _ -> true
    end
    state3 = if allow, do: state2, else: state
    {:reply, allow, state3}
  end

  @impl true
  def handle_cast({:close, ip}, state) do
    state2 = update_in(state[ip], fn
      nil -> nil
      1 -> nil
      n when is_integer(n) and n>1 -> n-1
    end)
    {:noreply, state2}
  end
end
