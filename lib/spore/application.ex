defmodule Spore.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Spore.Pending.Registry},
      {DynamicSupervisor, name: Spore.Pending.Supervisor, strategy: :one_for_one},
      {Spore.Pending, []}
    ]

    opts = [strategy: :one_for_one, name: Spore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
