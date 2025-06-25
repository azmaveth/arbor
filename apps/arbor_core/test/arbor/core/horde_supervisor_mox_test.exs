defmodule Arbor.Core.HordeSupervisorMoxTest do
  @moduledoc """
  Unit tests for HordeSupervisor using Mox for contract-based mocking.

  This test demonstrates the Mox migration pattern for testing supervisor
  behavior without requiring distributed infrastructure.

  MIGRATION NOTE: This complements the existing integration test (horde_supervisor_test.exs)
  which tests real infrastructure. This test focuses on the API contract behavior.
  """
  use ExUnit.Case, async: true

  import Mox

  alias Arbor.Core.HordeSupervisor
  alias Arbor.Test.Support.MoxSetup

  setup :verify_on_exit!
  setup :set_mox_from_context

  setup do
    # Setup Mox mocks for this test
    MoxSetup.setup_all_mocks()

    # Configure application to use mocked implementations
    original_registry = Application.get_env(:arbor_core, :registry_impl)
    original_supervisor = Application.get_env(:arbor_core, :supervisor_impl)

    Application.put_env(:arbor_core, :registry_impl, MoxSetup.MockRegistry)
    Application.put_env(:arbor_core, :supervisor_impl, MoxSetup.MockSupervisor)

    on_exit(fn ->
      Application.put_env(:arbor_core, :registry_impl, original_registry)
      Application.put_env(:arbor_core, :supervisor_impl, original_supervisor)
    end)

    :ok
  end

  describe "start_agent/1" do
    test "successfully starts and registers an agent" do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"

      agent_spec = %{
        id: agent_id,
        module: Arbor.Test.Mocks.TestAgent,
        args: [agent_id: agent_id],
        restart_strategy: :permanent,
        metadata: %{type: :test}
      }

      expected_pid = spawn(fn -> :ok end)

      # Mock registry to check if agent spec already exists (it doesn't)
      MoxSetup.MockRegistry
      |> expect(:lookup, fn {:agent_spec, ^agent_id} ->
        {:error, :not_found}
      end)

      # Mock registry registration of agent spec
      MoxSetup.MockRegistry
      |> expect(:register, fn {:agent_spec, ^agent_id}, spec_metadata ->
        assert spec_metadata.module == Arbor.Test.Mocks.TestAgent
        assert spec_metadata.restart_strategy == :permanent
        assert spec_metadata.metadata.type == :test
        :ok
      end)

      # Mock supervisor to start the agent process
      MoxSetup.MockSupervisor
      |> expect(:start_child, fn supervisor_name, child_spec ->
        assert supervisor_name == Arbor.Core.HordeAgentSupervisor
        assert child_spec.id == agent_id

        assert child_spec.start ==
                 {Arbor.Test.Mocks.TestAgent, :start_link, [[agent_id: agent_id]]}

        {:ok, expected_pid}
      end)

      # Execute the function under test
      assert {:ok, pid} = HordeSupervisor.start_agent(agent_spec)
      assert pid == expected_pid
    end

    test "returns error when agent is already started" do
      agent_id = "duplicate-agent-#{System.unique_integer([:positive])}"

      agent_spec = %{
        id: agent_id,
        module: Arbor.Test.Mocks.TestAgent,
        args: [agent_id: agent_id]
      }

      # Mock registry to indicate agent spec already exists
      MoxSetup.MockRegistry
      |> expect(:lookup, fn {:agent_spec, ^agent_id} ->
        {:ok, %{module: Arbor.Test.Mocks.TestAgent, created_at: System.system_time()}}
      end)

      # No supervisor mock needed - should fail before reaching supervisor

      assert {:error, :already_started} = HordeSupervisor.start_agent(agent_spec)
    end
  end

  describe "stop_agent/1" do
    test "successfully stops a running agent" do
      agent_id = "stop-test-#{System.unique_integer([:positive])}"
      agent_pid = spawn(fn -> :ok end)

      # Mock registry lookup to find the running agent
      MoxSetup.MockRegistry
      |> expect(:lookup, fn {:agent, ^agent_id} ->
        {:ok, agent_pid, %{started_at: System.system_time()}}
      end)

      # Mock registry unregistration
      MoxSetup.MockRegistry
      |> expect(:unregister, fn {:agent, ^agent_id} ->
        :ok
      end)

      # Mock supervisor termination
      MoxSetup.MockSupervisor
      |> expect(:terminate_child, fn supervisor_name, pid ->
        assert supervisor_name == Arbor.Core.HordeAgentSupervisor
        assert pid == agent_pid
        :ok
      end)

      # Mock registry cleanup of agent spec
      MoxSetup.MockRegistry
      |> expect(:unregister, fn {:agent_spec, ^agent_id} ->
        :ok
      end)

      assert :ok = HordeSupervisor.stop_agent(agent_id)
    end

    test "gracefully handles stopping non-existent agent" do
      agent_id = "non-existent-#{System.unique_integer([:positive])}"

      # Mock registry lookup to indicate agent not found
      MoxSetup.MockRegistry
      |> expect(:lookup, fn {:agent, ^agent_id} ->
        {:error, :not_found}
      end)

      # Mock cleanup of any lingering spec
      MoxSetup.MockRegistry
      |> expect(:unregister, fn {:agent_spec, ^agent_id} ->
        :ok
      end)

      assert :ok = HordeSupervisor.stop_agent(agent_id)
    end
  end

  describe "get_agent_info/1" do
    test "returns complete agent information for running agent" do
      agent_id = "info-test-#{System.unique_integer([:positive])}"
      agent_pid = spawn(fn -> :ok end)
      created_at = System.system_time()
      started_at = System.system_time()

      # Mock agent spec lookup
      MoxSetup.MockRegistry
      |> expect(:lookup, fn {:agent_spec, ^agent_id} ->
        {:ok,
         %{
           module: Arbor.Test.Mocks.TestAgent,
           restart_strategy: :permanent,
           metadata: %{type: :test},
           created_at: created_at
         }}
      end)

      # Mock runtime agent lookup
      MoxSetup.MockRegistry
      |> expect(:lookup, fn {:agent, ^agent_id} ->
        {:ok, agent_pid, %{started_at: started_at, node: node()}}
      end)

      assert {:ok, info} = HordeSupervisor.get_agent_info(agent_id)
      assert info.id == agent_id
      assert info.pid == agent_pid
      assert info.module == Arbor.Test.Mocks.TestAgent
      assert info.restart_strategy == :permanent
      assert info.created_at == created_at
      assert info.metadata.type == :test
      assert info.metadata.started_at == started_at
    end

    test "returns error for non-existent agent" do
      agent_id = "missing-#{System.unique_integer([:positive])}"

      # Mock agent spec lookup failure
      MoxSetup.MockRegistry
      |> expect(:lookup, fn {:agent_spec, ^agent_id} ->
        {:error, :not_found}
      end)

      assert {:error, :not_found} = HordeSupervisor.get_agent_info(agent_id)
    end
  end

  describe "list_agents/0" do
    test "returns list of all agents with their information" do
      # Setup test data
      agent1_id = "list-test-1-#{System.unique_integer([:positive])}"
      agent2_id = "list-test-2-#{System.unique_integer([:positive])}"

      agent1_pid = spawn(fn -> :ok end)
      agent2_pid = spawn(fn -> :ok end)

      created_at = System.system_time()

      # Mock registry to return all agent specs
      MoxSetup.MockRegistry
      |> expect(:match, fn {:agent_spec, :_} ->
        [
          {{:agent_spec, agent1_id},
           %{
             module: Arbor.Test.Mocks.TestAgent,
             restart_strategy: :permanent,
             metadata: %{type: :test1},
             created_at: created_at
           }},
          {{:agent_spec, agent2_id},
           %{
             module: Arbor.Test.Mocks.TestAgent,
             restart_strategy: :transient,
             metadata: %{type: :test2},
             created_at: created_at
           }}
        ]
      end)

      # Mock runtime lookups for each agent
      MoxSetup.MockRegistry
      |> expect(:lookup, fn {:agent, ^agent1_id} ->
        {:ok, agent1_pid, %{started_at: created_at}}
      end)
      |> expect(:lookup, fn {:agent, ^agent2_id} ->
        # This agent has spec but isn't running
        {:error, :not_found}
      end)

      assert {:ok, agents} = HordeSupervisor.list_agents()
      assert length(agents) == 2

      # Find agents in list (order not guaranteed)
      agent1 = Enum.find(agents, &(&1.id == agent1_id))
      agent2 = Enum.find(agents, &(&1.id == agent2_id))

      assert agent1.pid == agent1_pid
      assert agent1.status == :running
      assert agent1.module == Arbor.Test.Mocks.TestAgent

      assert agent2.pid == nil
      assert agent2.status == :stopped
      assert agent2.module == Arbor.Test.Mocks.TestAgent
    end
  end
end
