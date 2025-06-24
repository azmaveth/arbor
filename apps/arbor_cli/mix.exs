defmodule ArborCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :arbor_cli,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {ArborCli.Application, []}
    ]
  end

  defp escript do
    [
      main_module: ArborCli.CLI,
      name: "arbor",
      embed_elixir: true
    ]
  end

  defp deps do
    [
      # Internal dependencies
      {:arbor_contracts, in_umbrella: true},

      # External dependencies
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},
      {:phoenix_pubsub, "~> 2.1"},
      {:table_rex, "~> 3.1.1"},  # For table formatting
      {:optimus, "~> 0.3.0"},     # For command line argument parsing
      {:owl, "~> 0.11"},          # For rich terminal UI
      {:httpoison, "~> 2.0"},     # HTTP client
      {:websockex, "~> 0.4"}      # WebSocket client
    ]
  end
end
