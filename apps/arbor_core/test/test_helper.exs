# --- Test Configuration for Arbor Core ---
# Core application with agent supervision and cluster management.

# Ensure all required applications are started
{:ok, _} = Application.ensure_all_started(:telemetry)
{:ok, _} = Application.ensure_all_started(:telemetry_poller)
{:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

# Start a mock session registry for tests
{:ok, _} = Registry.start_link(keys: :unique, name: Arbor.Core.MockSessionRegistry)

# Environment detection
is_watch_mode = System.get_env("TEST_WATCH") == "true"
is_ci = System.get_env("CI") == "true"
run_distributed_tests = System.get_env("ARBOR_DISTRIBUTED_TEST") == "true"

# Configure ExUnit based on environment
exclude_tags =
  cond do
    is_watch_mode ->
      # In watch mode, only run fast tests
      [integration: true, distributed: true, chaos: true, contract: true, slow: true]

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

# Core tests may involve real processes, so less async when including integration
async_mode = not (run_distributed_tests or :integration not in exclude_tags)

# Load support files before ExUnit callbacks are registered.
# Note: The path is relative to the file where `Code.require_file` is called.
Code.require_file("support/test_cleanup.ex", __DIR__)
Code.require_file("support/infrastructure_manager.ex", __DIR__)
Code.require_file("support/test_coordinator.ex", __DIR__)
Code.require_file("support/multi_node_test_helper.ex", __DIR__)
Code.require_file("support/cluster_test_helper.ex", __DIR__)
Code.require_file("support/horde_stub.ex", __DIR__)
Code.require_file("support/async_helpers.ex", __DIR__)
Code.require_file("support/integration_case.ex", __DIR__)
Code.require_file("support/simple_integration_case.ex", __DIR__)
Code.require_file("support/test_agent.ex", __DIR__)

# Stop the arbor_core application if it's running to avoid conflicts
Application.stop(:arbor_core)

# Clean up any leftover infrastructure from previous test runs
Arbor.Test.Support.TestCleanup.cleanup_all()

# Start the infrastructure manager (singleton for all integration tests)
# This must be started before ExUnit.start() to be available for setup_all callbacks
{:ok, _} =
  GenServer.start(Arbor.Test.Support.InfrastructureManager, :ok,
    name: Arbor.Test.Support.InfrastructureManager
  )

# Start ExUnit, which configures the test run
ExUnit.start(exclude: exclude_tags, async: async_mode)

# Start HordeStub for tests that need it. This runs as part of the test setup.
# The HordeStub is defined in the support file loaded above.
# Only start HordeStub for fast unit tests (not integration or distributed)
should_use_horde_stub = :integration in exclude_tags and not run_distributed_tests

if should_use_horde_stub do
  # In a real application, we might use a config flag to switch between
  # real Horde and the stub, but for now, we start it directly.
  # The name is registered, so tests can use it.
  {:ok, _} = Arbor.Core.Test.HordeStub.start_link([])
end
