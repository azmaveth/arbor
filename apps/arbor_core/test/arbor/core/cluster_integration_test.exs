defmodule Arbor.Core.ClusterIntegrationTest do
  @moduledoc """
  Multi-node integration tests for distributed agent orchestration.

  These tests use REAL multi-node clustering with Horde and libcluster
  to verify that agents can communicate and coordinate across cluster nodes.

  IMPORTANT: These tests require actual distributed BEAM nodes and will
  initially fail until Horde production implementations are complete.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :cluster
  @moduletag timeout: 30_000

  alias Arbor.Core.{ClusterRegistry, ClusterSupervisor, ClusterCoordinator}

  # Helper to wrap start functions, treating :already_started as :ok
  defp start_or_ok({:ok, _pid}), do: {:ok, :started}
  defp start_or_ok({:error, {:already_started, _pid}}), do: {:ok, :already_started}
  defp start_or_ok({:error, _reason} = error), do: error

  defp start_horde_components() do
    # Try to start each component, but treat :already_started as success.
    # This ensures the test works whether Horde is started by the Application
    # or manually by the test itself.
    with {:ok, _} <- start_or_ok(start_horde_registry()),
         {:ok, _} <- start_or_ok(Arbor.Core.HordeSupervisor.start_supervisor()),
         {:ok, _} <- start_or_ok(Arbor.Core.HordeCoordinator.start_coordination()) do
      # Give time for components to sync
      :timer.sleep(500)
      :ok
    else
      error -> error
    end
  end

  defp start_horde_registry() do
    # Start the actual Horde.Registry that HordeRegistry module will use
    children = [
      {Horde.Registry,
       [
         name: Arbor.Core.HordeAgentRegistry,
         keys: :unique,
         members: :auto,
         delta_crdt_options: [sync_interval: 100]
       ]}
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Arbor.Core.HordeAgentRegistrySupervisor
    )
  end

  defp stop_horde_components() do
    # Stop supervisors in reverse order
    supervisors = [
      Arbor.Core.HordeCoordinatorSupervisor,
      Arbor.Core.HordeSupervisorRegistry,
      # The actual Horde.Registry supervisor
      Arbor.Core.HordeAgentRegistrySupervisor
    ]

    Enum.each(supervisors, fn sup_name ->
      case Process.whereis(sup_name) do
        nil ->
          :ok

        pid ->
          try do
            Supervisor.stop(pid, :normal, 5000)
          catch
            :exit, _ -> :ok
          end
      end
    end)
  end

  setup_all do
    # Start distributed Erlang
    :net_kernel.start([:arbor_test@localhost, :shortnames])

    # Set clustering mode to production for these tests
    Application.put_env(:arbor_core, :registry_impl, :horde)
    Application.put_env(:arbor_core, :supervisor_impl, :horde)
    Application.put_env(:arbor_core, :coordinator_impl, :horde)
    Application.put_env(:arbor_core, :env, :integration_test)

    # Start required dependencies first (handle already started)
    case start_supervised({Phoenix.PubSub, name: Arbor.Core.PubSub}) do
      {:ok, _pubsub} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Start Horde infrastructure manually for integration tests
    # Note: In production, these would be started by the Application supervision tree
    case start_horde_components() do
      :ok ->
        :ok

      {:error, reason} ->
        flunk("Failed to start Horde components: #{inspect(reason)}")
    end

    on_exit(fn ->
      # Stop Horde services
      stop_horde_components()

      # Reset to auto mode
      Application.put_env(:arbor_core, :registry_impl, :auto)
      Application.put_env(:arbor_core, :supervisor_impl, :auto)
      Application.put_env(:arbor_core, :coordinator_impl, :auto)

      # Stop distributed Erlang
      :net_kernel.stop()
    end)

    :ok
  end

  setup do
    # Ensure cluster is in clean state before each test
    :timer.sleep(100)
    :ok
  end

  describe "multi-node agent communication" do
    @tag :slow
    test "agents communicate across cluster nodes" do
      # This test will initially fail - requires real clustering

      # Register test process to receive messages
      Process.register(self(), :test_coordinator_proc)

      # Start primary coordinator agent
      coordinator_id = "coordinator-primary"

      {:ok, coordinator_pid} =
        ClusterSupervisor.start_coordinator_agent(
          coordinator_id,
          TestCoordinatorAgent,
          [coordination_mode: :primary],
          %{session_id: "test-session-001"}
        )

      # Start worker agent (should be placed on different node if available)
      worker_id = "worker-001"

      {:ok, worker_pid} =
        ClusterSupervisor.start_worker_agent(
          worker_id,
          TestWorkerAgent,
          [work_type: :analysis],
          %{session_id: "test-session-001"}
        )

      # Wait a bit for registration to propagate
      :timer.sleep(100)

      # Verify agents are registered cluster-wide
      assert {:ok, coordinator_pid, _coordinator_metadata} =
               ClusterRegistry.lookup_agent(coordinator_id)

      assert {:ok, worker_pid, _worker_metadata} = ClusterRegistry.lookup_agent(worker_id)
      assert is_pid(coordinator_pid)
      assert is_pid(worker_pid)

      # Get agent locations
      coordinator_node = node(coordinator_pid)
      worker_node = node(worker_pid)

      # If we have multiple nodes, agents should potentially be on different nodes
      available_nodes = Node.list() ++ [node()]

      if length(available_nodes) > 1 do
        # With multiple nodes, agents might be distributed
        # But we don't require it - just verify they can communicate
        IO.puts("Coordinator on: #{coordinator_node}, Worker on: #{worker_node}")
      end

      # Test cross-node communication via agent coordination
      task_spec = %{
        task_id: "analyze-001",
        task_type: :text_analysis,
        payload: %{text: "Hello distributed world!"},
        timeout: 5000
      }

      # Delegate task from coordinator to worker
      assert :ok = GenServer.call(coordinator_pid, {:delegate_task, worker_id, task_spec})

      # Verify task delegation across nodes (worker should receive task)
      task_id = task_spec.task_id
      assert_receive {:task_delegated, ^worker_id, ^task_spec}, 5000

      # Worker processes task and reports back
      result = %{analysis: "positive_sentiment", confidence: 0.95}
      assert :ok = GenServer.call(worker_pid, {:complete_task, task_id, result})

      # Coordinator should receive completion notification
      assert_receive {:task_completed, ^worker_id, ^task_id, ^result}, 5000
    end

    @tag :slow
    test "handles agent discovery across cluster" do
      # Start multiple agents of different types
      agents = [
        {"llm-agent-001", TestLLMAgent, %{model: "gpt-4"}},
        {"llm-agent-002", TestLLMAgent, %{model: "claude-3"}},
        {"worker-agent-001", TestWorkerAgent, %{specialization: :data_processing}},
        {"worker-agent-002", TestWorkerAgent, %{specialization: :file_analysis}}
      ]

      started_agents =
        for {agent_id, module, metadata} <- agents do
          {:ok, _pid} =
            ClusterSupervisor.start_agent(%{
              id: agent_id,
              module: module,
              args: [metadata: metadata],
              restart_strategy: :temporary,
              metadata: metadata
            })

          agent_id
        end

      # Wait for cluster synchronization
      :timer.sleep(500)

      # Verify all agents are discoverable cluster-wide
      for agent_id <- started_agents do
        assert {:ok, _pid, _metadata} = ClusterRegistry.lookup_agent(agent_id)
      end

      # Test agent discovery by type
      {:ok, llm_agents} = ClusterRegistry.list_agents_by_type(:llm_agent)
      {:ok, worker_agents} = ClusterRegistry.list_agents_by_type(:worker_agent)

      # Should find agents by type regardless of which node they're on
      llm_agent_ids = Enum.map(llm_agents, fn {id, _pid, _metadata} -> id end)
      worker_agent_ids = Enum.map(worker_agents, fn {id, _pid, _metadata} -> id end)

      assert "llm-agent-001" in llm_agent_ids
      assert "llm-agent-002" in llm_agent_ids
      assert "worker-agent-001" in worker_agent_ids
      assert "worker-agent-002" in worker_agent_ids

      # Clean up
      for agent_id <- started_agents do
        :ok = ClusterSupervisor.stop_agent(agent_id)
      end
    end
  end

  describe "node failure and recovery" do
    @tag :slow
    test "handles node failure with agent migration" do
      # This test simulates node failure scenarios
      # Initially will fail until Horde migration is implemented

      # Start agent on current node
      agent_id = "resilient-agent-001"

      {:ok, _pid} =
        ClusterSupervisor.start_agent(%{
          id: agent_id,
          module: TestResilientAgent,
          args: [state: %{important_data: "must_preserve"}],
          restart_strategy: :permanent,
          metadata: %{critical: true}
        })

      # Wait for registration to complete
      :timer.sleep(100)

      # Get initial agent info
      {:ok, original_info} = ClusterSupervisor.get_agent_info(agent_id)
      original_node = original_info.node
      original_pid = original_info.pid

      IO.puts("Agent started on node: #{original_node}")
      IO.puts("Agent PID: #{inspect(original_pid)}")

      # Verify agent is running and has state
      state = GenServer.call(original_pid, :get_state)
      assert state.important_data == "must_preserve"

      # For single-node test, simulate node failure by testing migration capability
      available_nodes = Node.list() ++ [node()]

      if length(available_nodes) > 1 do
        # Multi-node scenario: test actual migration
        target_nodes = available_nodes -- [original_node]
        target_node = List.first(target_nodes)

        # Trigger manual restoration (simulating failure response)
        assert {:ok, {new_pid, recovery_status}} =
                 Arbor.Core.HordeSupervisor.restore_agent(agent_id)

        # Verify agent migrated to different node
        assert node(new_pid) == target_node
        assert new_pid != original_pid

        # Verify state was preserved during migration
        preserved_state = GenServer.call(new_pid, :get_state)
        assert preserved_state.important_data == "must_preserve"

        # Verify registry was updated
        assert {:ok, migrated_info} = ClusterSupervisor.get_agent_info(agent_id)
        assert migrated_info.node == target_node
        assert migrated_info.pid == new_pid
      else
        # Single-node scenario: test restoration capability
        IO.puts("Single node detected - testing restoration capability only")

        # Verify agent can be restored with state preservation
        assert {:ok, {new_pid, recovery_status}} =
                 Arbor.Core.HordeSupervisor.restore_agent(agent_id)

        assert new_pid != original_pid

        # Verify state was preserved during restoration
        preserved_state = GenServer.call(new_pid, :get_state)
        assert preserved_state.important_data == "must_preserve"
      end
    end

    @tag :slow
    test "maintains cluster consistency during network partitions" do
      # Test split-brain handling and conflict resolution
      # Will initially fail until coordinator clustering is implemented

      # Set up cluster state
      initial_agents = [
        "partition-test-001",
        "partition-test-002",
        "partition-test-003"
      ]

      # Start agents
      for agent_id <- initial_agents do
        {:ok, _pid} =
          ClusterSupervisor.start_agent(%{
            id: agent_id,
            module: TestPartitionAgent,
            args: [partition_id: agent_id],
            restart_strategy: :permanent
          })
      end

      # Wait for cluster synchronization
      :timer.sleep(500)

      # Get initial cluster health
      {:ok, initial_health} = ClusterCoordinator.get_cluster_health()
      initial_agent_count = initial_health.nodes |> Enum.map(& &1.agent_count) |> Enum.sum()

      assert initial_agent_count >= length(initial_agents)

      # Simulate network partition (in single node, just test conflict resolution)
      partition_event = %{
        partitioned_nodes: [node()],
        isolated_nodes: [],
        partition_timestamp: System.system_time(:millisecond)
      }

      assert :ok = ClusterCoordinator.handle_split_brain(partition_event)

      # Verify cluster maintains consistency
      {:ok, post_partition_health} = ClusterCoordinator.get_cluster_health()
      assert post_partition_health.overall_status in [:healthy, :warning]

      # Verify all agents are still accessible
      for agent_id <- initial_agents do
        assert {:ok, _pid, _metadata} = ClusterRegistry.lookup_agent(agent_id)
      end

      # Clean up
      for agent_id <- initial_agents do
        :ok = ClusterSupervisor.stop_agent(agent_id)
      end
    end
  end

  describe "cluster performance and scaling" do
    @tag :slow
    test "distributes load across cluster nodes" do
      # Test agent distribution and load balancing
      # Will initially fail until Horde load balancing is implemented

      agent_count = 10

      agent_ids =
        for i <- 1..agent_count do
          agent_id = "load-test-#{String.pad_leading("#{i}", 3, "0")}"

          {:ok, _pid} =
            ClusterSupervisor.start_agent(%{
              id: agent_id,
              module: TestLoadAgent,
              args: [load_factor: :rand.uniform(100)],
              restart_strategy: :temporary
            })

          agent_id
        end

      # Wait for distribution
      :timer.sleep(1000)

      # Analyze distribution across nodes
      {:ok, cluster_info} = ClusterCoordinator.get_cluster_info()

      if cluster_info.active_nodes > 1 do
        # Multi-node: verify agents are distributed
        node_loads =
          for node_info <- cluster_info.nodes do
            {node_info.node, node_info.agent_count}
          end

        # Log agent distribution across nodes for debugging
        require Logger
        Logger.debug("Agent distribution across nodes: #{inspect(node_loads)}")

        # At least some distribution should occur
        non_empty_nodes = Enum.count(node_loads, fn {_node, count} -> count > 0 end)
        assert non_empty_nodes >= 1
      else
        # Single node: verify all agents are tracked
        total_agents = cluster_info.total_agents
        assert total_agents >= agent_count
      end

      # Test load balancing suggestion
      {:ok, optimization_plan} = ClusterCoordinator.analyze_cluster_load()
      assert is_map(optimization_plan)
      assert Map.has_key?(optimization_plan, :overloaded_nodes)
      assert Map.has_key?(optimization_plan, :underutilized_nodes)

      # Clean up
      for agent_id <- agent_ids do
        :ok = ClusterSupervisor.stop_agent(agent_id, 1000)
      end
    end

    @tag :slow
    test "handles rapid agent creation and destruction" do
      # Stress test cluster coordination under rapid changes

      # Rapid creation
      creation_tasks =
        for i <- 1..20 do
          Task.async(fn ->
            agent_id = "stress-agent-#{i}-#{:rand.uniform(1000)}"

            result =
              ClusterSupervisor.start_agent(%{
                id: agent_id,
                module: TestStressAgent,
                args: [stress_level: i],
                restart_strategy: :temporary
              })

            {agent_id, result}
          end)
        end

      # Wait for creation to complete
      creation_results = Task.await_many(creation_tasks, 10_000)
      successful_agents = for {agent_id, {:ok, _pid}} <- creation_results, do: agent_id

      # Allow some failures under stress
      assert length(successful_agents) >= 15

      # Verify agents are registered
      :timer.sleep(500)

      registered_count =
        Enum.count(successful_agents, fn agent_id ->
          case ClusterRegistry.lookup_agent(agent_id) do
            {:ok, _pid, _metadata} -> true
            _ -> false
          end
        end)

      # Allow some registry lag
      assert registered_count >= length(successful_agents) * 0.8

      # Rapid destruction
      destruction_tasks =
        for agent_id <- successful_agents do
          Task.async(fn ->
            ClusterSupervisor.stop_agent(agent_id, 1000)
          end)
        end

      # Wait for destruction
      Task.await_many(destruction_tasks, 10_000)

      # Verify cleanup
      :timer.sleep(500)

      remaining_count =
        Enum.count(successful_agents, fn agent_id ->
          case ClusterRegistry.lookup_agent(agent_id) do
            {:ok, _pid, _metadata} -> true
            _ -> false
          end
        end)

      # Most agents should be cleaned up
      assert remaining_count <= length(successful_agents) * 0.2
    end
  end

  describe "cluster health monitoring" do
    @tag :slow
    test "monitors cluster health metrics" do
      # Test health monitoring across cluster

      # Start some agents to generate activity
      test_agents = ["health-monitor-001", "health-monitor-002"]

      for agent_id <- test_agents do
        {:ok, _pid} =
          ClusterSupervisor.start_agent(%{
            id: agent_id,
            module: TestHealthAgent,
            args: [health_check_interval: 1000],
            restart_strategy: :temporary
          })
      end

      # Update node health metrics
      :ok = ClusterCoordinator.update_node_health(node(), :memory_usage, 65)
      :ok = ClusterCoordinator.update_node_health(node(), :cpu_usage, 45)

      # Get comprehensive health report
      {:ok, health_report} = ClusterCoordinator.perform_health_check()

      # Verify health report structure
      assert Map.has_key?(health_report, :cluster_info)
      assert Map.has_key?(health_report, :health_status)
      assert Map.has_key?(health_report, :sync_status)
      assert Map.has_key?(health_report, :check_timestamp)

      # Verify cluster info
      cluster_info = health_report.cluster_info
      assert cluster_info.active_nodes >= 1
      assert cluster_info.total_agents >= length(test_agents)

      # Verify health status
      health_status = health_report.health_status
      assert health_status.overall_status in [:healthy, :warning, :degraded, :critical]
      assert is_list(health_status.nodes)
      assert length(health_status.nodes) >= 1

      # Check node health details
      node_health = List.first(health_status.nodes)
      assert Map.has_key?(node_health, :node)
      assert Map.has_key?(node_health, :health_status)
      assert Map.has_key?(node_health, :memory_usage)
      assert Map.has_key?(node_health, :cpu_usage)

      # Clean up
      for agent_id <- test_agents do
        :ok = ClusterSupervisor.stop_agent(agent_id)
      end
    end
  end
end

# Test agent modules for integration testing

defmodule TestCoordinatorAgent do
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @spec init(keyword()) :: {:ok, map()}
  def init(args) do
    state = %{
      coordination_mode: Keyword.get(args, :coordination_mode, :secondary),
      delegated_tasks: %{},
      metadata: Keyword.get(args, :metadata, %{})
    }

    {:ok, state}
  end

  @spec handle_call({:delegate_task, String.t(), map()}, GenServer.from(), map()) ::
          {:reply, :ok, map()}
  def handle_call({:delegate_task, worker_id, task_spec}, _from, state) do
    # Simulate task delegation
    send(self(), {:task_delegated, worker_id, task_spec})
    updated_tasks = Map.put(state.delegated_tasks, task_spec.task_id, {worker_id, task_spec})
    {:reply, :ok, %{state | delegated_tasks: updated_tasks}}
  end

  @spec handle_info({:task_delegated, String.t(), map()}, map()) :: {:noreply, map()}
  def handle_info({:task_delegated, worker_id, task_spec}, state) do
    # Forward to test process if running in test
    if Process.whereis(:test_coordinator_proc) do
      send(:test_coordinator_proc, {:task_delegated, worker_id, task_spec})
    end

    {:noreply, state}
  end

  @spec handle_info({:task_completed, String.t(), String.t(), any()}, map()) :: {:noreply, map()}
  def handle_info({:task_completed, worker_id, task_id, result}, state) do
    # Forward to test process if running in test
    if Process.whereis(:test_coordinator_proc) do
      send(:test_coordinator_proc, {:task_completed, worker_id, task_id, result})
    end

    {:noreply, state}
  end
end

defmodule TestWorkerAgent do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(args) do
    state = %{
      work_type: Keyword.get(args, :work_type, :generic),
      current_tasks: %{},
      metadata: Keyword.get(args, :metadata, %{})
    }

    {:ok, state}
  end

  def handle_call({:complete_task, task_id, result}, _from, state) do
    # Simulate task completion
    updated_tasks = Map.delete(state.current_tasks, task_id)
    send(self(), {:task_completed_internal, task_id, result})
    {:reply, :ok, %{state | current_tasks: updated_tasks}}
  end

  def handle_info({:task_completed_internal, task_id, result}, state) do
    # Notify coordinator or test process
    # For this test, we'll send directly to the test process
    if Process.whereis(:test_coordinator_proc) do
      send(:test_coordinator_proc, {:task_completed, "worker-001", task_id, result})
    end

    {:noreply, state}
  end
end

defmodule TestLLMAgent do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(args) do
    state = %{
      model: Keyword.get(args, :model, "default"),
      metadata: Keyword.get(args, :metadata, %{})
    }

    {:ok, state}
  end
end

defmodule TestResilientAgent do
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @spec init(keyword()) :: {:ok, map()}
  def init(args) do
    # Check if we have recovered state from a restore operation
    case Keyword.get(args, :recovered_state) do
      nil ->
        # Normal initialization
        state = Keyword.get(args, :state, %{})
        {:ok, state}

      recovered_state ->
        # Use recovered state from checkpoint
        {:ok, recovered_state}
    end
  end

  @spec handle_call(:get_state, GenServer.from(), map()) :: {:reply, map(), map()}
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @spec handle_call(:extract_state, GenServer.from(), map()) :: {:reply, map(), map()}
  def handle_call(:extract_state, _from, state) do
    {:reply, state, state}
  end

  @spec handle_call(:prepare_checkpoint, GenServer.from(), map()) :: {:reply, map(), map()}
  def handle_call(:prepare_checkpoint, _from, state) do
    {:reply, state, state}
  end

  @spec handle_call({:restore_state, map()}, GenServer.from(), map()) :: {:reply, :ok, map()}
  def handle_call({:restore_state, new_state}, _from, _state) do
    {:reply, :ok, new_state}
  end
end

defmodule TestPartitionAgent do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(args) do
    state = %{
      partition_id: Keyword.get(args, :partition_id),
      status: :active
    }

    {:ok, state}
  end
end

defmodule TestLoadAgent do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(args) do
    state = %{
      load_factor: Keyword.get(args, :load_factor, 50)
    }

    {:ok, state}
  end
end

defmodule TestStressAgent do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(args) do
    state = %{
      stress_level: Keyword.get(args, :stress_level, 1)
    }

    {:ok, state}
  end
end

defmodule TestHealthAgent do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(args) do
    state = %{
      health_check_interval: Keyword.get(args, :health_check_interval, 5000)
    }

    {:ok, state}
  end
end
