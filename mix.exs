defmodule Arbor.MixProject do
  use Mix.Project

  def project do
    [
      name: "Arbor",
      apps_path: "apps",
      apps: [:arbor_contracts, :arbor_security, :arbor_persistence, :arbor_core, :arbor_cli],
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      test_coverage: [tool: ExCoveralls],
      docs: docs(),
      preferred_cli_env: [
        # Coverage tools
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,

        # Test execution tiers
        "test.fast": :test,
        "test.contract": :test,
        "test.integration": :test,
        "test.distributed": :test,
        "test.chaos": :test,

        # Combined test suites
        "test.unit": :test,
        "test.ci": :test,
        "test.all": :test,

        # Development and coverage
        "test.watch": :test,
        "test.cover": :test,
        "test.coverage.full": :test,

        # CI/CD
        "test.ci.fast": :test,
        "test.ci.full": :test,
        "test.dist": :test,

        # Future implementations
        "test.perf": :test,
        "test.security": :test
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
      # Project setup
      setup: ["deps.get", "deps.compile", "compile"],

      # Test execution tiers (by speed and scope)
      # <2 min - unit tests with mocks
      "test.fast": ["test --only fast"],
      # ~3 min - interface boundary tests
      "test.contract": ["test --only contract"],
      # ~8 min - single-node e2e tests
      "test.integration": ["test --only integration"],
      # ~15 min - multi-node cluster tests
      "test.distributed": ["test --only distributed"],
      # ~30 min - fault injection tests
      "test.chaos": ["test --only chaos"],

      # Combined test suites
      # fast + contract
      "test.unit": ["test --exclude integration,distributed,chaos"],
      # everything except expensive tests
      "test.ci": ["test --exclude distributed,chaos"],
      # everything (use with caution)
      "test.all": ["test"],

      # Development workflow
      # watch mode for development
      "test.watch": ["test --only fast --listen-on-stdin"],

      # Quality and coverage
      # coverage without slow tests
      "test.cover": ["test --cover --exclude distributed,chaos"],
      # full coverage including slow tests
      "test.coverage.full": ["test --cover"],

      # CI/CD specific
      "test.ci.fast": ["test --exclude integration,distributed,chaos", "credo --strict"],
      "test.ci.full": ["test --cover --export-coverage default", "credo --strict", "dialyzer"],

      # Distributed testing (requires special setup)
      "test.dist": ["test --cover --export-coverage distributed --only distributed"],

      # Performance and security (placeholders for future implementation)
      "test.perf": ["run -e \"IO.puts('Performance tests not implemented yet')\""],
      "test.security": ["run -e \"IO.puts('Security tests not implemented yet')\""],

      # Code quality
      docs: ["docs"],
      quality: ["format", "credo --strict", "dialyzer"]
    ]
  end

  # Release configuration
  defp releases do
    [
      arbor: [
        applications: [
          arbor_contracts: :permanent,
          arbor_security: :permanent,
          arbor_persistence: :permanent,
          arbor_core: :permanent
        ],
        include_executables_for: [:unix],
        steps: [:assemble, :tar]
      ]
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
