defmodule Arbor.Core.ClusterSupervisorTest do
  @moduledoc """
  Unit tests for distributed agent supervision logic using local mocks.

  These tests use MOCK implementations to test supervision logic without
  requiring actual distributed clustering. The real Horde-based
  implementation will be tested in integration tests.
  """

  use ExUnit.Case, async: false

  alias Arbor.Core.ClusterSupervisor
  alias Arbor.Test.Mocks.LocalSupervisor

  @moduletag :integration

  setup do
    # MOCK: Use local implementations for unit testing
    Application.put_env(:arbor_core, :registry_impl, :mock)
    Application.put_env(:arbor_core, :supervisor_impl, :mock)

    # Start the mock registry and supervisor (handle already started)
    case Arbor.Test.Mocks.LocalClusterRegistry.start_link() do
      {:ok, _registry} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    case Arbor.Test.Mocks.LocalSupervisor.start_link() do
      {:ok, _supervisor} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Clear any existing state
    Arbor.Test.Mocks.LocalClusterRegistry.clear()
    Arbor.Test.Mocks.LocalSupervisor.clear()

    on_exit(fn ->
      # Reset configuration
      Application.put_env(:arbor_core, :registry_impl, :auto)
      Application.put_env(:arbor_core, :supervisor_impl, :auto)
    end)

    {:ok, state} = Arbor.Test.Mocks.LocalSupervisor.init([])
    %{supervisor_state: state}
  end

  describe "agent lifecycle" do
    test "starts agent with valid spec", %{supervisor_state: state} do
      agent_spec = %{
        id: "test-agent-123",
        module: Arbor.Test.Mocks.TestAgent,
        args: [name: "test", config: %{}],
        restart_strategy: :permanent,
        metadata: %{session_id: "session-456"}
      }

      # MOCK: Use local supervisor for unit testing
      assert {:ok, pid} = ClusterSupervisor.start_agent(agent_spec)
      assert is_pid(pid)

      # Agent should be registered and running
      assert {:ok, agent_info} = ClusterSupervisor.get_agent_info(agent_spec.id)
      assert agent_info.id == agent_spec.id
      assert agent_info.pid == pid
      assert agent_info.status == :running
      assert agent_info.metadata == agent_spec.metadata
    end

    test "prevents duplicate agent registration", %{supervisor_state: state} do
      agent_spec = %{
        id: "duplicate-agent",
        module: Arbor.Test.Mocks.TestAgent,
        args: [],
        restart_strategy: :temporary
      }

      # MOCK: Use local supervisor for unit testing
      assert {:ok, _pid1} = ClusterSupervisor.start_agent(agent_spec)

      # Attempting to start same agent ID should fail
      assert {:error, :agent_already_started} =
               ClusterSupervisor.start_agent(agent_spec)
    end

    test "stops agent gracefully", %{supervisor_state: state} do
      agent_spec = %{
        id: "stop-test-agent",
        module: Arbor.Test.Mocks.TestAgent,
        args: [],
        restart_strategy: :temporary
      }

      # MOCK: Use local supervisor for unit testing
      {:ok, _pid} = ClusterSupervisor.start_agent(agent_spec)

      # Verify agent is running
      assert {:ok, _info} = ClusterSupervisor.get_agent_info(agent_spec.id)

      # Stop the agent
      assert :ok = ClusterSupervisor.stop_agent(agent_spec.id, 5000)

      # Agent should no longer be found
      assert {:error, :agent_not_found} =
               ClusterSupervisor.get_agent_info(agent_spec.id)
    end

    test "handles stop of non-existent agent", %{supervisor_state: state} do
      # MOCK: Use local supervisor for unit testing
      assert {:error, :agent_not_found} =
               ClusterSupervisor.stop_agent("non-existent", 5000)
    end

    test "restarts agent with same specification", %{supervisor_state: state} do
      agent_spec = %{
        id: "restart-test-agent",
        module: Arbor.Test.Mocks.TestAgent,
        args: [initial_state: :ready],
        restart_strategy: :permanent
      }

      # MOCK: Use local supervisor for unit testing
      {:ok, original_pid} = ClusterSupervisor.start_agent(agent_spec)

      # Restart the agent
      assert {:ok, new_pid} = ClusterSupervisor.restart_agent(agent_spec.id)

      # Should have new PID
      assert new_pid != original_pid

      # Agent info should be updated
      assert {:ok, agent_info} = ClusterSupervisor.get_agent_info(agent_spec.id)
      assert agent_info.pid == new_pid
      assert agent_info.restart_count >= 1
    end

    test "handles restart of non-existent agent", %{supervisor_state: state} do
      # MOCK: Use local supervisor for unit testing
      assert {:error, :agent_not_found} =
               ClusterSupervisor.restart_agent("non-existent")
    end
  end

  describe "agent listing and information" do
    test "lists all supervised agents", %{supervisor_state: state} do
      # Start multiple agents
      agents = [
        %{
          id: "agent-1",
          module: Arbor.Test.Mocks.TestAgent,
          args: [],
          restart_strategy: :permanent
        },
        %{
          id: "agent-2",
          module: Arbor.Test.Mocks.TestAgent,
          args: [],
          restart_strategy: :temporary
        },
        %{
          id: "agent-3",
          module: Arbor.Test.Mocks.TestAgent,
          args: [],
          restart_strategy: :transient
        }
      ]

      # MOCK: Use local supervisor for unit testing
      for agent_spec <- agents do
        {:ok, _pid} = ClusterSupervisor.start_agent(agent_spec)
      end

      # List all agents
      assert {:ok, agent_list} = ClusterSupervisor.list_agents()
      assert length(agent_list) == 3

      # Verify all agents are present
      agent_ids = Enum.map(agent_list, & &1.id)
      assert "agent-1" in agent_ids
      assert "agent-2" in agent_ids
      assert "agent-3" in agent_ids
    end

    test "returns empty list when no agents", %{supervisor_state: state} do
      # MOCK: Use local supervisor for unit testing
      assert {:ok, []} = ClusterSupervisor.list_agents()
    end

    test "gets detailed agent information", %{supervisor_state: state} do
      agent_spec = %{
        id: "info-test-agent",
        module: Arbor.Test.Mocks.TestAgent,
        args: [config: %{mode: :test}],
        restart_strategy: :permanent,
        max_restarts: 10,
        metadata: %{type: :test_agent, session_id: "session-789"}
      }

      # MOCK: Use local supervisor for unit testing
      {:ok, pid} = ClusterSupervisor.start_agent(agent_spec)

      assert {:ok, info} = ClusterSupervisor.get_agent_info(agent_spec.id)

      # Verify comprehensive information
      assert info.id == agent_spec.id
      assert info.pid == pid
      assert info.node == node()
      assert info.status == :running
      assert info.restart_count == 0
      assert info.metadata == agent_spec.metadata
      assert info.spec.restart_strategy == :permanent
      assert info.spec.max_restarts == 10
      assert is_integer(info.memory)
      assert is_integer(info.message_queue_len)
      assert is_list(info.restart_history)
    end

    test "handles info request for non-existent agent", %{supervisor_state: state} do
      # MOCK: Use local supervisor for unit testing
      assert {:error, :agent_not_found} =
               ClusterSupervisor.get_agent_info("non-existent")
    end
  end

  # Migration tests have been removed as migrate_agent/2 has been replaced
  # with restore_agent/1 which handles state recovery and optimal node placement
  # automatically via Horde

  describe "supervision strategy updates" do
    test "updates agent supervision strategy", %{supervisor_state: state} do
      agent_spec = %{
        id: "update-test-agent",
        module: Arbor.Test.Mocks.TestAgent,
        args: [],
        restart_strategy: :temporary,
        max_restarts: 3
      }

      # MOCK: Use local supervisor for unit testing
      {:ok, _pid} = ClusterSupervisor.start_agent(agent_spec)

      # Update supervision strategy
      updates = %{
        restart_strategy: :permanent,
        max_restarts: 10,
        max_seconds: 60
      }

      assert :ok = ClusterSupervisor.update_agent_spec(agent_spec.id, updates)

      # Verify updates applied
      assert {:ok, info} = ClusterSupervisor.get_agent_info(agent_spec.id)
      assert info.spec.restart_strategy == :permanent
      assert info.spec.max_restarts == 10
      assert info.spec.max_seconds == 60
    end

    test "handles spec update for non-existent agent", %{supervisor_state: state} do
      updates = %{restart_strategy: :permanent}

      # MOCK: Use local supervisor for unit testing
      assert {:error, :agent_not_found} =
               ClusterSupervisor.update_agent_spec("non-existent", updates)
    end
  end

  describe "health and monitoring" do
    test "reports supervision health metrics", %{supervisor_state: state} do
      # Start agents with different configurations
      agents = [
        %{
          id: "healthy-1",
          module: Arbor.Test.Mocks.TestAgent,
          args: [],
          restart_strategy: :permanent
        },
        %{
          id: "healthy-2",
          module: Arbor.Test.Mocks.TestAgent,
          args: [],
          restart_strategy: :temporary
        },
        %{
          id: "healthy-3",
          module: Arbor.Test.Mocks.TestAgent,
          args: [],
          restart_strategy: :transient
        }
      ]

      # MOCK: Use local supervisor for unit testing
      for agent_spec <- agents do
        {:ok, _pid} = ClusterSupervisor.start_agent(agent_spec)
      end

      assert {:ok, health} = ClusterSupervisor.health_metrics()

      # Verify health metrics structure
      assert health.total_agents == 3
      assert health.running_agents == 3
      assert health.restarting_agents == 0
      assert health.failed_agents == 0
      assert is_list(health.nodes)
      assert is_number(health.restart_intensity)
      assert is_integer(health.memory_usage)
    end

    test "tracks restart intensity", %{supervisor_state: state} do
      agent_spec = %{
        id: "restart-intensity-agent",
        module: Arbor.Test.Mocks.TestAgent,
        args: [],
        restart_strategy: :permanent
      }

      # MOCK: Use local supervisor for unit testing
      {:ok, _pid} = ClusterSupervisor.start_agent(agent_spec)

      # Restart multiple times
      {:ok, _pid} = ClusterSupervisor.restart_agent(agent_spec.id)
      {:ok, _pid} = ClusterSupervisor.restart_agent(agent_spec.id)

      assert {:ok, health} = ClusterSupervisor.health_metrics()
      assert health.restart_intensity > 0
    end
  end

  describe "event handling" do
    test "registers event handlers for lifecycle events", %{supervisor_state: state} do
      # Set up event handler
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event_received, event})
      end

      # MOCK: Use local supervisor for unit testing
      assert :ok = ClusterSupervisor.set_event_handler(:agent_started, callback)
      assert :ok = ClusterSupervisor.set_event_handler(:agent_stopped, callback)

      agent_spec = %{
        id: "event-test-agent",
        module: Arbor.Test.Mocks.TestAgent,
        args: [],
        restart_strategy: :temporary
      }

      # Start agent - should trigger event
      {:ok, _pid} = ClusterSupervisor.start_agent(agent_spec)

      # Should receive start event
      assert_receive {:event_received, {:agent_started, "event-test-agent", _details}}, 1000

      # Stop agent - should trigger event
      :ok = ClusterSupervisor.stop_agent(agent_spec.id, 5000)

      # Should receive stop event
      assert_receive {:event_received, {:agent_stopped, "event-test-agent", _details}}, 1000
    end
  end

  describe "agent handoff" do
    test "handles agent state handoff for migration", %{supervisor_state: state} do
      agent_spec = %{
        id: "handoff-test-agent",
        module: Arbor.Test.Mocks.TestAgent,
        args: [initial_state: %{important_data: "value"}],
        restart_strategy: :permanent
      }

      # MOCK: Use local supervisor for unit testing
      {:ok, _pid} = ClusterSupervisor.start_agent(agent_spec)

      # Extract state for handoff
      assert {:ok, agent_state} = ClusterSupervisor.extract_agent_state(agent_spec.id)

      assert is_map(agent_state)
      assert Map.has_key?(agent_state, :important_data)

      # Restore state after takeover
      assert {:ok, _restored_state} =
               ClusterSupervisor.restore_agent_state(
                 agent_spec.id,
                 agent_state
               )
    end

    test "handles handoff for non-existent agent", %{supervisor_state: state} do
      # MOCK: Use local supervisor for unit testing
      assert {:error, :agent_not_found} = ClusterSupervisor.extract_agent_state("non-existent")
    end
  end
end
