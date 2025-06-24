# --- Test Configuration for Arbor Persistence ---
# Event sourcing and CQRS implementation layer.
# Tests may include integration tests with real event stores.

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
      # Default: exclude distributed and chaos tests
      [distributed: true, chaos: true]
  end

# Persistence tests may involve real storage, so less async when including integration
async_mode = not (run_distributed_tests or :integration not in exclude_tags)

ExUnit.start(exclude: exclude_tags, async: async_mode)
