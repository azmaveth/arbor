defmodule Arbor.MixProject do
  use Mix.Project

  def project do
    [
      name: "Arbor",
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      docs: docs(),
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "test.all": :test,
        "test.ci": :test
      ]
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    [
      # Code quality
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},

      # Testing
      {:excoveralls, "~> 0.18", only: :test},
      {:mock, "~> 0.3", only: :test},
      {:ex_machina, "~> 2.7", only: :test},

      # Development tools
      {:observer_cli, "~> 1.7", only: :dev},
      {:benchee, "~> 1.3", only: :dev}
    ]
  end

  # Mix aliases for common tasks
  defp aliases do
    [
      setup: ["deps.get", "deps.compile", "compile"],
      "test.all": ["test --cover", "credo --strict", "dialyzer"],
      "test.ci": ["test --cover --export-coverage default", "credo --strict"],
      docs: ["docs"],
      quality: ["format", "credo --strict", "dialyzer"]
    ]
  end

  # Documentation configuration
  defp docs do
    [
      name: "Arbor",
      source_url: "https://github.com/azmaveth/arbor",
      main: "readme",
      extras: ["README.md"]
    ]
  end
end
