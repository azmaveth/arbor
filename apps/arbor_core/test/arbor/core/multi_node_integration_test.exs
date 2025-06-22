defmodule Arbor.Core.MultiNodeIntegrationTest do
  @moduledoc """
  Multi-node integration tests for cluster fault tolerance.

  These tests validate that the declarative supervision architecture
  can survive node failures and properly redistribute agents across
  the remaining cluster nodes.

  ## Test Requirements

  - Agents specifications persist across node failures
  - AgentReconciler restarts missing agents on surviving nodes
  - Cluster maintains consistency during network partitions
  - Agent state recovery works across node boundaries
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :multi_node
  @moduletag timeout: 60_000

  alias Arbor.Core.{HordeSupervisor, AgentReconciler, MultiNodeTestHelper}

  setup_all do
    # Only run if multi-node testing is explicitly enabled
    unless System.get_env("MULTI_NODE_TESTS") == "true" do
      {:skip, "Multi-node tests require MULTI_NODE_TESTS=true environment variable"}
    else
      :ok
    end
  end

  setup do
    # Start a 3-node cluster for testing
    nodes =
      MultiNodeTestHelper.start_cluster([
        %{name: :node1@localhost, apps: [:arbor_core]},
        %{name: :node2@localhost, apps: [:arbor_core]},
        %{name: :node3@localhost, apps: [:arbor_core]}
      ])

    # Verify cluster health
    :ok = MultiNodeTestHelper.verify_cluster_health(nodes)

    # Wait for Horde components to synchronize
    :timer.sleep(2000)

    on_exit(fn ->
      MultiNodeTestHelper.stop_cluster(nodes)
    end)

    {:ok, nodes: nodes}
  end

  describe "agent specification persistence" do
    test "agent specs persist and reconcile across node failures", %{nodes: [node1, node2, node3]} do
      agent_id = "test-multi-node-persistence-#{System.unique_integer([:positive])}"

      # Start agent on the cluster
      agent_spec = %{
        id: agent_id,
        module: MultiNodeTestAgent,
        args: [agent_id: agent_id, initial_data: "important_state"],
        restart_strategy: :permanent
      }

      assert {:ok, original_pid} = HordeSupervisor.start_agent(agent_spec)
      original_node = node(original_pid)

      # Verify agent spec is in registry
      assert {:ok, stored_spec} = HordeSupervisor.lookup_agent_spec(agent_id)
      assert stored_spec.module == MultiNodeTestAgent
      assert stored_spec.restart_strategy == :permanent

      # Verify agent is registered in runtime registry
      assert {:ok, agent_info} = HordeSupervisor.get_agent_info(agent_id)
      assert agent_info.pid == original_pid
      assert agent_info.node == original_node

      # Kill the node running the agent
      MultiNodeTestHelper.kill_node(original_node)
      remaining_nodes = [node1, node2, node3] -- [original_node]

      # Wait for AgentReconciler to detect and restart the agent
      # (This may take up to the reconciliation interval + processing time)
      MultiNodeTestHelper.wait_for_agent_distribution(remaining_nodes, [agent_id], 15_000)

      # Verify agent restarted on a surviving node
      assert {:ok, new_agent_info} = HordeSupervisor.get_agent_info(agent_id)
      assert new_agent_info.node != original_node
      assert new_agent_info.node in remaining_nodes
      assert Process.alive?(new_agent_info.pid)

      # Verify spec still exists in registry
      assert {:ok, recovered_spec} = HordeSupervisor.lookup_agent_spec(agent_id)
      assert recovered_spec.module == stored_spec.module
      assert recovered_spec.restart_strategy == stored_spec.restart_strategy

      # Clean up
      HordeSupervisor.stop_agent(agent_id)
    end

    test "multiple agents redistribute after node failure", %{nodes: [node1, node2, node3]} do
      # Start multiple agents across the cluster
      agent_count = 6
      agent_prefix = "test-multi-redistribute"
      test_id = System.unique_integer([:positive])

      agent_ids =
        for i <- 1..agent_count do
          agent_id = "#{agent_prefix}-#{test_id}-#{i}"

          agent_spec = %{
            id: agent_id,
            module: MultiNodeTestAgent,
            args: [agent_id: agent_id, index: i],
            restart_strategy: :permanent
          }

          assert {:ok, _pid} = HordeSupervisor.start_agent(agent_spec)
          agent_id
        end

      # Wait for agents to distribute across the cluster
      MultiNodeTestHelper.wait_for_agent_distribution([node1, node2, node3], agent_ids)

      # Get distribution before node failure
      initial_distribution = Enum.group_by(agent_ids, &MultiNodeTestHelper.get_agent_node/1)

      # Find a node that has agents and kill it
      {killed_node, agents_on_killed_node} =
        Enum.find(initial_distribution, fn {_node, agents} -> length(agents) > 0 end)

      MultiNodeTestHelper.kill_node(killed_node)
      remaining_nodes = [node1, node2, node3] -- [killed_node]

      # Wait for agents to be redistributed
      MultiNodeTestHelper.wait_for_agent_distribution(remaining_nodes, agent_ids, 20_000)

      # Verify all agents are now running on surviving nodes
      final_distribution = Enum.group_by(agent_ids, &MultiNodeTestHelper.get_agent_node/1)

      # No agents should be on the killed node
      assert Map.get(final_distribution, killed_node, []) == []

      # All agents should be distributed among remaining nodes
      running_agents = final_distribution |> Map.values() |> List.flatten()
      assert length(running_agents) == agent_count

      # Verify all agents are on remaining nodes
      Enum.each(running_agents, fn agent_id ->
        agent_node = MultiNodeTestHelper.get_agent_node(agent_id)
        assert agent_node in remaining_nodes
      end)

      # Clean up
      Enum.each(agent_ids, &HordeSupervisor.stop_agent/1)
    end
  end

  describe "network partition resilience" do
    test "cluster handles network partitions gracefully", %{nodes: [node1, node2, node3]} do
      agent_id = "test-partition-resilience-#{System.unique_integer([:positive])}"

      # Start agent on the cluster
      agent_spec = %{
        id: agent_id,
        module: MultiNodeTestAgent,
        args: [agent_id: agent_id],
        restart_strategy: :permanent
      }

      assert {:ok, _pid} = HordeSupervisor.start_agent(agent_spec)

      # Create a partition by isolating node1
      MultiNodeTestHelper.partition_node(node1)

      # Wait for partition to take effect
      :timer.sleep(3000)

      # Agent should still be accessible from the majority partition (node2, node3)
      # Note: This test assumes agent is not on the partitioned node
      # In a real scenario, we'd need more sophisticated partition handling

      # Heal the partition
      MultiNodeTestHelper.heal_partition(node1)

      # Wait for cluster to reconverge
      :timer.sleep(3000)

      # Verify cluster health after partition healing
      :ok = MultiNodeTestHelper.verify_cluster_health([node1, node2, node3])

      # Verify agent is still running and accessible
      assert {:ok, agent_info} = HordeSupervisor.get_agent_info(agent_id)
      assert Process.alive?(agent_info.pid)

      # Clean up
      HordeSupervisor.stop_agent(agent_id)
    end
  end

  describe "reconciler behavior under stress" do
    test "reconciler handles rapid node failures", %{nodes: [node1, node2, node3]} do
      # This test validates that the reconciler can handle
      # multiple rapid failures without getting overwhelmed

      agent_count = 9
      agent_prefix = "test-rapid-failure"
      test_id = System.unique_integer([:positive])

      # Start agents across the cluster
      agent_ids =
        for i <- 1..agent_count do
          agent_id = "#{agent_prefix}-#{test_id}-#{i}"

          agent_spec = %{
            id: agent_id,
            module: MultiNodeTestAgent,
            args: [agent_id: agent_id, index: i],
            restart_strategy: :permanent
          }

          assert {:ok, _pid} = HordeSupervisor.start_agent(agent_spec)
          agent_id
        end

      # Wait for distribution
      MultiNodeTestHelper.wait_for_agent_distribution([node1, node2, node3], agent_ids)

      # Kill two nodes in rapid succession
      MultiNodeTestHelper.kill_node(node1)
      :timer.sleep(1000)
      MultiNodeTestHelper.kill_node(node2)

      # All agents should eventually be running on node3
      MultiNodeTestHelper.wait_for_agent_distribution([node3], agent_ids, 30_000)

      # Verify all agents are now on node3
      final_distribution = Enum.group_by(agent_ids, &MultiNodeTestHelper.get_agent_node/1)
      agents_on_node3 = Map.get(final_distribution, node3, [])
      assert length(agents_on_node3) == agent_count

      # Clean up
      Enum.each(agent_ids, &HordeSupervisor.stop_agent/1)
    end
  end
end

# Test agent for multi-node testing
defmodule MultiNodeTestAgent do
  @moduledoc """
  Simple test agent for multi-node cluster testing.
  """

  use GenServer

  alias Arbor.Core.HordeRegistry

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @spec init(keyword()) :: {:ok, map()}
  def init(args) do
    agent_id = Keyword.get(args, :agent_id)

    state = %{
      agent_id: agent_id,
      initial_data: Keyword.get(args, :initial_data),
      index: Keyword.get(args, :index, 0),
      started_at: System.system_time(:millisecond),
      node: node()
    }

    # Note: Agent registration is now handled by HordeSupervisor (centralized)

    {:ok, state}
  end

  @spec handle_call(:get_state, GenServer.from(), map()) :: {:reply, map(), map()}
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @spec terminate(any(), map()) :: :ok
  def terminate(_reason, _state) do
    # Note: Agent cleanup is now handled by HordeSupervisor (centralized)
    :ok
  end
end
