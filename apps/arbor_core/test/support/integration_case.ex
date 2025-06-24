defmodule Arbor.Test.Support.IntegrationCase do
  @moduledoc """
  Provides centralized infrastructure setup for integration tests.

  This module eliminates race conditions by ensuring only one setup per test suite
  and providing clean isolation between tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false

      import Arbor.Test.Support.IntegrationCase
      alias Arbor.Test.Support.AsyncHelpers

      # Common test configuration
      @moduletag :integration
      @moduletag timeout: 30_000

      # Standard registry and supervisor names
      @registry_name Arbor.Core.HordeAgentRegistry
      @supervisor_name Arbor.Core.HordeAgentSupervisor
    end
  end

  setup_all do
    ensure_infrastructure()

    on_exit(fn ->
      cleanup_infrastructure()
    end)

    :ok
  end

  setup do
    # Clean state before each test
    cleanup_test_agents()

    # Wait for cleanup to stabilize
    wait_for_clean_state()

    :ok
  end

  @doc """
  Ensures all required infrastructure is running with proper coordination.
  """
  def ensure_infrastructure do
    # Start distributed Erlang with unique name per test suite
    node_name = "arbor_integration_#{System.unique_integer([:positive])}@localhost"

    case :net_kernel.start([String.to_atom(node_name), :shortnames]) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        :ok

      {:error, reason} ->
        IO.puts("Warning: Could not start distributed Erlang: #{inspect(reason)}")
        :ok
    end

    # Start Phoenix.PubSub if not running
    case GenServer.whereis(Arbor.Core.PubSub) do
      nil ->
        {:ok, _} = start_supervised({Phoenix.PubSub, name: Arbor.Core.PubSub})

      _pid ->
        :ok
    end

    # Start HordeSupervisor infrastructure
    if Process.whereis(Arbor.Core.HordeSupervisorSupervisor) == nil do
      case Arbor.Core.HordeSupervisor.start_supervisor() do
        {:ok, _} ->
          :ok

        {:error, {:already_started, _}} ->
          :ok

        {:error, reason} ->
          raise "Failed to start Horde supervisor: #{inspect(reason)}"
      end
    end

    # Start AgentReconciler if needed
    case GenServer.whereis(Arbor.Core.AgentReconciler) do
      nil ->
        {:ok, _} = start_supervised(Arbor.Core.AgentReconciler)

      _pid ->
        :ok
    end

    # Configure cluster membership
    setup_cluster_membership()

    # Wait for stabilization
    wait_for_infrastructure_ready()

    :ok
  end

  @doc """
  Sets up cluster membership for single-node testing.
  """
  def setup_cluster_membership do
    current_node = node()

    # Set cluster members for registries and supervisor
    Horde.Cluster.set_members(
      Arbor.Core.HordeAgentRegistry,
      [{Arbor.Core.HordeAgentRegistry, current_node}]
    )

    Horde.Cluster.set_members(
      Arbor.Core.HordeCheckpointRegistry,
      [{Arbor.Core.HordeCheckpointRegistry, current_node}]
    )

    Horde.Cluster.set_members(
      Arbor.Core.HordeAgentSupervisor,
      [{Arbor.Core.HordeAgentSupervisor, current_node}]
    )
  end

  @doc """
  Waits for infrastructure to be ready and stable.
  """
  def wait_for_infrastructure_ready do
    # Wait for processes to be registered
    Arbor.Test.Support.AsyncHelpers.wait_until(
      fn ->
        pubsub_ready = GenServer.whereis(Arbor.Core.PubSub) != nil
        registry_ready = GenServer.whereis(Arbor.Core.HordeAgentRegistry) != nil
        supervisor_ready = GenServer.whereis(Arbor.Core.HordeAgentSupervisor) != nil
        reconciler_ready = GenServer.whereis(Arbor.Core.AgentReconciler) != nil

        pubsub_ready and registry_ready and supervisor_ready and reconciler_ready
      end,
      timeout: 5000,
      initial_delay: 50
    )

    # Wait for cluster membership to stabilize
    wait_for_cluster_membership()

    # Wait for ETS tables to be created
    wait_for_ets_tables()
  end

  @doc """
  Waits for Horde cluster membership to be ready.
  """
  def wait_for_cluster_membership do
    current_node = node()

    Arbor.Test.Support.AsyncHelpers.wait_until(
      fn ->
        registry_members = Horde.Cluster.members(Arbor.Core.HordeAgentRegistry)
        supervisor_members = Horde.Cluster.members(Arbor.Core.HordeAgentSupervisor)

        registry_ready =
          Enum.any?(registry_members, fn
            {Arbor.Core.HordeAgentRegistry, node} when node == current_node -> true
            {node, node} when node == current_node -> true
            member when is_atom(member) and member == current_node -> true
            _ -> false
          end)

        supervisor_ready =
          Enum.any?(supervisor_members, fn
            {Arbor.Core.HordeAgentSupervisor, node} when node == current_node -> true
            {node, node} when node == current_node -> true
            member when is_atom(member) and member == current_node -> true
            _ -> false
          end)

        registry_ready and supervisor_ready
      end,
      timeout: 5000,
      initial_delay: 50
    )
  end

  @doc """
  Waits for Horde ETS tables to be created.
  """
  def wait_for_ets_tables do
    keys_table = :"keys_Elixir.Arbor.Core.HordeAgentRegistry"

    Arbor.Test.Support.AsyncHelpers.wait_until(
      fn ->
        :ets.info(keys_table) != :undefined
      end,
      timeout: 2000,
      initial_delay: 50
    )
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
        if is_binary(agent_id) and is_test_agent_id?(agent_id) do
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
        if is_binary(agent_id) and is_test_agent_id?(agent_id) do
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
              is_binary(agent_id) and is_test_agent_id?(agent_id)
            end)
        end
      end,
      timeout: 3000,
      initial_delay: 50
    )
  end

  @doc """
  Cleans up infrastructure on test suite completion.
  """
  def cleanup_infrastructure do
    # Stop distributed Erlang if we started it
    try do
      :net_kernel.stop()
    catch
      :exit, _ -> :ok
    end
  end

  # Private helper to identify test agent IDs
  defp is_test_agent_id?(agent_id) when is_binary(agent_id) do
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

  defp is_test_agent_id?(_), do: false
end
