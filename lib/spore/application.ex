defmodule Spore.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    _ = Spore.Tracing.start()
    if Application.get_env(:spore, :json_logs, false) do
      Logger.configure_backend(:console, format: {Spore.JsonFormatter, :format})
    end

    children = [
      {Registry, keys: :unique, name: Spore.Pending.Registry},
      {DynamicSupervisor, name: Spore.Pending.Supervisor, strategy: :one_for_one},
      {Spore.Pending, []},
      {Spore.Limits, []},
      {Spore.Banlist, []},
      {Spore.SecretQuota, []},
      {Spore.Active, []},
      {Spore.Metrics, []}
    ]

    opts = [strategy: :one_for_one, name: Spore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
