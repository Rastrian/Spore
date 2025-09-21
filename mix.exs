defmodule Spore.MixProject do
  use Mix.Project

  def project do
    [
      app: :spore,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: [main_module: Spore.CLI]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Spore.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:uuid, "~> 1.1"}
    ]
  end
end
