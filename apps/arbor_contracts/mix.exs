defmodule Arbor.Contracts.MixProject do
  use Mix.Project

  def project do
    [
      app: :arbor_contracts,
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
      extra_applications: [:logger, :telemetry],
      mod: {Arbor.Contracts.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:typed_struct, "~> 0.3.0"},
      {:jason, "~> 1.4"},
      {:norm, "~> 0.13"},
      {:telemetry, "~> 1.0"}
    ]
  end
end
