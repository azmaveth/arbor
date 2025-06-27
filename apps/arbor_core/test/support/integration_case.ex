defmodule Arbor.Test.Support.IntegrationCase do
  @moduledoc """
  Provides centralized infrastructure setup for integration tests.

  This module uses a singleton InfrastructureManager to ensure infrastructure
  is started exactly once for the entire test suite, eliminating race conditions
  and providing clean isolation between tests.

  ## Architecture

  - Infrastructure is started once and shared across all integration tests
  - Each test module registers/unregisters its usage
  - Individual tests clean up their own agents/state
  - Infrastructure is torn down when last test module completes
  """

  use ExUnit.CaseTemplate
  require Logger

  alias Arbor.Test.Support.InfrastructureManager

  using do
    quote do
      use ExUnit.Case, async: false

      import Arbor.Test.Support.IntegrationCase
      alias Arbor.Test.Support.{AsyncHelpers, TestCoordinator}

      # Common test configuration
      @moduletag :integration
      @moduletag timeout: 30_000

      # Standard registry and supervisor names
      @registry_name Arbor.Core.HordeAgentRegistry
      @supervisor_name Arbor.Core.HordeAgentSupervisor

      # Test-specific namespace for isolation
      @test_namespace TestCoordinator.unique_test_id()
    end
  end

  setup_all context do
    # Use the singleton infrastructure manager
    :ok = InfrastructureManager.ensure_started()

    # Register this test module as a user
    # Use the actual test module from context, not IntegrationCase module
    test_module = context.module
    cleanup_fn = InfrastructureManager.register_user(test_module)

    on_exit(cleanup_fn)

    :ok
  end

  setup context do
    # Clean state before each test
    cleanup_test_agents()

    # Wait for cleanup to stabilize
    wait_for_clean_state()

    # Provide test metadata for better debugging
    Logger.metadata(
      test: context.test,
      test_module: context.module,
      test_pid: self()
    )

    :ok
  end

  @doc """
  Cleans up test agents between tests.
  """
  def cleanup_test_agents do
    registry_name = Arbor.Core.HordeAgentRegistry
    supervisor_name = Arbor.Core.HordeAgentSupervisor

    # Stop running test agents
    try do
      children = Horde.DynamicSupervisor.which_children(supervisor_name)

      for {agent_id, _pid, _type, _modules} <- children do
        if is_binary(agent_id) and test_agent_id?(agent_id) do
          Arbor.Core.HordeSupervisor.stop_agent(agent_id)
        end
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    # Clean up registry entries
    try do
      pattern = {{:agent_spec, :"$1"}, :"$2", :"$3"}
      guard = []
      body = [:"$1"]

      specs = Horde.Registry.select(registry_name, [{pattern, guard, body}])

      for agent_id <- specs do
        if is_binary(agent_id) and test_agent_id?(agent_id) do
          spec_key = {:agent_spec, agent_id}
          Horde.Registry.unregister(registry_name, spec_key)

          # Also clean up checkpoint if exists
          checkpoint_key = {:agent_checkpoint, agent_id}
          Horde.Registry.unregister(registry_name, checkpoint_key)
        end
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  @doc """
  Waits for system to reach clean state after cleanup.
  """
  def wait_for_clean_state do
    supervisor_name = Arbor.Core.HordeAgentSupervisor

    Arbor.Test.Support.AsyncHelpers.wait_until(
      fn ->
        case Horde.DynamicSupervisor.which_children(supervisor_name) do
          [] ->
            true

          children ->
            # Check that no test agents remain
            not Enum.any?(children, fn {agent_id, _, _, _} ->
              is_binary(agent_id) and test_agent_id?(agent_id)
            end)
        end
      end,
      timeout: 3000,
      initial_delay: 50
    )
  end

  # Private helper to identify test agent IDs
  defp test_agent_id?(agent_id) when is_binary(agent_id) do
    test_patterns = [
      "test-",
      "telemetry-test",
      "error-test",
      "perf-test",
      "checkpoint",
      "failover",
      "state-",
      "migration-",
      "cluster-",
      "integration-",
      "reconciler-"
    ]

    Enum.any?(test_patterns, fn pattern ->
      String.contains?(agent_id, pattern)
    end)
  end

  defp test_agent_id?(_), do: false
end
