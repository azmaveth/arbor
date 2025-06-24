defmodule Arbor.Core.ClusterCoordinatorTest do
  alias Arbor.Test.Support.AsyncHelpers

  @moduledoc """
  Unit tests for cluster coordination logic using local mocks.

  These tests use MOCK implementations to test cluster coordination logic without
  requiring actual distributed clustering. The real Horde-based coordination
  implementation will be tested in integration tests.

  Cluster coordination involves:
  - Node join/leave event handling
  - Agent redistribution across cluster
  - Cluster state synchronization
  - Load balancing and health monitoring
  """

  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Core.ClusterCoordinator
  alias Arbor.Test.Mocks.LocalCoordinator

  setup do
    # MOCK: Use local coordinator for unit testing
    # Replace with Horde-based coordination for distributed operation

    # Stop any existing coordinator
    existing_pid =
      case Process.whereis(LocalCoordinator) do
        nil ->
          nil

        pid ->
          try do
            GenServer.stop(pid)
            pid
          catch
            :exit, _ -> nil
          end
      end

    # Give a moment for cleanup if we had a process to stop
    if existing_pid do
      AsyncHelpers.wait_until(
        fn ->
          # Verify process is stopped
          not Process.alive?(existing_pid)
        end,
        timeout: 100,
        initial_delay: 10
      )
    end

    # Start fresh coordinator for this test
    {:ok, _pid} = LocalCoordinator.start_link([])

    # Clear any existing state
    LocalCoordinator.clear()

    {:ok, state} = LocalCoordinator.init([])
    %{coordinator_state: state}
  end

  describe "node lifecycle management" do
    test "handles node join events", %{coordinator_state: state} do
      node_info = %{
        node: :worker@node1,
        capacity: 100,
        capabilities: [:worker_agent, :llm_agent],
        resources: %{memory: 8_000_000, cpu_count: 4}
      }

      # MOCK: Use local coordinator for unit testing
      assert :ok = LocalCoordinator.handle_node_join(node_info, state)

      # Verify node is tracked
      assert {:ok, cluster_info} = LocalCoordinator.get_cluster_info(state)
      assert length(cluster_info.nodes) >= 1

      joined_node =
        Enum.find(cluster_info.nodes, fn node ->
          node.node == :worker@node1
        end)

      assert joined_node != nil
      assert joined_node.status == :active
      assert joined_node.capacity == 100
      assert joined_node.capabilities == [:worker_agent, :llm_agent]
    end

    test "handles node leave events", %{coordinator_state: state} do
      # First, join a node
      node_info = %{
        node: :worker@node2,
        capacity: 50,
        capabilities: [:worker_agent],
        resources: %{memory: 4_000_000, cpu_count: 2}
      }

      # MOCK: Use local coordinator for unit testing
      :ok = LocalCoordinator.handle_node_join(node_info, state)

      # Now handle node leave
      assert :ok = LocalCoordinator.handle_node_leave(:worker@node2, :shutdown, state)

      # Verify node is marked as inactive or removed
      assert {:ok, cluster_info} = LocalCoordinator.get_cluster_info(state)

      left_node =
        Enum.find(cluster_info.nodes, fn node ->
          node.node == :worker@node2
        end)

      # Node should either be removed or marked as inactive
      assert left_node == nil or left_node.status == :inactive
    end

    test "handles node failure events", %{coordinator_state: state} do
      # First, join a backup node that can accept migrations
      backup_node = %{
        node: :worker@backup,
        capacity: 100,
        capabilities: [:coordinator_agent],
        resources: %{memory: 8_000_000, cpu_count: 4}
      }

      :ok = LocalCoordinator.handle_node_join(backup_node, state)

      # Join a node with agents
      node_info = %{
        node: :worker@node3,
        capacity: 75,
        capabilities: [:coordinator_agent],
        resources: %{memory: 6_000_000, cpu_count: 3}
      }

      # MOCK: Use local coordinator for unit testing
      :ok = LocalCoordinator.handle_node_join(node_info, state)

      # Add some agents to the node
      agents = [
        %{id: "agent-1", node: :worker@node3, type: :coordinator},
        %{id: "agent-2", node: :worker@node3, type: :coordinator}
      ]

      for agent <- agents do
        :ok = LocalCoordinator.register_agent_on_node(agent, state)
      end

      # Simulate node failure
      assert :ok = LocalCoordinator.handle_node_failure(:worker@node3, :network_timeout, state)

      # Verify redistribution plan is created
      assert {:ok, redistribution_plan} =
               LocalCoordinator.get_redistribution_plan(:worker@node3, state)

      assert length(redistribution_plan.agents_to_migrate) == 2
      assert redistribution_plan.target_nodes != []
    end
  end

  describe "agent redistribution" do
    test "calculates optimal agent distribution", %{coordinator_state: state} do
      # Set up a multi-node cluster
      nodes = [
        %{
          node: :coordinator@node1,
          capacity: 100,
          capabilities: [:coordinator_agent, :worker_agent]
        },
        %{node: :worker@node2, capacity: 80, capabilities: [:worker_agent, :llm_agent]},
        %{node: :worker@node3, capacity: 60, capabilities: [:worker_agent]}
      ]

      # MOCK: Use local coordinator for unit testing
      for node_info <- nodes do
        :ok = LocalCoordinator.handle_node_join(node_info, state)
      end

      # Add agents with different requirements
      agents = [
        %{
          id: "coord-1",
          type: :coordinator_agent,
          priority: :high,
          resources: %{memory: 1000, cpu: 50}
        },
        %{
          id: "worker-1",
          type: :worker_agent,
          priority: :normal,
          resources: %{memory: 500, cpu: 25}
        },
        %{
          id: "worker-2",
          type: :worker_agent,
          priority: :normal,
          resources: %{memory: 500, cpu: 25}
        },
        %{id: "llm-1", type: :llm_agent, priority: :high, resources: %{memory: 2000, cpu: 75}}
      ]

      assert {:ok, distribution_plan} = LocalCoordinator.calculate_distribution(agents, state)

      # Verify distribution respects node capabilities
      for assignment <- distribution_plan.assignments do
        agent = Enum.find(agents, &(&1.id == assignment.agent_id))
        assert assignment.target_node != nil

        # Verify node can handle agent type
        {:ok, cluster_info} = LocalCoordinator.get_cluster_info(state)
        target_node = Enum.find(cluster_info.nodes, &(&1.node == assignment.target_node))
        assert agent.type in target_node.capabilities
      end

      # Verify load balancing
      node_loads = Enum.group_by(distribution_plan.assignments, & &1.target_node)
      # Agents distributed across nodes
      assert map_size(node_loads) > 1
    end

    test "handles agent redistribution on node capacity changes", %{coordinator_state: state} do
      # Set up initial cluster
      node_info = %{
        node: :worker@node1,
        capacity: 100,
        capabilities: [:worker_agent],
        resources: %{memory: 8_000_000, cpu_count: 4}
      }

      # MOCK: Use local coordinator for unit testing
      :ok = LocalCoordinator.handle_node_join(node_info, state)

      # Register agents on the node
      agents = [
        %{id: "agent-1", node: :worker@node1, type: :worker_agent},
        %{id: "agent-2", node: :worker@node1, type: :worker_agent},
        %{id: "agent-3", node: :worker@node1, type: :worker_agent}
      ]

      for agent <- agents do
        :ok = LocalCoordinator.register_agent_on_node(agent, state)
      end

      # Reduce node capacity (simulating high load)
      capacity_update = %{
        node: :worker@node1,
        # Significantly reduced
        new_capacity: 30,
        reason: :high_load
      }

      assert :ok = LocalCoordinator.update_node_capacity(capacity_update, state)

      # Should suggest redistribution
      assert {:ok, redistribution_plan} = LocalCoordinator.suggest_redistribution(state)

      # Some agents should be marked for migration
      assert length(redistribution_plan.agents_to_migrate) > 0
      assert redistribution_plan.reason == :capacity_exceeded
    end
  end

  describe "cluster state synchronization" do
    test "synchronizes cluster state across coordinator nodes", %{coordinator_state: state} do
      # Set up coordinator nodes
      coordinators = [
        :coordinator@primary,
        :coordinator@secondary,
        :coordinator@tertiary
      ]

      # MOCK: Use local coordinator for unit testing
      for coordinator_node <- coordinators do
        node_info = %{
          node: coordinator_node,
          capacity: 100,
          capabilities: [:coordinator_agent],
          role: :coordinator
        }

        :ok = LocalCoordinator.handle_node_join(node_info, state)
      end

      # Create cluster state update
      state_update = %{
        timestamp: System.system_time(:millisecond),
        updates: [
          {:agent_started, "agent-1", :worker@node1},
          {:agent_stopped, "agent-2", :worker@node2},
          {:node_capacity_changed, :worker@node1, 85}
        ]
      }

      assert :ok = LocalCoordinator.synchronize_cluster_state(state_update, state)

      # Verify state is synchronized
      assert {:ok, sync_status} = LocalCoordinator.get_sync_status(state)
      assert sync_status.last_sync_timestamp >= state_update.timestamp
      assert Enum.sort(sync_status.coordinator_nodes) == Enum.sort(coordinators)
      assert sync_status.sync_conflicts == []
    end

    test "handles split-brain scenarios", %{coordinator_state: state} do
      # Set up initial cluster with coordinators
      coordinators = [
        :coordinator@primary,
        :coordinator@secondary
      ]

      # MOCK: Use local coordinator for unit testing
      for coordinator_node <- coordinators do
        node_info = %{
          node: coordinator_node,
          capacity: 100,
          capabilities: [:coordinator_agent],
          role: :coordinator
        }

        :ok = LocalCoordinator.handle_node_join(node_info, state)
      end

      # Simulate split-brain condition
      split_brain_event = %{
        partitioned_nodes: [:coordinator@primary],
        isolated_nodes: [:coordinator@secondary],
        partition_timestamp: System.system_time(:millisecond)
      }

      assert :ok = LocalCoordinator.handle_split_brain(split_brain_event, state)

      # Verify split-brain handling
      assert {:ok, partition_status} = LocalCoordinator.get_partition_status(state)
      assert partition_status.active_partition != nil
      assert partition_status.quorum_achieved == true
      assert partition_status.isolated_nodes == [:coordinator@secondary]
    end

    test "resolves conflicts during state merge", %{coordinator_state: state} do
      # Create conflicting state updates
      conflict_scenario = %{
        node_a_updates: [
          {:agent_started, "agent-1", :worker@node1, timestamp: 1000},
          {:agent_capacity_updated, "agent-1", 50, timestamp: 1001}
        ],
        node_b_updates: [
          # Later timestamp - should win
          {:agent_started, "agent-1", :worker@node2, timestamp: 1001},
          {:agent_capacity_updated, "agent-1", 75, timestamp: 1002}
        ]
      }

      # MOCK: Use local coordinator for unit testing
      assert {:ok, resolution} =
               LocalCoordinator.resolve_state_conflicts(conflict_scenario, state)

      # Verify conflict resolution
      assert resolution.conflicts_detected > 0
      assert resolution.resolution_strategy == :latest_timestamp
      assert length(resolution.resolved_updates) > 0

      # Should resolve to latest timestamp updates
      agent_location =
        Enum.find(resolution.resolved_updates, fn update ->
          match?({:agent_started, "agent-1", _, _}, update)
        end)

      # Later timestamp wins
      assert elem(agent_location, 2) == :worker@node2
    end
  end

  describe "load balancing and optimization" do
    test "monitors cluster load and suggests optimizations", %{coordinator_state: state} do
      # Set up cluster with varying loads
      nodes = [
        %{node: :worker@overloaded, capacity: 20, current_load: 95, agent_count: 10},
        %{node: :worker@normal, capacity: 50, current_load: 50, agent_count: 5},
        %{node: :worker@underused, capacity: 90, current_load: 10, agent_count: 1}
      ]

      # MOCK: Use local coordinator for unit testing
      for node_info <- nodes do
        node_data = Map.put(node_info, :capabilities, [:worker_agent])
        :ok = LocalCoordinator.handle_node_join(node_data, state)
        :ok = LocalCoordinator.update_node_load(node_info.node, node_info.current_load, state)
      end

      assert {:ok, optimization_plan} = LocalCoordinator.analyze_cluster_load(state)

      # Should identify overloaded and underutilized nodes
      assert length(optimization_plan.overloaded_nodes) >= 1
      assert length(optimization_plan.underutilized_nodes) >= 1

      overloaded = List.first(optimization_plan.overloaded_nodes)
      assert overloaded.node == :worker@overloaded
      assert overloaded.recommended_action == :migrate_agents

      underutilized = List.first(optimization_plan.underutilized_nodes)
      assert underutilized.node == :worker@underused
      assert underutilized.recommended_action == :accept_migrations
    end

    test "implements health monitoring and alerts", %{coordinator_state: state} do
      # Set up cluster
      node_info = %{
        node: :worker@monitored,
        capacity: 100,
        capabilities: [:worker_agent],
        resources: %{memory: 8_000_000, cpu_count: 4}
      }

      # MOCK: Use local coordinator for unit testing
      :ok = LocalCoordinator.handle_node_join(node_info, state)

      # Simulate health deterioration
      health_updates = [
        %{node: :worker@monitored, metric: :memory_usage, value: 70, timestamp: 1000},
        %{node: :worker@monitored, metric: :memory_usage, value: 85, timestamp: 2000},
        # Critical
        %{node: :worker@monitored, metric: :memory_usage, value: 95, timestamp: 3000},
        # High
        %{node: :worker@monitored, metric: :cpu_usage, value: 90, timestamp: 3100}
      ]

      for update <- health_updates do
        :ok = LocalCoordinator.update_node_health(update, state)
      end

      assert {:ok, health_status} = LocalCoordinator.get_cluster_health(state)

      # Should detect health issues
      monitored_node = Enum.find(health_status.nodes, &(&1.node == :worker@monitored))
      assert monitored_node.health_status == :critical
      assert monitored_node.alerts != []

      memory_alert = Enum.find(monitored_node.alerts, &(&1.metric == :memory_usage))
      assert memory_alert.severity == :critical
      assert memory_alert.threshold_exceeded == true
    end
  end

  describe "coordination event handling" do
    test "processes coordination events in order", %{coordinator_state: state} do
      # Create sequence of coordination events
      events = [
        {:node_join, :worker@node1, %{capacity: 100}, timestamp: 1000},
        {:agent_start_request, "agent-1", %{type: :worker}, timestamp: 1001},
        {:agent_assigned, "agent-1", :worker@node1, timestamp: 1002},
        {:node_capacity_update, :worker@node1, 80, timestamp: 1003},
        {:redistribution_suggested, [:worker@node1], timestamp: 1004}
      ]

      # MOCK: Use local coordinator for unit testing
      for event <- events do
        assert :ok = LocalCoordinator.process_coordination_event(event, state)
      end

      # Verify events were processed in order
      assert {:ok, event_log} = LocalCoordinator.get_coordination_log(state)
      assert length(event_log.processed_events) == 5

      # Events should be ordered by timestamp
      timestamps = Enum.map(event_log.processed_events, & &1.timestamp)
      assert timestamps == Enum.sort(timestamps)
    end

    test "handles coordination event failures gracefully", %{coordinator_state: state} do
      # Create events with some that will fail
      events = [
        {:node_join, :worker@node1, %{capacity: 100}, timestamp: 1000},
        # Should fail
        {:invalid_event, "bad-data", timestamp: 1001},
        {:agent_start_request, "agent-1", %{type: :worker}, timestamp: 1002}
      ]

      # MOCK: Use local coordinator for unit testing
      results = Enum.map(events, &LocalCoordinator.process_coordination_event(&1, state))

      # Should handle failures gracefully
      assert Enum.at(results, 0) == :ok
      assert match?({:error, _}, Enum.at(results, 1))
      assert Enum.at(results, 2) == :ok

      # Verify system remains functional after failure
      assert {:ok, cluster_info} = LocalCoordinator.get_cluster_info(state)
      # Node join succeeded
      assert length(cluster_info.nodes) >= 1
    end
  end
end
