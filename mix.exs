defmodule Spore.MixProject do
  use Mix.Project

  # Single source of truth for the version. Everything else (release label,
  # `spore update --check`, the escript banner) derives from this attribute.
  @version "0.2.8"

  def project do
    [
      app: :spore,
      version: @version,
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
      mod: {Spore.Application, []},
      # Expose the version as application env so runtime code (spore update
      # --check) reads the truth from the same place release tooling does.
      env: [version: @version]
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
