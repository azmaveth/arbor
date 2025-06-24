# --- Test Configuration for Arbor Security ---
# Security layer with capability-based authentication and authorization.

# Configure the application to use mock databases in most tests
# Integration tests will override this by starting real repos
Application.put_env(:arbor_security, :use_mock_db, true)

# Start the real repository for integration tests that need it
# This will only be used if integration tests specifically start it
Application.ensure_all_started(:postgrex)

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
      []

    is_ci ->
      # In CI, exclude only expensive tests
      [distributed: true, chaos: true]

    true ->
      # Default: exclude distributed, chaos, and integration tests
      [integration: true, distributed: true, chaos: true]
  end

# Security tests may involve real processes, so less async when including integration
async_mode = not (run_distributed_tests or :integration not in exclude_tags)

ExUnit.start(exclude: exclude_tags, async: async_mode)
