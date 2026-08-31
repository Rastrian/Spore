defmodule Spore.MixProject do
  use Mix.Project

  def project do
    [
      app: :spore,
      version: "0.2.7",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: [main_module: Spore.CLI],
      # The app's singletons (Limits, Banlist, SecretQuota, ...) are registered
      # names; tests start fresh instances per test via start_supervised!, so
      # the real application must NOT be booted by the test runner.
      aliases: [test: "test --no-start"]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl],
      mod: {Spore.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:uuid, "~> 1.1"},
      {:opentelemetry_api, "~> 1.5"},
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_exporter, "~> 1.10"}
    ]
  end
end
