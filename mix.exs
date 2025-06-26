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
        test: :test,
        "test.pre_commit": :test,
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
      {:mox, "~> 1.1", only: :test},
      {:ex_machina, "~> 2.7", only: :test},

      # Development tools
      {:observer_cli, "~> 1.7", only: :dev},
      {:benchee, "~> 1.3", only: :dev},
      {:jason, "~> 1.4"},
      {:sourceror, "~> 1.0", only: :dev}
    ]
  end

  # Mix aliases for common tasks
  defp aliases do
    [
      # Smart test dispatcher and pre-commit hook
      "test.do": ["test"],
      test: &dispatch_test/1,
      "test.pre_commit": ["format --check-formatted", "credo --strict", "test.fast"],

      # Project setup
      setup: ["deps.get", "deps.compile", "compile"],

      # Test execution tiers (by speed and scope)
      # <2 min - unit tests with mocks
      "test.fast": ["test.do --only fast"],
      # ~3 min - interface boundary tests
      "test.contract": ["test.do --only contract"],
      # ~8 min - single-node e2e tests
      "test.integration": ["test.do --only integration"],
      # ~15 min - multi-node cluster tests
      "test.distributed": ["test.do --only distributed"],
      # ~30 min - fault injection tests
      "test.chaos": ["test.do --only chaos"],

      # Combined test suites
      # fast + contract
      "test.unit": ["test.do --exclude integration,distributed,chaos"],
      # everything except expensive tests
      "test.ci": ["test.do --exclude distributed,chaos"],
      # everything (use with caution)
      "test.all": ["test.do"],

      # Development workflow
      # watch mode for development
      "test.watch": ["test.do --only fast --listen-on-stdin"],

      # Quality and coverage
      # coverage without slow tests
      "test.cover": ["test.do --cover --exclude distributed,chaos"],
      # full coverage including slow tests
      "test.coverage.full": ["test.do --cover"],

      # CI/CD specific
      "test.ci.fast": ["test.do --exclude integration,distributed,chaos", "credo --strict"],
      "test.ci.full": ["test.do --cover --export-coverage default", "credo --strict", "dialyzer"],

      # Distributed testing (requires special setup)
      "test.dist": ["test.do --cover --export-coverage distributed --only distributed"],

      # Performance and security (placeholders for future implementation)
      "test.perf": ["run -e \"IO.puts('Performance tests not implemented yet')\""],
      "test.security": ["run -e \"IO.puts('Security tests not implemented yet')\""],

      # Code quality
      docs: ["docs"],
      quality: ["format", "credo --strict", "dialyzer"]
    ]
  end

  # Smart test dispatcher function
  defp dispatch_test(args) do
    # Handle help requests by delegating to Mix.Tasks.Help
    case args do
      ["--help"] ->
        Mix.Tasks.Help.run(["test"])

      ["-h"] ->
        Mix.Tasks.Help.run(["test"])

      _ ->
        # Apply smart routing logic
        has_overrides? =
          Enum.any?(args, &(&1 in ["--only", "--exclude", "--include"])) or
            Enum.any?(args, &String.starts_with?(&1, "test/"))

        {suite_name, test_args} =
          cond do
            has_overrides? ->
              {"User-defined suite", args}

            System.get_env("DISTRIBUTED") == "true" ->
              {"Full suite (DISTRIBUTED=true)", args}

            System.get_env("CI") == "true" ->
              {"CI suite", ["--exclude", "distributed,chaos" | args]}

            true ->
              # Default for local development: run only the fastest tests.
              {"Fast suite (local default)", ["--only", "fast" | args]}
          end

        IO.puts(IO.ANSI.green() <> "==> Running #{suite_name}" <> IO.ANSI.reset())
        # We call "test.do" to avoid a recursive loop on the "test" alias itself.
        Mix.Task.run("test.do", test_args)
    end
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
