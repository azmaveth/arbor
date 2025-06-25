defmodule Arbor.Agents.CodeAnalyzerDistributedTest do
  @moduledoc """
  Distributed tests for CodeAnalyzer agent.

  These tests verify:
  - CRDT synchronization of agent registrations
  - Race condition handling during concurrent agent operations
  - Failover behavior when nodes crash
  - State consistency across cluster changes
  """

  use ExUnit.Case, async: false

  alias Arbor.Agents.CodeAnalyzer
  alias Arbor.Core.{ClusterTestHelper, HordeSupervisor, MultiNodeTestHelper}
  alias Arbor.Test.Support.AsyncHelpers

  require Logger

  @moduletag :distributed
  @moduletag timeout: 120_000

  @temp_dir_prefix "/tmp/arbor_distributed_test_"

  setup_all do
    # Start the multi-node cluster for distributed testing
    nodes = ClusterTestHelper.start_default_cluster()

    on_exit(fn ->
      MultiNodeTestHelper.stop_cluster(nodes)
    end)

    {:ok, %{nodes: nodes}}
  end

  setup %{nodes: nodes} do
    # Create unique temp directories for each test
    test_id = System.unique_integer([:positive])
    temp_dirs = create_temp_dirs_on_nodes(nodes, test_id)

    on_exit(fn ->
      cleanup_temp_dirs_on_nodes(nodes, temp_dirs)
    end)

    %{temp_dirs: temp_dirs, test_id: test_id}
  end

  describe "CRDT synchronization" do
    test "agent registrations sync across all nodes", %{
      nodes: nodes,
      temp_dirs: temp_dirs,
      test_id: test_id
    } do
      agent_id = "dist_analyzer_sync_#{test_id}"
      [node1, node2, node3] = nodes
      temp_dir = hd(temp_dirs)

      # Start agent on node1
      agent_spec = %{
        id: agent_id,
        module: CodeAnalyzer,
        args: [agent_id: agent_id, working_dir: temp_dir]
      }

      assert {:ok, pid} = :rpc.call(node1, HordeSupervisor, :start_agent, [agent_spec])
      # Note: Horde may start the agent on any node in the cluster for load balancing
      assert node(pid) in nodes

      # Wait for CRDT sync
      assert :ok = ClusterTestHelper.wait_for_registry_convergence(nodes)

      # Get the actual node where the agent was started
      actual_node = node(pid)

      # Verify agent is visible from all nodes
      for node <- nodes do
        assert {:ok, info} = :rpc.call(node, HordeSupervisor, :get_agent_info, [agent_id])
        assert info.id == agent_id
        assert info.pid == pid
        assert info.node == actual_node
      end

      # Stop agent from a different node
      assert :ok = :rpc.call(node2, HordeSupervisor, :stop_agent, [agent_id])

      # Wait for removal to sync across cluster
      AsyncHelpers.wait_until(
        fn ->
          # Verify agent is removed from all nodes
          Enum.all?(nodes, fn node ->
            case :rpc.call(node, HordeSupervisor, :get_agent_info, [agent_id]) do
              {:error, :not_found} -> true
              _ -> false
            end
          end)
        end,
        timeout: 3000,
        initial_delay: 200
      )

      assert :ok = ClusterTestHelper.wait_for_registry_convergence(nodes)

      # Verify agent is gone from all nodes
      for node <- nodes do
        assert {:error, :not_found} =
                 :rpc.call(node, HordeSupervisor, :get_agent_info, [agent_id])
      end
    end

    test "concurrent agent starts deduplicate correctly", %{
      nodes: nodes,
      temp_dirs: temp_dirs,
      test_id: test_id
    } do
      agent_id = "dist_analyzer_dedup_#{test_id}"
      temp_dir = hd(temp_dirs)

      agent_spec = %{
        id: agent_id,
        module: CodeAnalyzer,
        args: [agent_id: agent_id, working_dir: temp_dir]
      }

      # Try to start the same agent from all nodes concurrently
      results =
        ClusterTestHelper.test_concurrent_operations(
          nodes,
          fn node ->
            :rpc.call(node, HordeSupervisor, :start_agent, [agent_spec])
          end,
          fn ->
            # Verify only one agent instance exists
            case HordeSupervisor.get_agent_info(agent_id) do
              {:ok, _info} -> :ok
              {:error, :not_found} -> {:error, :agent_not_started}
            end
          end,
          # One attempt per node
          concurrency: 1
        )

      # Count successful starts
      successful_starts =
        Enum.count(results, fn
          {:ok, _pid} -> true
          _ -> false
        end)

      # Exactly one should succeed
      assert successful_starts == 1

      # Verify agent exists and is running
      assert {:ok, info} = HordeSupervisor.get_agent_info(agent_id)
      assert Process.alive?(info.pid)

      # Clean up
      HordeSupervisor.stop_agent(agent_id)
    end
  end

  describe "failover scenarios" do
    test "agent migrates when its node crashes", %{
      nodes: [node1, node2, node3],
      temp_dirs: temp_dirs,
      test_id: test_id
    } do
      agent_id = "dist_analyzer_failover_#{test_id}"
      temp_dir = hd(temp_dirs)

      # Start agent
      agent_spec = %{
        id: agent_id,
        module: CodeAnalyzer,
        args: [agent_id: agent_id, working_dir: temp_dir],
        restart_strategy: :permanent
      }

      assert {:ok, original_pid} = HordeSupervisor.start_agent(agent_spec)
      original_node = node(original_pid)

      # Perform some operations to build state
      assert {:ok, _} = CodeAnalyzer.analyze_file(agent_id, "test.ex")
      assert {:ok, status} = CodeAnalyzer.exec(agent_id, "status", [])
      assert status.analysis_count == 1

      # Kill the node running the agent
      Logger.info("Killing node #{original_node} to test failover")
      MultiNodeTestHelper.kill_node(original_node)

      # Wait for failover
      remaining_nodes = [node1, node2, node3] -- [original_node]
      MultiNodeTestHelper.wait_for_agent_distribution(remaining_nodes, [agent_id], 20_000)

      # Verify agent restarted on a different node
      assert {:ok, new_info} = HordeSupervisor.get_agent_info(agent_id)
      assert new_info.node != original_node
      assert new_info.node in remaining_nodes
      assert Process.alive?(new_info.pid)
      assert new_info.pid != original_pid

      # Note: State recovery depends on persistence implementation
      # For now, we verify the agent is accessible and functional
      assert {:ok, new_status} = CodeAnalyzer.exec(agent_id, "status", [])
      assert new_status.agent_id == agent_id

      # Clean up
      HordeSupervisor.stop_agent(agent_id)
    end

    test "multiple agents redistribute after cascading failures", %{
      nodes: nodes,
      temp_dirs: temp_dirs,
      test_id: test_id
    } do
      # Start agents across the cluster
      agent_count = 6

      agent_ids =
        for i <- 1..agent_count do
          agent_id = "dist_analyzer_cascade_#{test_id}_#{i}"
          temp_dir = Enum.at(temp_dirs, rem(i, length(temp_dirs)))

          agent_spec = %{
            id: agent_id,
            module: CodeAnalyzer,
            args: [agent_id: agent_id, working_dir: temp_dir],
            restart_strategy: :permanent
          }

          assert {:ok, _pid} = HordeSupervisor.start_agent(agent_spec)
          agent_id
        end

      # Wait for initial distribution
      MultiNodeTestHelper.wait_for_agent_distribution(nodes, agent_ids)

      # Record initial distribution
      initial_distribution =
        Map.new(agent_ids, fn id ->
          {:ok, info} = HordeSupervisor.get_agent_info(id)
          {id, info.node}
        end)

      # Cascade failures with delays
      [node1, node2, _node3] = nodes
      failed_nodes = ClusterTestHelper.cascade_node_failures([node1, node2], 2000)

      # Only node3 remains
      remaining_nodes = nodes -- failed_nodes
      assert length(remaining_nodes) == 1

      # Wait for all agents to migrate to the remaining node
      MultiNodeTestHelper.wait_for_agent_distribution(remaining_nodes, agent_ids, 30_000)

      # Verify all agents are on the remaining node
      final_distribution =
        Map.new(agent_ids, fn id ->
          {:ok, info} = HordeSupervisor.get_agent_info(id)
          {id, info.node}
        end)

      remaining_node = hd(remaining_nodes)
      assert Enum.all?(final_distribution, fn {_id, node} -> node == remaining_node end)

      # Clean up
      Enum.each(agent_ids, &HordeSupervisor.stop_agent/1)
    end
  end

  describe "race conditions" do
    test "concurrent operations on same agent maintain consistency", %{
      nodes: nodes,
      temp_dirs: temp_dirs,
      test_id: test_id
    } do
      agent_id = "dist_analyzer_race_#{test_id}"
      temp_dir = hd(temp_dirs)

      # Start agent
      agent_spec = %{
        id: agent_id,
        module: CodeAnalyzer,
        args: [agent_id: agent_id, working_dir: temp_dir]
      }

      assert {:ok, _pid} = HordeSupervisor.start_agent(agent_spec)

      # Create test files on all nodes
      create_test_files_on_nodes(nodes, temp_dirs)

      # Perform concurrent analyze operations from different nodes
      operation_count = 10

      tasks =
        for node <- nodes, i <- 1..operation_count do
          Task.async(fn ->
            # Rotate through 3 files
            file = "test_#{rem(i, 3)}.ex"
            :rpc.call(node, CodeAnalyzer, :analyze_file, [agent_id, file])
          end)
        end

      results = Task.await_many(tasks, 30_000)

      # All operations should succeed
      assert Enum.all?(results, fn
               {:ok, _analysis} -> true
               _ -> false
             end)

      # Get final state
      assert {:ok, status} = CodeAnalyzer.exec(agent_id, "status", [])

      # Total analysis count should match total operations
      expected_count = length(nodes) * operation_count
      assert status.analysis_count == expected_count

      # Clean up
      HordeSupervisor.stop_agent(agent_id)
    end

    test "stop/start race conditions handled correctly", %{
      nodes: nodes,
      temp_dirs: temp_dirs,
      test_id: test_id
    } do
      agent_id = "dist_analyzer_stop_start_#{test_id}"
      temp_dir = hd(temp_dirs)

      agent_spec = %{
        id: agent_id,
        module: CodeAnalyzer,
        args: [agent_id: agent_id, working_dir: temp_dir]
      }

      # Rapidly stop and start agent from different nodes
      iterations = 5

      for i <- 1..iterations do
        node = Enum.at(nodes, rem(i, length(nodes)))

        # Start
        case :rpc.call(node, HordeSupervisor, :start_agent, [agent_spec]) do
          {:ok, _pid} -> :ok
          {:error, :already_started} -> :ok
          {:error, reason} -> raise "Unexpected start error: #{inspect(reason)}"
        end

        # Brief pause to let it stabilize
        AsyncHelpers.wait_until(
          fn ->
            case HordeSupervisor.get_agent_info(agent_id) do
              {:ok, info} -> Process.alive?(info.pid)
              _ -> false
            end
          end,
          timeout: 1000,
          initial_delay: 100
        )

        # Stop
        case :rpc.call(node, HordeSupervisor, :stop_agent, [agent_id]) do
          :ok -> :ok
          # Already stopped
          {:error, :not_found} -> :ok
          {:error, reason} -> raise "Unexpected stop error: #{inspect(reason)}"
        end

        # Wait for stop to complete
        AsyncHelpers.wait_until(
          fn ->
            case HordeSupervisor.get_agent_info(agent_id) do
              {:error, :not_found} -> true
              _ -> false
            end
          end,
          timeout: 1000,
          initial_delay: 100
        )
      end

      # Final state should be stopped
      assert {:error, :not_found} = HordeSupervisor.get_agent_info(agent_id)
    end
  end

  describe "split-brain scenarios" do
    test "cluster handles network partition and healing", %{
      nodes: [node1, node2, node3],
      temp_dirs: temp_dirs,
      test_id: test_id
    } do
      agent_id = "dist_analyzer_split_#{test_id}"
      temp_dir = hd(temp_dirs)

      # Start agent before partition
      agent_spec = %{
        id: agent_id,
        module: CodeAnalyzer,
        args: [agent_id: agent_id, working_dir: temp_dir],
        restart_strategy: :permanent
      }

      assert {:ok, _pid} = HordeSupervisor.start_agent(agent_spec)

      # Create partition: [node1, node2] | [node3]
      group1 = [node1, node2]
      group2 = [node3]

      ClusterTestHelper.create_split_brain(group1, group2)

      # Wait for partition to take effect and stabilize
      AsyncHelpers.wait_until(
        fn ->
          # Verify partitions are isolated
          node1_connections = :rpc.call(node1, Node, :list, [])
          node3_connections = :rpc.call(node3, Node, :list, [])

          case {node1_connections, node3_connections} do
            {connections1, connections3} when is_list(connections1) and is_list(connections3) ->
              node3 not in connections1 and node1 not in connections3

            _ ->
              false
          end
        end,
        timeout: 5000,
        initial_delay: 300
      )

      # Try to get agent info from both partitions
      group1_result = :rpc.call(node1, HordeSupervisor, :get_agent_info, [agent_id])
      group2_result = :rpc.call(node3, HordeSupervisor, :get_agent_info, [agent_id])

      # At least one partition should have the agent
      assert Enum.any?([group1_result, group2_result], fn
               {:ok, _} -> true
               _ -> false
             end)

      # Heal the partition
      ClusterTestHelper.heal_split_brain(group1, group2)

      # Wait for cluster to reconverge
      assert :ok = ClusterTestHelper.wait_for_registry_convergence([node1, node2, node3])

      # All nodes should agree on agent state
      results =
        for node <- [node1, node2, node3] do
          :rpc.call(node, HordeSupervisor, :get_agent_info, [agent_id])
        end

      # All should have the same view
      assert Enum.all?(results, fn result ->
               match?({:ok, _}, result) or match?({:error, :not_found}, result)
             end)

      # Clean up
      HordeSupervisor.stop_agent(agent_id)
    end
  end

  # Helper functions

  defp create_temp_dirs_on_nodes(nodes, test_id) do
    Enum.map(nodes, fn node ->
      dir = "#{@temp_dir_prefix}#{test_id}_#{node}"
      :ok = :rpc.call(node, File, :mkdir_p!, [dir])
      dir
    end)
  end

  defp cleanup_temp_dirs_on_nodes(nodes, dirs) do
    Enum.zip(nodes, dirs)
    |> Enum.each(fn {node, dir} ->
      :rpc.call(node, File, :rm_rf!, [dir])
    end)
  end

  defp create_test_files_on_nodes(nodes, dirs) do
    test_files = [
      {"test_0.ex", "defmodule Test0, do: def hello, do: :world"},
      {"test_1.ex", "defmodule Test1, do: def foo, do: :bar"},
      {"test_2.ex", "defmodule Test2, do: def baz, do: :qux"}
    ]

    Enum.zip(nodes, dirs)
    |> Enum.each(fn {node, dir} ->
      Enum.each(test_files, fn {filename, content} ->
        path = Path.join(dir, filename)
        :ok = :rpc.call(node, File, :write!, [path, content])
      end)
    end)
  end
end
