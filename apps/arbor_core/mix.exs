defmodule Arbor.Core.MixProject do
  use Mix.Project

  def project do
    [
      app: :arbor_core,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Arbor.Core.Application, []},
      extra_applications: [
        :logger,
        :runtime_tools,
        :phoenix_pubsub,
        :telemetry,
        :telemetry_poller
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:arbor_contracts, in_umbrella: true},
      {:arbor_security, in_umbrella: true},
      {:arbor_persistence, in_umbrella: true},
      {:horde, "~> 0.8"},
      {:libcluster, "~> 3.3"},
      {:phoenix_pubsub, "~> 2.1"},
      {:telemetry, "~> 1.0"}
    ]
  end
end
