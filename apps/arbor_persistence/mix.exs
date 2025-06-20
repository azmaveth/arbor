defmodule Arbor.Persistence.MixProject do
  use Mix.Project

  def project do
    [
      app: :arbor_persistence,
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
      extra_applications: [:logger],
      mod: {Arbor.Persistence.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:arbor_contracts, in_umbrella: true},
      {:ecto_sql, "~> 3.11"},
      {:postgrex, "~> 0.17"},
      {:jason, "~> 1.4"}
    ]
  end
end
