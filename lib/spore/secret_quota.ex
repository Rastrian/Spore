defmodule Spore.SecretQuota do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(_) do
    {:ok, %{counts: %{}, limits: load_limits()}}
  end

  def allow?(id), do: GenServer.call(__MODULE__, {:allow?, id})
  def dec(id), do: GenServer.cast(__MODULE__, {:dec, id})
  def reload_limits(), do: GenServer.cast(__MODULE__, :reload)

  defp load_limits do
    case Application.get_env(:spore, :secret_quotas) do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  @impl true
  def handle_call({:allow?, id}, _from, %{counts: c, limits: l} = state) do
    curr = Map.get(c, id, 0)
    max = Map.get(l, id, :infinity)
    allow = max == :infinity or curr < max
    c2 = if allow, do: Map.put(c, id, curr + 1), else: c
    {:reply, allow, %{state | counts: c2}}
  end

  @impl true
  def handle_cast({:dec, id}, %{counts: c} = state) do
    c2 = case Map.get(c, id) do
      nil -> c
      1 -> Map.delete(c, id)
      n when is_integer(n) and n>1 -> Map.put(c, id, n-1)
    end
    {:noreply, %{state | counts: c2}}
  end

  @impl true
  def handle_cast(:reload, state) do
    {:noreply, %{state | limits: load_limits()}}
  end
end
