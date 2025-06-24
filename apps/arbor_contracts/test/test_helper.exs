# --- Test Configuration for Arbor Contracts ---
# This is the foundation layer with schemas, types, and protocols.
# Tests should be fast unit tests with minimal dependencies.

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
      # Default: exclude distributed, chaos, and integration tests.
      # Contract tests are primarily fast unit tests.
      [integration: true, distributed: true, chaos: true]
  end

# Contracts tests should generally be fast and can run async.
# We only disable async for integration or distributed tests.
async_mode = not (run_distributed_tests or :integration not in exclude_tags)

ExUnit.start(exclude: exclude_tags, async: async_mode)
