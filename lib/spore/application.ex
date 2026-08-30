defmodule Spore.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # SPORE_ARGS is applied before any child starts so that flags such as
    # --metrics-port or --otel-enable are already in the application env when
    # the corresponding child boots.
    spore_opts = parse_spore_args()

    _ = Spore.Tracing.start()

    if Application.get_env(:spore, :json_logs, false) do
      case :logger.get_handler_config(:default) do
        {:ok, %{formatter: {Logger.Formatter, formatter}}} ->
          :logger.update_handler_config(
            :default,
            %{
              formatter:
                {Logger.Formatter, %{formatter | template: {Spore.JsonFormatter, :format}}}
            }
          )

        _ ->
          :ok
      end
    end

    children =
      [
        {Registry, keys: :unique, name: Spore.Pending.Registry},
        {DynamicSupervisor, name: Spore.Pending.Supervisor, strategy: :one_for_one},
        {Spore.Pending, []},
        {Spore.Limits, []},
        {Spore.Banlist, []},
        {Spore.SecretQuota, []},
        {Spore.Active, []},
        {Spore.Metrics, []}
      ] ++ release_children(spore_opts)

    opts = [strategy: :one_for_one, name: Spore.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Turn SPORE_ARGS into a child for the release boot path. Unset or
  # unrecognized values leave the tree untouched so the plain `bin/spore`
  # daemon still boots.
  defp release_children({:server, server_opts}), do: [{Spore.ReleaseServer, server_opts}]
  defp release_children({:local, local_opts}), do: [{Spore.ReleaseClient, local_opts}]
  defp release_children(nil), do: []

  defp parse_spore_args do
    case System.get_env("SPORE_ARGS") do
      nil ->
        nil

      args ->
        case OptionParser.split(args) do
          ["server" | rest] ->
            {:server, Spore.CLI.apply_server_opts(rest)}

          ["local" | rest] ->
            {:local, Spore.CLI.apply_local_opts(rest)}

          other ->
            Logger.warning(
              "ignoring SPORE_ARGS, only \"server ...\" or \"local ...\" is supported: " <>
                inspect(other)
            )

            nil
        end
    end
  end
end
