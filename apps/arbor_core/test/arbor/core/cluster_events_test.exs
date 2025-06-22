defmodule Arbor.Core.ClusterEventsTest do
  @moduledoc """
  Tests for cluster-wide event broadcasting using Phoenix.PubSub.
  
  Validates that agent lifecycle events and reconciliation events
  are properly broadcast across the cluster.
  """
  
  use ExUnit.Case, async: false
  
  @moduletag :integration
  @moduletag timeout: 30_000
  
  alias Arbor.Core.{ClusterEvents, HordeSupervisor, AgentReconciler}
  
  # Test configuration
  @registry_name Arbor.Core.HordeAgentRegistry
  @supervisor_name Arbor.Core.HordeAgentSupervisor
  
  setup_all do
    # Start distributed Erlang if not already started
    case :net_kernel.start([:arbor_cluster_events_test@localhost, :shortnames]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> 
        IO.puts("Warning: Could not start distributed Erlang: #{inspect(reason)}")
        :ok
    end
    
    # Ensure required infrastructure is running
    ensure_infrastructure()
    
    on_exit(fn ->
      cleanup_all_test_agents()
    end)
    
    :ok
  end
  
  setup do
    # Clean state before each test
    cleanup_all_test_agents()
    :timer.sleep(200)
    
    :ok
  end
  
  describe "agent lifecycle events" do
    test "broadcasts agent_started events when agents are created" do
      agent_id = "test-cluster-events-start-#{System.unique_integer([:positive])}"
      
      # Subscribe to agent events
      :ok = ClusterEvents.subscribe(:agent_events)
      
      # Start an agent
      agent_spec = %{
        id: agent_id,
        module: ClusterTestAgent,
        args: [agent_id: agent_id],
        restart_strategy: :permanent
      }
      
      assert {:ok, pid} = HordeSupervisor.start_agent(agent_spec)
      
      # Verify we receive the cluster event
      assert_receive {:cluster_event, :agent_started, event_data}, 1000
      
      assert event_data.agent_id == agent_id
      assert event_data.pid == pid
      assert event_data.node == node()
      assert event_data.module == ClusterTestAgent
      assert event_data.restart_strategy == :permanent
      assert is_integer(event_data.timestamp)
      assert event_data.event_type == :agent_started
      
      # Cleanup
      HordeSupervisor.stop_agent(agent_id)
      ClusterEvents.unsubscribe(:agent_events)
    end
    
    test "broadcasts agent_stopped events when agents are stopped" do
      agent_id = "test-cluster-events-stop-#{System.unique_integer([:positive])}"
      
      # Start an agent first
      agent_spec = %{
        id: agent_id,
        module: ClusterTestAgent,
        args: [agent_id: agent_id],
        restart_strategy: :temporary
      }
      
      assert {:ok, pid} = HordeSupervisor.start_agent(agent_spec)
      
      # Subscribe to agent events
      :ok = ClusterEvents.subscribe(:agent_events)
      
      # Stop the agent
      :ok = HordeSupervisor.stop_agent(agent_id)
      
      # Verify we receive the cluster event
      assert_receive {:cluster_event, :agent_stopped, event_data}, 1000
      
      assert event_data.agent_id == agent_id
      assert event_data.pid == pid
      assert event_data.node == node()
      assert is_integer(event_data.timestamp)
      assert event_data.event_type == :agent_stopped
      
      # Cleanup
      ClusterEvents.unsubscribe(:agent_events)
    end
    
    test "broadcasts agent_restarted events during reconciliation" do
      agent_id = "test-cluster-events-restart-#{System.unique_integer([:positive])}"
      
      # Subscribe to agent events
      :ok = ClusterEvents.subscribe(:agent_events)
      
      # Start an agent
      agent_spec = %{
        id: agent_id,
        module: ClusterTestAgent,
        args: [agent_id: agent_id],
        restart_strategy: :permanent
      }
      
      assert {:ok, original_pid} = HordeSupervisor.start_agent(agent_spec)
      
      # Clear the start event
      assert_receive {:cluster_event, :agent_started, _}, 1000
      
      # Kill the agent to trigger reconciliation restart
      Process.exit(original_pid, :kill)
      :timer.sleep(100)
      
      # Force reconciliation
      AgentReconciler.force_reconcile()
      
      # Verify we receive the restart event
      assert_receive {:cluster_event, :agent_restarted, event_data}, 2000
      
      assert event_data.agent_id == agent_id
      assert event_data.module == ClusterTestAgent
      assert event_data.restart_strategy == :permanent
      assert is_integer(event_data.restart_duration_ms)
      assert is_integer(event_data.memory_usage)
      assert event_data.event_type == :agent_restarted
      
      # Cleanup
      HordeSupervisor.stop_agent(agent_id)
      ClusterEvents.unsubscribe(:agent_events)
    end
    
    test "supports agent-specific event subscriptions" do
      agent1_id = "test-specific-events-1-#{System.unique_integer([:positive])}"
      agent2_id = "test-specific-events-2-#{System.unique_integer([:positive])}"
      
      # Subscribe to events for agent1 only
      :ok = ClusterEvents.subscribe(:agent_events, agent_id: agent1_id)
      
      # Start both agents
      agent1_spec = %{
        id: agent1_id,
        module: ClusterTestAgent,
        args: [agent_id: agent1_id],
        restart_strategy: :permanent
      }
      
      agent2_spec = %{
        id: agent2_id,
        module: ClusterTestAgent,
        args: [agent_id: agent2_id],
        restart_strategy: :permanent
      }
      
      {:ok, _pid1} = HordeSupervisor.start_agent(agent1_spec)
      {:ok, _pid2} = HordeSupervisor.start_agent(agent2_spec)
      
      # Should only receive events for agent1
      assert_receive {:cluster_event, :agent_started, event_data}, 1000
      assert event_data.agent_id == agent1_id
      
      # Should not receive events for agent2
      refute_receive {:cluster_event, :agent_started, %{agent_id: ^agent2_id}}, 500
      
      # Cleanup
      HordeSupervisor.stop_agent(agent1_id)
      HordeSupervisor.stop_agent(agent2_id)
      ClusterEvents.unsubscribe(:agent_events, agent_id: agent1_id)
    end
  end
  
  describe "reconciliation events" do
    test "broadcasts reconciliation_started and reconciliation_completed events" do
      # Subscribe to reconciliation events
      :ok = ClusterEvents.subscribe(:reconciliation_events)
      
      # Force a reconciliation
      AgentReconciler.force_reconcile()
      
      # Verify we receive both events
      assert_receive {:cluster_event, :reconciliation_started, start_event}, 1000
      assert start_event.reconciler == AgentReconciler
      assert start_event.event_type == :reconciliation_started
      
      assert_receive {:cluster_event, :reconciliation_completed, complete_event}, 2000
      assert complete_event.reconciler == AgentReconciler
      assert complete_event.event_type == :reconciliation_completed
      assert is_integer(complete_event.duration_ms)
      assert is_number(complete_event.reconciliation_efficiency)
      
      # Cleanup
      ClusterEvents.unsubscribe(:reconciliation_events)
    end
  end
  
  describe "cluster event utilities" do
    test "get_stats returns cluster information" do
      stats = ClusterEvents.get_stats()
      
      assert is_map(stats.active_topics)
      assert stats.node == node()
      assert is_binary(stats.cluster_id)
      assert stats.pubsub_name == Arbor.Core.PubSub
    end
    
    test "subscriber_count returns counts for topics" do
      # Note: Phoenix.PubSub doesn't expose subscriber counts directly
      # so this should return 0 for now
      assert ClusterEvents.subscriber_count(:agent_events) == 0
      assert ClusterEvents.subscriber_count(:cluster_events) == 0
      assert ClusterEvents.subscriber_count(:reconciliation_events) == 0
    end
    
    test "list_active_topics returns topic information" do
      topics = ClusterEvents.list_active_topics()
      
      assert Map.has_key?(topics, "agent_events")
      assert Map.has_key?(topics, "cluster_events")
      assert Map.has_key?(topics, "reconciliation_events")
    end
  end
  
  describe "event telemetry" do
    test "cluster event broadcasts emit telemetry" do
      # Capture telemetry events
      test_pid = self()
      handler_id = :cluster_events_telemetry_test
      
      :telemetry.attach(
        handler_id,
        [:arbor, :cluster_events, :broadcast],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )
      
      # Broadcast an event
      ClusterEvents.broadcast(:agent_started, %{
        agent_id: "test-telemetry-agent",
        pid: self(),
        module: ClusterTestAgent
      })
      
      # Verify telemetry was emitted
      assert_receive {:telemetry, [:arbor, :cluster_events, :broadcast], measurements, metadata}
      assert measurements.event_count == 1
      assert metadata.event_type == :agent_started
      assert metadata.agent_id == "test-telemetry-agent"
      assert metadata.node == node()
      
      # Cleanup
      :telemetry.detach(handler_id)
    end
  end
  
  # Helper functions
  
  defp ensure_infrastructure do
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
    
    # Start AgentReconciler if not running
    case GenServer.whereis(AgentReconciler) do
      nil -> start_supervised!(AgentReconciler)
      _pid -> :ok
    end
    
    # Wait for Horde components to stabilize
    :timer.sleep(500)
    
    :ok
  end
  
  defp cleanup_all_test_agents do
    # Get all running children and stop test agents
    try do
      children = Horde.DynamicSupervisor.which_children(@supervisor_name)
      for {agent_id, _pid, _type, _modules} <- children do
        if is_binary(agent_id) and String.contains?(agent_id, "test-") do
          HordeSupervisor.stop_agent(agent_id)
        end
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
    
    # Clean up any remaining specs
    try do
      pattern = {{:agent_spec, :"$1"}, :"$2", :"$3"}
      guard = []
      body = [:"$1"]
      
      specs = Horde.Registry.select(@registry_name, [{pattern, guard, body}])
      for agent_id <- specs do
        if is_binary(agent_id) and String.contains?(agent_id, "test-") do
          spec_key = {:agent_spec, agent_id}
          Horde.Registry.unregister(@registry_name, spec_key)
        end
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end
end

# Test agent for cluster events testing
defmodule ClusterTestAgent do
  use GenServer
  
  alias Arbor.Core.HordeRegistry
  
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end
  
  def init(args) do
    agent_id = Keyword.get(args, :agent_id)
    
    state = %{
      agent_id: agent_id,
      started_at: System.system_time(:millisecond)
    }
    
    # Self-register in HordeRegistry if agent_id is provided
    if agent_id do
      runtime_metadata = %{started_at: state.started_at}
      case HordeRegistry.register_agent_name(agent_id, self(), runtime_metadata) do
        {:ok, _} -> :ok
        error -> 
          IO.puts("Agent registration failed: #{inspect error}")
      end
    end
    
    {:ok, state}
  end
  
  def terminate(_reason, state) do
    if state.agent_id do
      HordeRegistry.unregister_agent_name(state.agent_id)
    end
    :ok
  end
end