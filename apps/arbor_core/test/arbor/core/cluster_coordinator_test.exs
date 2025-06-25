defmodule Arbor.Core.ClusterCoordinatorTest do
  @moduledoc """
  Unit tests for cluster coordination logic using Mox-based mocking.

  These tests use Mox to mock the LocalCoordinator implementation, providing
  contract-based testing without requiring actual coordination infrastructure.
  This replaces the hand-written LocalCoordinator mock with standardized
  Mox-based testing patterns.

  Cluster coordination involves:
  - Node join/leave event handling
  - Agent redistribution across cluster
  - Cluster state synchronization
  - Load balancing and health monitoring
  """

  use ExUnit.Case, async: true

  import Mox
  import Arbor.Test.Support.MoxSetup

  alias Arbor.Core.ClusterCoordinator

  @moduletag :fast

  setup :verify_on_exit!
  setup :setup_mox

  setup do
    # Configure ClusterCoordinator to use our mock
    Application.put_env(:arbor_core, :coordinator_impl, Arbor.Test.Mocks.LocalCoordinatorMock)

    on_exit(fn ->
      Application.put_env(:arbor_core, :coordinator_impl, :auto)
    end)

    # Set up a basic mock state that will be used throughout tests
    mock_state = %{
      nodes: %{},
      agents: %{},
      event_log: [],
      health_metrics: %{},
      sync_status: %{
        last_sync_timestamp: 0,
        coordinator_nodes: [],
        sync_conflicts: [],
        partition_status: %{}
      },
      redistribution_plans: []
    }

    {:ok, mock_state: mock_state}
  end

  describe "node lifecycle management" do
    test "handles node join events" do
      node_info = %{
        node: :worker@node1,
        capacity: 100,
        capabilities: [:worker_agent, :llm_agent],
        resources: %{memory: 8_000_000, cpu_count: 4}
      }

      # Mock the coordinator response
      expect_coordinator_handle_node_join(node_info, :ok)

      # Test the public API
      assert :ok = ClusterCoordinator.handle_node_join(node_info)
    end

    test "handles node leave events" do
      node = :worker@node2
      reason = :shutdown

      # Mock the coordinator response
      expect_coordinator_handle_node_leave(node, reason, :ok)

      # Test the public API
      assert :ok = ClusterCoordinator.handle_node_leave(node, reason)
    end

    test "handles node failure events" do
      node = :worker@node3
      reason = :network_timeout

      # Mock the coordinator response
      expect_coordinator_handle_node_failure(node, reason, :ok)

      # Test the public API
      assert :ok = ClusterCoordinator.handle_node_failure(node, reason)
    end

    test "gets cluster information" do
      cluster_info = %{
        nodes: [
          %{
            node: :worker@node1,
            status: :active,
            capacity: 100,
            capabilities: [:worker_agent, :llm_agent]
          }
        ],
        total_capacity: 100,
        active_nodes: 1,
        total_agents: 0
      }

      # Mock the coordinator response
      expect_coordinator_get_cluster_info({:ok, cluster_info})

      # Test the public API
      assert {:ok, ^cluster_info} = ClusterCoordinator.get_cluster_info()
    end
  end

  describe "agent redistribution" do
    test "registers agent on node" do
      agent_info = %{
        id: "agent-1",
        node: :worker@node1,
        type: :coordinator,
        priority: :high,
        resources: %{memory: 1000, cpu: 50}
      }

      # Mock the coordinator response
      expect_coordinator_register_agent(agent_info, :ok)

      # Test the public API
      assert :ok = ClusterCoordinator.register_agent_on_node(agent_info)
    end

    test "calculates optimal agent distribution" do
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
        }
      ]

      distribution_plan = %{
        assignments: [
          %{
            agent_id: "coord-1",
            target_node: :coordinator@node1,
            assignment_reason: :load_balancing
          },
          %{agent_id: "worker-1", target_node: :worker@node2, assignment_reason: :load_balancing}
        ],
        strategy: :least_loaded,
        created_at: System.system_time(:millisecond)
      }

      # Mock the coordinator response
      expect_coordinator_calculate_distribution(agents, {:ok, distribution_plan})

      # Test the public API
      assert {:ok, result} = ClusterCoordinator.calculate_distribution(agents)
      assert result.assignments |> length() == 2
      assert result.strategy == :least_loaded
    end

    test "suggests redistribution for load balancing" do
      redistribution_plan = %{
        agents_to_migrate: ["agent-1"],
        reason: :capacity_exceeded,
        created_at: System.system_time(:millisecond)
      }

      # Mock the coordinator response
      expect_coordinator_suggest_redistribution({:ok, redistribution_plan})

      # Test the public API
      assert {:ok, result} = ClusterCoordinator.suggest_redistribution()
      assert result.reason == :capacity_exceeded
      assert "agent-1" in result.agents_to_migrate
    end

    test "updates node capacity" do
      node = :worker@node1
      new_capacity = 30
      reason = :high_load

      capacity_update = %{
        node: node,
        new_capacity: new_capacity,
        reason: reason
      }

      # Mock the coordinator response
      expect_coordinator_update_capacity(capacity_update, :ok)

      # Test the public API
      assert :ok = ClusterCoordinator.update_node_capacity(node, new_capacity, reason)
    end
  end

  describe "cluster state synchronization" do
    test "synchronizes cluster state" do
      state_update = %{
        timestamp: System.system_time(:millisecond),
        updates: [
          {:agent_started, "agent-1", :worker@node1},
          {:agent_stopped, "agent-2", :worker@node2},
          {:node_capacity_changed, :worker@node1, 85}
        ]
      }

      # Mock the coordinator response
      Arbor.Test.Mocks.LocalCoordinatorMock
      |> expect(:synchronize_cluster_state, fn ^state_update, _state -> :ok end)

      # Test the public API
      assert :ok = ClusterCoordinator.synchronize_cluster_state(state_update)
    end

    test "gets synchronization status" do
      sync_status = %{
        last_sync_timestamp: System.system_time(:millisecond),
        coordinator_nodes: [:coordinator@primary, :coordinator@secondary],
        sync_conflicts: []
      }

      # Mock the coordinator response
      expect_coordinator_get_sync_status({:ok, sync_status})

      # Test the public API
      assert {:ok, result} = ClusterCoordinator.get_sync_status()
      assert length(result.coordinator_nodes) == 2
      assert result.sync_conflicts == []
    end

    test "handles split-brain scenarios" do
      split_brain_event = %{
        partitioned_nodes: [:coordinator@primary],
        isolated_nodes: [:coordinator@secondary],
        partition_timestamp: System.system_time(:millisecond)
      }

      # Mock the coordinator response
      Arbor.Test.Mocks.LocalCoordinatorMock
      |> expect(:handle_split_brain, fn ^split_brain_event, _state -> :ok end)

      # Test the public API
      assert :ok = ClusterCoordinator.handle_split_brain(split_brain_event)
    end
  end

  describe "health monitoring and optimization" do
    test "updates node health metrics" do
      node = :worker@monitored
      metric = :memory_usage
      value = 95

      health_update = %{
        node: node,
        metric: metric,
        value: value,
        timestamp: System.system_time(:millisecond)
      }

      # Mock the coordinator response
      Arbor.Test.Mocks.LocalCoordinatorMock
      |> expect(:update_node_health, fn update, _state ->
        assert update.node == node
        assert update.metric == metric
        assert update.value == value
        :ok
      end)

      # Test the public API
      assert :ok = ClusterCoordinator.update_node_health(node, metric, value)
    end

    test "gets cluster health status" do
      health_status = %{
        nodes: [
          %{
            node: :worker@monitored,
            health_status: :critical,
            alerts: [
              %{metric: :memory_usage, severity: :critical, threshold_exceeded: true}
            ]
          }
        ],
        overall_status: :critical,
        critical_alerts: 1
      }

      # Mock the coordinator response
      expect_coordinator_get_cluster_health({:ok, health_status})

      # Test the public API
      assert {:ok, result} = ClusterCoordinator.get_cluster_health()
      assert result.overall_status == :critical
      assert result.critical_alerts == 1
    end

    test "analyzes cluster load" do
      optimization_plan = %{
        overloaded_nodes: [
          %{node: :worker@overloaded, current_load: 95, recommended_action: :migrate_agents}
        ],
        underutilized_nodes: [
          %{node: :worker@underused, current_load: 10, recommended_action: :accept_migrations}
        ]
      }

      # Mock the coordinator response
      Arbor.Test.Mocks.LocalCoordinatorMock
      |> expect(:analyze_cluster_load, fn _state -> {:ok, optimization_plan} end)

      # Test the public API
      assert {:ok, result} = ClusterCoordinator.analyze_cluster_load()
      assert length(result.overloaded_nodes) == 1
      assert length(result.underutilized_nodes) == 1
    end

    test "updates node load" do
      node = :worker@node1
      load = 75

      # Mock the coordinator response
      Arbor.Test.Mocks.LocalCoordinatorMock
      |> expect(:update_node_load, fn ^node, ^load, _state -> :ok end)

      # Test the public API
      assert :ok = ClusterCoordinator.update_node_load(node, load)
    end
  end

  describe "coordination event handling" do
    test "processes coordination events" do
      event = {:node_join, :worker@node1, %{capacity: 100}, timestamp: 1000}

      # Mock the coordinator response
      expect_coordinator_process_event(event, :ok)

      # Test the public API
      assert :ok = ClusterCoordinator.process_coordination_event(event)
    end

    test "handles coordination event failures gracefully" do
      invalid_event = {:invalid_event, "bad-data", timestamp: 1001}

      # Mock the coordinator response to return an error
      expect_coordinator_process_event(invalid_event, {:error, :invalid_event_type})

      # Test the public API
      assert {:error, :invalid_event_type} =
               ClusterCoordinator.process_coordination_event(invalid_event)
    end

    test "gets coordination event log" do
      event_log = %{
        processed_events: [
          %{type: :node_join, timestamp: 1000, processed: true},
          %{type: :agent_start_request, timestamp: 1001, processed: true}
        ],
        total_events: 2,
        failed_events: 0
      }

      # Mock the coordinator response
      Arbor.Test.Mocks.LocalCoordinatorMock
      |> expect(:get_coordination_log, fn _state -> {:ok, event_log} end)

      # Test the public API
      assert {:ok, result} = ClusterCoordinator.get_coordination_log()
      assert result.total_events == 2
      assert result.failed_events == 0
    end
  end

  describe "convenience functions" do
    test "handles complete node failure recovery" do
      failed_node = :worker@node3
      reason = :network_timeout

      redistribution_plan = %{
        trigger_node: failed_node,
        agents_to_migrate: ["agent-1", "agent-2"],
        target_nodes: [:worker@node1, :worker@node2],
        reason: :node_failure,
        created_at: System.system_time(:millisecond)
      }

      # Mock both the failure handling and redistribution plan retrieval
      expect_coordinator_handle_node_failure(failed_node, reason, :ok)

      Arbor.Test.Mocks.LocalCoordinatorMock
      |> expect(:get_redistribution_plan, fn ^failed_node, _state ->
        {:ok, redistribution_plan}
      end)

      # Test the public API
      assert {:ok, recovery_plan} =
               ClusterCoordinator.handle_node_failure_recovery(failed_node, reason)

      assert recovery_plan.failed_node == failed_node
      assert recovery_plan.failure_reason == reason
      assert recovery_plan.redistribution_plan.agents_to_migrate == ["agent-1", "agent-2"]
    end

    test "performs comprehensive health check" do
      cluster_info = %{nodes: [], total_capacity: 0, active_nodes: 0, total_agents: 0}
      health_status = %{nodes: [], overall_status: :healthy, critical_alerts: 0}
      sync_status = %{last_sync_timestamp: 0, coordinator_nodes: [], sync_conflicts: []}

      # Mock all the required responses
      expect_coordinator_get_cluster_info({:ok, cluster_info})
      expect_coordinator_get_cluster_health({:ok, health_status})
      expect_coordinator_get_sync_status({:ok, sync_status})

      # Test the public API
      assert {:ok, health_report} = ClusterCoordinator.perform_health_check()
      assert health_report.cluster_info == cluster_info
      assert health_report.health_status == health_status
      assert health_report.sync_status == sync_status
      assert health_report.check_timestamp != nil
    end
  end
end
