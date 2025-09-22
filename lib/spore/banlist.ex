defmodule Spore.Banlist do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  def allow?(ip), do: GenServer.call(__MODULE__, {:allow?, ip})
  def note_failure(ip), do: GenServer.cast(__MODULE__, {:failure, ip})

  @impl true
  def handle_call({:allow?, ip}, _from, state) do
    now = System.monotonic_time(:millisecond)

    case Map.get(state, ip) do
      {:banned, until_ms} when now < until_ms -> {:reply, false, state}
      {:banned, _} -> {:reply, true, Map.delete(state, ip)}
      _ -> {:reply, true, state}
    end
  end

  @impl true
  def handle_cast({:failure, ip}, state) do
    {count, state2} = Map.get_and_update(state, {:count, ip}, fn v -> {v || 0, (v || 0) + 1} end)
    threshold = Application.get_env(:spore, :auth_fail_threshold, 5)
    ban_ms = Application.get_env(:spore, :auth_ban_ms, 60_000)

    state3 =
      if count + 1 >= threshold do
        Map.put(state2, ip, {:banned, System.monotonic_time(:millisecond) + ban_ms})
      else
        state2
      end

    {:noreply, state3}
  end
end
