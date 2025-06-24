# --- Test Configuration for Arbor CLI ---
# Command-line interface for interacting with the Arbor system.

# Environment detection
is_watch_mode = System.get_env("TEST_WATCH") == "true"
is_ci = System.get_env("CI") == "true"
run_distributed_tests = System.get_env("ARBOR_DISTRIBUTED_TEST") == "true"

# Configure ExUnit based on environment
exclude_tags =
  cond do
    is_watch_mode ->
      # In watch mode, only run fast tests
      [integration: true, distributed: true, chaos: true, contract: true]

    run_distributed_tests ->
      # When running distributed tests, don't exclude anything
      # (though CLI app has no distributed tests)
      []

    is_ci ->
      # In CI, exclude only expensive tests
      [distributed: true, chaos: true]

    true ->
      # Default: exclude distributed and chaos tests
      [distributed: true, chaos: true]
  end

# CLI tests may involve real processes, so less async when including integration
async_mode = not (run_distributed_tests or :integration not in exclude_tags)

ExUnit.start(exclude: exclude_tags, async: async_mode)

# Configure test environment
Application.put_env(:arbor_cli, :gateway_endpoint, "http://localhost:4000")
Application.put_env(:arbor_cli, :output_format, :table)
Application.put_env(:arbor_cli, :timeout, 30_000)
Application.put_env(:arbor_cli, :verbose, false)
Application.put_env(:arbor_cli, :telemetry_enabled, false)
