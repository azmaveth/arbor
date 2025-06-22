defmodule Arbor.Core.SimulatedMultiNodeTest do
  @moduledoc """
  Simulated multi-node tests for cluster fault tolerance.
  
  These tests validate the declarative supervision architecture
  using mocks and simulated node failures rather than actual
  OS processes. This provides reliable testing without the
  complexity of true multi-node setup.
  """
  
  use ExUnit.Case, async: false
  
  alias Arbor.Core.{HordeSupervisor, AgentReconciler}
  
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
        _ -> :ok
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
        module: TestAgent,
        args: [agent_id: agent_id],
        restart_strategy: :permanent
      }
      
      assert {:ok, pid} = HordeSupervisor.start_agent(agent_spec)
      
      # Verify spec is in registry
      assert {:ok, stored_spec} = HordeSupervisor.lookup_agent_spec(agent_id)
      assert stored_spec.module == TestAgent
      assert stored_spec.restart_strategy == :permanent
      
      # Kill the agent process directly
      Process.exit(pid, :kill)
      
      # Spec should still exist in registry
      assert {:ok, _spec} = HordeSupervisor.lookup_agent_spec(agent_id)
      
      # Force reconciliation to trigger restart (since we disabled Horde auto-restart)
      AgentReconciler.force_reconcile()
      
      # Wait for reconciler to restart it
      assert_eventually(fn ->
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
      end, 10_000, "Agent should be restarted")
      
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
      agent_ids = for i <- 1..agent_count do
        agent_id = "#{agent_prefix}-#{test_id}-#{i}"
        
        agent_spec = %{
          id: agent_id,
          module: TestAgent,
          args: [agent_id: agent_id, index: i],
          restart_strategy: :permanent
        }
        
        assert {:ok, _pid} = HordeSupervisor.start_agent(agent_spec)
        agent_id
      end
      
      # Get initial PIDs
      initial_pids = Enum.map(agent_ids, fn agent_id ->
        {:ok, info} = HordeSupervisor.get_agent_info(agent_id)
        {agent_id, info.pid}
      end)
      
      # Kill all agents
      Enum.each(initial_pids, fn {_agent_id, pid} ->
        Process.exit(pid, :kill)
      end)
      
      # Specs should still exist
      Enum.each(agent_ids, fn agent_id ->
        assert {:ok, _spec} = HordeSupervisor.lookup_agent_spec(agent_id)
      end)
      
      # Force reconciliation
      AgentReconciler.force_reconcile()
      
      # Wait for all agents to be restarted
      assert_eventually(fn ->
        all_restarted = Enum.all?(initial_pids, fn {agent_id, old_pid} ->
          case HordeSupervisor.get_agent_info(agent_id) do
            {:ok, info} when info.pid != old_pid -> 
              Process.alive?(info.pid)
            _ -> 
              false
          end
        end)
        
        if all_restarted, do: :ok, else: :retry
      end, 10_000, "All agents should be restarted by reconciler")
      
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
        module: TestAgent,
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
      assert_eventually(fn ->
        case HordeSupervisor.get_agent_info(agent_id) do
          {:ok, info} -> 
            if Process.alive?(info.pid) do
              {:ok, info}
            else
              :retry
            end
          {:error, :not_found} ->
            # Force reconcile again
            AgentReconciler.force_reconcile()
            :timer.sleep(200)
            :retry
        end
      end, 15_000, "Agent should be started by reconciler")
      
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
        module: TestAgent,
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
      assert_eventually(fn ->
        if Process.alive?(orphan_pid) do
          :retry
        else
          :ok
        end
      end, 10_000, "Orphaned process should be terminated by reconciler")
      
      # Process should be terminated and unregistered
      refute Process.alive?(orphan_pid)
      assert {:error, :not_registered} = Arbor.Core.HordeRegistry.lookup_agent_name(agent_id)
    end
  end
  
  describe "centralized registration" do
    test "agents do not self-register" do
      agent_id = "test-no-self-register-#{System.unique_integer([:positive])}"
      
      # Start agent directly (not through supervisor)
      {:ok, pid} = TestAgent.start_link(agent_id: agent_id)
      
      # Agent should NOT be in registry
      assert {:error, :not_registered} = Arbor.Core.HordeRegistry.lookup_agent_name(agent_id)
      
      # Clean up
      Process.exit(pid, :normal)
    end
    
    test "supervisor handles all registration" do
      agent_id = "test-supervisor-register-#{System.unique_integer([:positive])}"
      
      agent_spec = %{
        id: agent_id,
        module: TestAgent,
        args: [agent_id: agent_id],
        restart_strategy: :temporary
      }
      
      assert {:ok, pid} = HordeSupervisor.start_agent(agent_spec)
      
      # Should be registered by supervisor
      assert {:ok, ^pid, metadata} = Arbor.Core.HordeRegistry.lookup_agent_name(agent_id)
      assert metadata.module == TestAgent
      
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
          :timer.sleep(100)
          assert_eventually_loop(fun, deadline, message)
        else
          flunk(message)
        end
      result ->
        result
    end
  end
  
  defp ensure_horde_infrastructure do
    # Start Horde.Registry if not running
    case GenServer.whereis(@registry_name) do
      nil ->
        {:ok, _} = start_supervised({Horde.Registry, [
          name: @registry_name,
          keys: :unique,
          members: :auto,
          delta_crdt_options: [sync_interval: 100]
        ]})
      _pid -> :ok
    end
    
    # Start Horde.DynamicSupervisor if not running  
    case GenServer.whereis(@supervisor_name) do
      nil ->
        {:ok, _} = start_supervised({Horde.DynamicSupervisor, [
          name: @supervisor_name,
          strategy: :one_for_one,
          distribution_strategy: Horde.UniformRandomDistribution,
          process_redistribution: :active,
          members: :auto,
          delta_crdt_options: [sync_interval: 100]
        ]})
      _pid -> :ok
    end
    
    # Wait for Horde components to stabilize
    :timer.sleep(500)
  end
end

# Simple test agent
defmodule TestAgent do
  use GenServer
  
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end
  
  def init(args) do
    state = %{
      agent_id: Keyword.get(args, :agent_id),
      index: Keyword.get(args, :index, 0),
      started_at: System.system_time(:millisecond)
    }
    
    # No self-registration - handled by supervisor
    {:ok, state}
  end
  
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end
  
  def terminate(_reason, _state) do
    # No self-cleanup - handled by supervisor
    :ok
  end
end