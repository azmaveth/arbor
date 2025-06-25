defmodule Arbor.Agents.CodeAnalyzerTest do
  use ExUnit.Case, async: false
  
  @moduletag :slow

  alias Arbor.Core.ClusterSupervisor

  # Using setup_all to start Horde once for all tests in this module
  setup_all do
    # Ensure Horde is started and this node is part of the cluster
    # In a real test suite, this might be handled in test_helper.exs
    children = [
      {Horde.Registry, name: :agent_registry, keys: :unique, members: [node()]},
      {Horde.Supervisor, name: :agent_supervisor, members: [node()]}
    ]

    {:ok, _pid} =
      Supervisor.start_link(children, strategy: :one_for_one, name: Arbor.Agents.Test.Supervisor)

    wait_for_membership_ready()

    :ok
  end

  describe "CodeAnalyzer Agent Lifecycle" do
    test "starts and stops a code_analyzer agent via ClusterSupervisor" do
      agent_id = "test_analyzer_#{System.unique_integer([:positive])}"

      spec = %{
        agent_id: agent_id,
        agent_type: :code_analyzer,
        agent_config: %{
          "project_path" => "/tmp/project"
        }
      }

      assert {:ok, _pid} = ClusterSupervisor.start_agent(spec)

      # Verify the agent is running
      assert Process.whereis({:via, Horde.Registry, {:agent_registry, agent_id}}) != nil

      assert {:ok, :stopped} = ClusterSupervisor.stop_agent(agent_id)

      # Verify the agent is stopped
      # Give it a moment to unregister
      Process.sleep(100)
      assert Process.whereis({:via, Horde.Registry, {:agent_registry, agent_id}}) == nil
    end
  end

  defp wait_for_membership_ready(max_wait_ms \\ 5000, interval_ms \\ 100) do
    start_time = System.monotonic_time(:millisecond)
    wait_for_membership_loop(start_time, max_wait_ms, interval_ms)
  end

  defp wait_for_membership_loop(start_time, max_wait_ms, interval_ms) do
    elapsed_time = System.monotonic_time(:millisecond) - start_time

    if elapsed_time > max_wait_ms do
      Logger.error("Timeout waiting for cluster membership.",
        registry_members: Horde.Cluster.members(:agent_registry),
        supervisor_members: Horde.Cluster.members(:agent_supervisor),
        current_node: node()
      )
      raise "Timeout waiting for cluster membership"
    else
      current_node = node()
      registry_members = Horde.Cluster.members(:agent_registry)
      supervisor_members = Horde.Cluster.members(:agent_supervisor)

      # Extract actual nodes from potential keyword list format
      registry_nodes =
        Enum.map(registry_members, fn
          {node, _} when is_atom(node) -> node
          node when is_atom(node) -> node
          other -> other
        end)

      supervisor_nodes =
        Enum.map(supervisor_members, fn
          {node, _} when is_atom(node) -> node
          node when is_atom(node) -> node
          other -> other
        end)

      if current_node in registry_nodes and current_node in supervisor_nodes do
        :ok
      else
        Process.sleep(interval_ms)
        wait_for_membership_loop(start_time, max_wait_ms, interval_ms)
      end
    end
  end
end
