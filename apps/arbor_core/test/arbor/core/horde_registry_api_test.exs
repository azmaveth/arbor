defmodule Arbor.Core.HordeRegistryApiTest do
  @moduledoc """
  Tests for Horde Registry API usage patterns to ensure we use the correct API
  and prevent regressions to the old GenServer.call pattern that caused failures.

  This test covers the fixes for Issue: FunctionClauseError in Horde.RegistryImpl
  when using incorrect GenServer.call({:lookup, agent_id}) pattern.
  """

  use Arbor.Test.Support.IntegrationCase

  alias Arbor.Core.{HordeRegistry, HordeSupervisor}

  @moduletag :integration

  describe "Horde Registry API patterns" do
    test "Horde.Registry.select works correctly for agent lookup", %{} do
      agent_id = "test-horde-api-#{:erlang.unique_integer([:positive])}"

      # Start a test agent through the proper supervisor
      agent_spec = %{
        id: agent_id,
        start:
          {Arbor.Test.Mocks.TestAgent, :start_link,
           [[name: {:via, Horde.Registry, {Arbor.Core.HordeAgentRegistry, agent_id}}]]},
        restart: :transient,
        type: :worker
      }

      {:ok, agent_pid} = HordeSupervisor.start_agent(agent_spec)

      # Wait a moment for registration to complete
      Process.sleep(100)

      # Test the CORRECT Horde.Registry.select pattern
      select_result =
        Horde.Registry.select(Arbor.Core.HordeAgentRegistry, [
          {{agent_id, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}
        ])

      case select_result do
        [] ->
          flunk("Agent should be registered and findable via Horde.Registry.select")

        [{pid, _metadata}] ->
          assert pid == agent_pid, "Registry should return the correct PID"

        results when is_list(results) ->
          assert length(results) >= 1, "Should find at least one registered agent"
          {found_pid, _} = hd(results)
          assert is_pid(found_pid), "Result should contain a valid PID"
      end

      # Clean up
      HordeSupervisor.stop_agent(agent_id)
    end

    test "GenServer.call with {:lookup, agent_id} pattern fails as expected", %{} do
      agent_id = "test-genserver-lookup-#{:erlang.unique_integer([:positive])}"

      # Start a test agent
      agent_spec = %{
        id: agent_id,
        start:
          {Arbor.Test.Mocks.TestAgent, :start_link,
           [[name: {:via, Horde.Registry, {Arbor.Core.HordeAgentRegistry, agent_id}}]]},
        restart: :transient,
        type: :worker
      }

      {:ok, _agent_pid} = HordeSupervisor.start_agent(agent_spec)
      Process.sleep(100)

      # Test that the OLD INCORRECT pattern fails
      assert_raise FunctionClauseError, fn ->
        GenServer.call(Arbor.Core.HordeAgentRegistry, {:lookup, agent_id})
      end

      # Clean up
      HordeSupervisor.stop_agent(agent_id)
    end

    test "HordeRegistry.lookup_agent_name wrapper works correctly", %{} do
      agent_id = "test-wrapper-lookup-#{:erlang.unique_integer([:positive])}"

      # Start a test agent and register it properly
      agent_spec = %{
        id: agent_id,
        start:
          {Arbor.Test.Mocks.TestAgent, :start_link,
           [[name: {:via, Horde.Registry, {Arbor.Core.HordeAgentRegistry, agent_id}}]]},
        restart: :transient,
        type: :worker
      }

      {:ok, agent_pid} = HordeSupervisor.start_agent(agent_spec)

      # Register the agent with metadata using our wrapper
      metadata = %{type: :test_agent, started_at: DateTime.utc_now()}
      :ok = HordeRegistry.register_agent_name(agent_id, agent_pid, metadata)

      # Test the wrapper function
      case HordeRegistry.lookup_agent_name(agent_id) do
        {:ok, found_pid, found_metadata} ->
          assert found_pid == agent_pid, "Should return correct PID"
          assert is_map(found_metadata), "Should return metadata"
          assert found_metadata.type == :test_agent, "Should preserve metadata"

        {:error, reason} ->
          flunk("Agent lookup should succeed, got error: #{inspect(reason)}")
      end

      # Clean up
      HordeSupervisor.stop_agent(agent_id)
    end

    test "Registry handles multiple agents correctly", %{} do
      base_id = "multi-agent-#{:erlang.unique_integer([:positive])}"
      agent_ids = for i <- 1..3, do: "#{base_id}-#{i}"

      # Start multiple agents
      agent_pids =
        for agent_id <- agent_ids do
          agent_spec = %{
            id: agent_id,
            start:
              {Arbor.Test.Mocks.TestAgent, :start_link,
               [[name: {:via, Horde.Registry, {Arbor.Core.HordeAgentRegistry, agent_id}}]]},
            restart: :transient,
            type: :worker
          }

          {:ok, pid} = HordeSupervisor.start_agent(agent_spec)
          {agent_id, pid}
        end

      Process.sleep(200)

      # Test that we can find all agents using the correct pattern
      for {agent_id, expected_pid} <- agent_pids do
        select_result =
          Horde.Registry.select(Arbor.Core.HordeAgentRegistry, [
            {{agent_id, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}
          ])

        assert length(select_result) >= 1, "Should find agent #{agent_id}"
        {found_pid, _metadata} = hd(select_result)
        assert found_pid == expected_pid, "Should find correct PID for #{agent_id}"
      end

      # Clean up all agents
      for {agent_id, _pid} <- agent_pids do
        HordeSupervisor.stop_agent(agent_id)
      end
    end

    test "Registry select with complex patterns works", %{} do
      agent_id = "pattern-test-#{:erlang.unique_integer([:positive])}"

      # Start agent and register with specific metadata
      agent_spec = %{
        id: agent_id,
        start:
          {Arbor.Test.Mocks.TestAgent, :start_link,
           [[name: {:via, Horde.Registry, {Arbor.Core.HordeAgentRegistry, agent_id}}]]},
        restart: :transient,
        type: :worker
      }

      {:ok, agent_pid} = HordeSupervisor.start_agent(agent_spec)

      metadata = %{type: :test_agent, category: :integration_test}
      :ok = HordeRegistry.register_agent_name(agent_id, agent_pid, metadata)

      # Test different select patterns

      # Pattern 1: Find by exact agent_id
      exact_match =
        Horde.Registry.select(Arbor.Core.HordeAgentRegistry, [
          {{agent_id, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}
        ])

      assert length(exact_match) == 1, "Should find exactly one agent with exact ID match"

      # Pattern 2: Find all agents (wildcard pattern)
      all_agents =
        Horde.Registry.select(Arbor.Core.HordeAgentRegistry, [
          {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
        ])

      assert length(all_agents) >= 1, "Should find at least our test agent"

      # Verify our agent is in the results
      agent_found =
        Enum.any?(all_agents, fn {id, pid, _meta} ->
          id == agent_id and pid == agent_pid
        end)

      assert agent_found, "Our test agent should be found in wildcard search"

      # Clean up
      HordeSupervisor.stop_agent(agent_id)
    end
  end

  describe "Error handling and edge cases" do
    test "Registry select handles empty results gracefully", %{} do
      nonexistent_id = "nonexistent-#{:erlang.unique_integer([:positive])}"

      select_result =
        Horde.Registry.select(Arbor.Core.HordeAgentRegistry, [
          {{nonexistent_id, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}
        ])

      assert select_result == [], "Should return empty list for nonexistent agent"
    end

    test "Registry select handles malformed patterns gracefully", %{} do
      # Test with malformed pattern - should not crash
      assert_raise FunctionClauseError, fn ->
        Horde.Registry.select(Arbor.Core.HordeAgentRegistry, "invalid_pattern")
      end
    end

    test "Concurrent registry operations work correctly", %{} do
      base_id = "concurrent-#{:erlang.unique_integer([:positive])}"

      # Start multiple agents concurrently
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            agent_id = "#{base_id}-#{i}"

            agent_spec = %{
              id: agent_id,
              start:
                {Arbor.Test.Mocks.TestAgent, :start_link,
                 [[name: {:via, Horde.Registry, {Arbor.Core.HordeAgentRegistry, agent_id}}]]},
              restart: :transient,
              type: :worker
            }

            {:ok, pid} = HordeSupervisor.start_agent(agent_spec)
            {agent_id, pid}
          end)
        end

      # Wait for all to complete
      agent_results = Task.await_many(tasks, 5000)

      # Verify all agents are registered correctly
      for {agent_id, expected_pid} <- agent_results do
        select_result =
          Horde.Registry.select(Arbor.Core.HordeAgentRegistry, [
            {{agent_id, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}
          ])

        assert length(select_result) >= 1, "Agent #{agent_id} should be registered"
        {found_pid, _} = hd(select_result)
        assert found_pid == expected_pid, "Should find correct PID for #{agent_id}"
      end

      # Clean up all agents
      for {agent_id, _pid} <- agent_results do
        HordeSupervisor.stop_agent(agent_id)
      end
    end
  end
end
