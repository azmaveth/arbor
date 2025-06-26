defmodule Arbor.Core.SimulatedMultiNodeTest do
  @moduledoc """
  Simulated multi-node tests for cluster fault tolerance.

  These tests validate the declarative supervision architecture
  using mocks and simulated node failures rather than actual
  OS processes. This provides reliable testing without the
  complexity of true multi-node setup.
  """

  use ExUnit.Case, async: false

  alias Arbor.Core.{AgentReconciler, HordeSupervisor}
  alias Arbor.Test.Support.AsyncHelpers

  @moduletag :distributed

  @registry_name Arbor.Core.HordeAgentRegistry
  @supervisor_name Arbor.Core.HordeAgentSupervisor

  setup_all do
    # Ensure Horde infrastructure is running
    ensure_horde_infrastructure()

    # Start AgentReconciler if not running
    case GenServer.whereis(AgentReconciler) do
      nil -> start_supervised!(AgentReconciler)
      _pid -> :ok
    end

    :ok
  end

  setup do
    # Start with a clean slate
    on_exit(fn ->
      # Clean up any running agents
      case HordeSupervisor.list_agents() do
        {:ok, agents} ->
          Enum.each(agents, fn agent ->
            HordeSupervisor.stop_agent(agent.id)
          end)

        _ ->
          :ok
      end
    end)

    :ok
  end

  describe "agent specification persistence" do
    test "agent specs persist in registry even when process dies" do
      agent_id = "test-persistence-#{System.unique_integer([:positive])}"

      # Start agent with permanent strategy
      agent_spec = %{
        id: agent_id,
        module: Arbor.Test.Mocks.TestAgent,
        args: [agent_id: agent_id],
        restart_strategy: :permanent
      }

      assert {:ok, pid} = HordeSupervisor.start_agent(agent_spec)

      # Verify spec is in registry
      assert {:ok, stored_spec} = HordeSupervisor.lookup_agent_spec(agent_id)
      assert stored_spec.module == Arbor.Test.Mocks.TestAgent
      assert stored_spec.restart_strategy == :permanent

      # Kill the agent process using proper supervisor termination
      Horde.DynamicSupervisor.terminate_child(Arbor.Core.HordeAgentSupervisor, pid)

      # Spec should still exist in registry
      assert {:ok, _spec} = HordeSupervisor.lookup_agent_spec(agent_id)

      # Force reconciliation to trigger restart (since we disabled Horde auto-restart)
      AgentReconciler.force_reconcile()

      # Wait for reconciler to restart it
      assert_eventually(
        fn ->
          case HordeSupervisor.get_agent_info(agent_id) do
            {:ok, info} when info.pid != pid ->
              if Process.alive?(info.pid) do
                {:ok, info}
              else
                :retry
              end

            _ ->
              :retry
          end
        end,
        10_000,
        "Agent should be restarted"
      )

      # Agent should be running again with different PID
      {:ok, agent_info} = HordeSupervisor.get_agent_info(agent_id)
      assert agent_info.pid != pid
      assert Process.alive?(agent_info.pid)

      # Clean up
      HordeSupervisor.stop_agent(agent_id)
    end

    test "multiple agents reconcile after simulated failures" do
      agent_count = 3
      agent_prefix = "test-multi-reconcile"
      test_id = System.unique_integer([:positive])

      # Start multiple agents
      agent_ids =
        for i <- 1..agent_count do
          agent_id = "#{agent_prefix}-#{test_id}-#{i}"

          agent_spec = %{
            id: agent_id,
            module: Arbor.Test.Mocks.TestAgent,
            args: [agent_id: agent_id, index: i],
            restart_strategy: :permanent
          }

          assert {:ok, _pid} = HordeSupervisor.start_agent(agent_spec)
          agent_id
        end

      # Get initial PIDs
      initial_pids =
        Enum.map(agent_ids, fn agent_id ->
          {:ok, info} = HordeSupervisor.get_agent_info(agent_id)
          {agent_id, info.pid}
        end)

      # Kill all agents using proper supervisor termination
      Enum.each(initial_pids, fn {_agent_id, pid} ->
        Horde.DynamicSupervisor.terminate_child(Arbor.Core.HordeAgentSupervisor, pid)
      end)

      # Specs should still exist
      Enum.each(agent_ids, fn agent_id ->
        assert {:ok, _spec} = HordeSupervisor.lookup_agent_spec(agent_id)
      end)

      # Force reconciliation
      AgentReconciler.force_reconcile()

      # Wait for all agents to be restarted
      assert_eventually(
        fn ->
          all_restarted =
            Enum.all?(initial_pids, fn {agent_id, old_pid} ->
              case HordeSupervisor.get_agent_info(agent_id) do
                {:ok, info} when info.pid != old_pid ->
                  Process.alive?(info.pid)

                _ ->
                  false
              end
            end)

          if all_restarted, do: :ok, else: :retry
        end,
        10_000,
        "All agents should be restarted by reconciler"
      )

      # Verify all agents are running with new PIDs
      Enum.each(initial_pids, fn {agent_id, old_pid} ->
        {:ok, agent_info} = HordeSupervisor.get_agent_info(agent_id)
        assert agent_info.pid != old_pid
        assert Process.alive?(agent_info.pid)
      end)

      # Clean up
      Enum.each(agent_ids, &HordeSupervisor.stop_agent/1)
    end
  end

  describe "reconciler behavior" do
    test "reconciler detects and restarts missing agents" do
      agent_id = "test-reconciler-restart-#{System.unique_integer([:positive])}"

      # First, register just the spec without starting the process
      spec_metadata = %{
        module: Arbor.Test.Mocks.TestAgent,
        args: [agent_id: agent_id],
        restart_strategy: :permanent,
        metadata: %{},
        created_at: System.system_time(:millisecond)
      }

      # Use private function to register spec only
      spec_key = {:agent_spec, agent_id}
      {:ok, _} = Horde.Registry.register(@registry_name, spec_key, spec_metadata)

      # Verify spec exists but no agent is running
      assert {:ok, _spec} = HordeSupervisor.lookup_agent_spec(agent_id)
      assert {:error, :not_found} = HordeSupervisor.get_agent_info(agent_id)

      # Force reconciliation
      AgentReconciler.force_reconcile()

      # Wait for agent to be started by reconciler
      assert_eventually(
        fn ->
          case HordeSupervisor.get_agent_info(agent_id) do
            {:ok, info} ->
              if Process.alive?(info.pid) do
                {:ok, info}
              else
                :retry
              end

            {:error, :not_found} ->
              # Force reconcile again and wait briefly
              AgentReconciler.force_reconcile()
              Process.sleep(200)
              :retry
          end
        end,
        15_000,
        "Agent should be started by reconciler"
      )

      # Agent should be running
      {:ok, agent_info} = HordeSupervisor.get_agent_info(agent_id)
      assert Process.alive?(agent_info.pid)

      # Clean up
      HordeSupervisor.stop_agent(agent_id)
    end

    test "reconciler cleans up orphaned processes" do
      agent_id = "test-reconciler-cleanup-#{System.unique_integer([:positive])}"

      # Start an agent normally to ensure it's a child of the supervisor
      agent_spec = %{
        id: agent_id,
        module: Arbor.Test.Mocks.TestAgent,
        args: [agent_id: agent_id],
        restart_strategy: :temporary
      }

      assert {:ok, orphan_pid} = HordeSupervisor.start_agent(agent_spec)

      # Now, make it an orphan by deleting its spec
      spec_key = {:agent_spec, agent_id}
      :ok = Horde.Registry.unregister(@registry_name, spec_key)

      # Verify it's running but has no spec
      assert Process.alive?(orphan_pid)
      assert {:ok, ^orphan_pid, _} = Arbor.Core.HordeRegistry.lookup_agent_name(agent_id)
      assert {:error, :not_found} = HordeSupervisor.lookup_agent_spec(agent_id)

      # Force reconciliation
      AgentReconciler.force_reconcile()

      # Wait for orphan to be cleaned up
      assert_eventually(
        fn ->
          if Process.alive?(orphan_pid) do
            :retry
          else
            :ok
          end
        end,
        10_000,
        "Orphaned process should be terminated by reconciler"
      )

      # Process should be terminated and unregistered
      refute Process.alive?(orphan_pid)
      assert {:error, :not_registered} = Arbor.Core.HordeRegistry.lookup_agent_name(agent_id)
    end
  end

  describe "centralized registration" do
    test "agents do not self-register" do
      agent_id = "test-no-self-register-#{System.unique_integer([:positive])}"

      # Start agent directly (not through supervisor)
      {:ok, pid} = Arbor.Test.Mocks.TestAgent.start_link(agent_id: agent_id)

      # Agent should NOT be in registry
      assert {:error, :not_registered} = Arbor.Core.HordeRegistry.lookup_agent_name(agent_id)

      # Clean up the standalone agent
      GenServer.stop(pid)
    end

    test "supervisor handles all registration" do
      agent_id = "test-supervisor-register-#{System.unique_integer([:positive])}"

      agent_spec = %{
        id: agent_id,
        module: Arbor.Test.Mocks.TestAgent,
        args: [agent_id: agent_id],
        restart_strategy: :temporary
      }

      assert {:ok, pid} = HordeSupervisor.start_agent(agent_spec)

      # Should be registered by supervisor
      assert {:ok, ^pid, metadata} = Arbor.Core.HordeRegistry.lookup_agent_name(agent_id)
      assert metadata.module == Arbor.Test.Mocks.TestAgent

      # Stop through supervisor
      assert :ok = HordeSupervisor.stop_agent(agent_id)

      # Should be unregistered
      assert {:error, :not_registered} = Arbor.Core.HordeRegistry.lookup_agent_name(agent_id)
    end
  end

  # Helper functions

  defp assert_eventually(fun, timeout \\ 5000, message \\ "Condition not met") do
    deadline = System.monotonic_time(:millisecond) + timeout

    assert_eventually_loop(fun, deadline, message)
  end

  defp assert_eventually_loop(fun, deadline, message) do
    case fun.() do
      :retry ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          assert_eventually_loop(fun, deadline, message)
        else
          flunk(message)
        end

      result ->
        result
    end
  end

  defp ensure_horde_infrastructure do
    # Start Phoenix.PubSub if not running
    case GenServer.whereis(Arbor.Core.PubSub) do
      nil ->
        {:ok, _} = start_supervised({Phoenix.PubSub, name: Arbor.Core.PubSub})

      _pid ->
        :ok
    end

    # Start HordeSupervisor infrastructure if not running
    if Process.whereis(Arbor.Core.HordeSupervisorSupervisor) == nil do
      HordeSupervisor.start_supervisor()
    end

    # Set members for single-node test environment. This is still necessary
    # to configure Horde for the test context.
    Horde.Cluster.set_members(@registry_name, [{@registry_name, node()}])
    Horde.Cluster.set_members(@supervisor_name, [{@supervisor_name, node()}])

    # Wait for Horde components to stabilize
    wait_for_membership_ready()
  end

  defp wait_for_membership_ready(timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_for_membership_loop(deadline)
  end

  defp wait_for_membership_loop(deadline) do
    # Use AsyncHelpers for exponential backoff membership check
    timeout = deadline - System.monotonic_time(:millisecond)

    try do
      AsyncHelpers.wait_until(
        fn ->
          registry_members = Horde.Cluster.members(@registry_name)
          supervisor_members = Horde.Cluster.members(@supervisor_name)
          current_node = node()

          # Check for proper named members in the new format
          expected_registry_member = {@registry_name, current_node}
          expected_supervisor_member = {@supervisor_name, current_node}

          registry_ready =
            expected_registry_member in registry_members or
              {expected_registry_member, expected_registry_member} in registry_members

          supervisor_ready =
            expected_supervisor_member in supervisor_members or
              {expected_supervisor_member, expected_supervisor_member} in supervisor_members

          if registry_ready and supervisor_ready do
            IO.puts("  -> Horde membership is ready.")
            true
          else
            false
          end
        end,
        timeout: max(timeout, 100),
        initial_delay: 100
      )

      # Additional stabilization wait for distributed supervisor CRDT sync
      AsyncHelpers.wait_until(
        fn ->
          case Horde.DynamicSupervisor.which_children(@supervisor_name) do
            [] ->
              true

            children ->
              # Accept any tracked children count
              length(children) >= 0
          end
        end,
        timeout: 1000,
        initial_delay: 50
      )

      :ok
    rescue
      _e in ExUnit.AssertionError ->
        registry_members = Horde.Cluster.members(@registry_name)
        supervisor_members = Horde.Cluster.members(@supervisor_name)

        message = """
        Timed out waiting for Horde membership synchronization.
        - Current Node: #{inspect(node())}
        - Registry Members: #{inspect(registry_members)}
        - Supervisor Members: #{inspect(supervisor_members)}
        """

        reraise RuntimeError, [message: message], __STACKTRACE__
    end
  end
end
