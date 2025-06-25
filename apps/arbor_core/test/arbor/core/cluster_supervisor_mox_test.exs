defmodule Arbor.Core.ClusterSupervisorMoxTest do
  @moduledoc """
  Demonstrates Mox-based testing replacing hand-written mocks.

  This test shows how to use Mox with contract-based mocking instead of 
  hand-written LocalSupervisor and LocalClusterRegistry mocks.

  Benefits:
  - Contract enforcement: Mox ensures test mocks match actual behaviours
  - Reduced duplication: No need to maintain parallel mock implementations
  - Better safety: Compile-time verification of mock compliance
  """

  use ExUnit.Case, async: false

  import Arbor.Test.Support.MoxSetup
  import Mox

  alias Arbor.Core.ClusterSupervisor

  @moduletag :integration

  setup_all do
    # Use Mox-based mock implementations
    setup_mock_implementations()

    on_exit(fn ->
      # Reset to auto configuration
      reset_implementations()
    end)

    :ok
  end

  setup :setup_mox

  describe "agent lifecycle with Mox" do
    test "starts agent with valid spec" do
      agent_spec = %{
        id: "test-agent-123",
        module: Arbor.Test.Mocks.TestAgent,
        args: [name: "test", config: %{}],
        restart_strategy: :permanent,
        metadata: %{session_id: "session-456"}
      }

      expected_pid = self()

      # Set up Mox expectation - contract-enforced
      expect_supervisor_start(agent_spec, {:ok, expected_pid})

      # Call the function under test
      assert {:ok, ^expected_pid} = ClusterSupervisor.start_agent(agent_spec)

      # Mox automatically verifies the expectation was met
    end

    test "prevents duplicate agent registration" do
      agent_spec = %{
        id: "duplicate-agent",
        module: Arbor.Test.Mocks.TestAgent,
        args: [],
        restart_strategy: :temporary
      }

      expected_pid = self()

      # Set up expectations for two calls
      expect_supervisor_start(agent_spec, {:ok, expected_pid})
      expect_supervisor_start(agent_spec, {:error, :agent_already_started})

      # First call succeeds
      assert {:ok, ^expected_pid} = ClusterSupervisor.start_agent(agent_spec)

      # Second call fails as expected
      assert {:error, :agent_already_started} = ClusterSupervisor.start_agent(agent_spec)
    end

    test "stops agent gracefully" do
      agent_spec = %{
        id: "stop-test-agent",
        module: Arbor.Test.Mocks.TestAgent,
        args: [],
        restart_strategy: :temporary
      }

      expected_pid = self()

      # Set up expectations
      expect_supervisor_start(agent_spec, {:ok, expected_pid})
      expect_supervisor_info(agent_spec.id, {:ok, %{id: agent_spec.id, pid: expected_pid}})
      expect_supervisor_stop(agent_spec.id, :ok, 5000)
      expect_supervisor_info(agent_spec.id, {:error, :agent_not_found})

      # Start agent
      {:ok, ^expected_pid} = ClusterSupervisor.start_agent(agent_spec)

      # Verify agent is running
      assert {:ok, _info} = ClusterSupervisor.get_agent_info(agent_spec.id)

      # Stop the agent
      assert :ok = ClusterSupervisor.stop_agent(agent_spec.id, 5000)

      # Agent should no longer be found
      assert {:error, :agent_not_found} = ClusterSupervisor.get_agent_info(agent_spec.id)
    end

    test "handles stop of non-existent agent" do
      # Set up expectation for error case
      expect_supervisor_stop("non-existent", {:error, :agent_not_found}, 5000)

      assert {:error, :agent_not_found} = ClusterSupervisor.stop_agent("non-existent", 5000)
    end

    test "restarts agent with same specification" do
      agent_spec = %{
        id: "restart-test-agent",
        module: Arbor.Test.Mocks.TestAgent,
        args: [initial_state: :ready],
        restart_strategy: :permanent
      }

      original_pid = spawn(fn -> :ok end)
      new_pid = self()

      # Set up expectations
      expect_supervisor_start(agent_spec, {:ok, original_pid})
      expect_supervisor_restart(agent_spec.id, {:ok, new_pid})

      expect_supervisor_info(
        agent_spec.id,
        {:ok,
         %{
           id: agent_spec.id,
           pid: new_pid,
           restart_count: 1
         }}
      )

      # Start agent
      {:ok, ^original_pid} = ClusterSupervisor.start_agent(agent_spec)

      # Restart the agent
      assert {:ok, ^new_pid} = ClusterSupervisor.restart_agent(agent_spec.id)

      # Agent info should be updated
      assert {:ok, agent_info} = ClusterSupervisor.get_agent_info(agent_spec.id)
      assert agent_info.pid == new_pid
      assert agent_info.restart_count >= 1
    end

    test "handles restart of non-existent agent" do
      # Set up expectation for error case
      Arbor.Core.MockSupervisor
      |> expect(:restart_agent, fn "non-existent" -> {:error, :agent_not_found} end)

      assert {:error, :agent_not_found} = ClusterSupervisor.restart_agent("non-existent")
    end
  end

  describe "agent listing and information with Mox" do
    test "lists all supervised agents" do
      expected_agents = [
        %{id: "agent-1", status: :running},
        %{id: "agent-2", status: :running},
        %{id: "agent-3", status: :running}
      ]

      # Set up expectation
      expect_supervisor_list({:ok, expected_agents})

      # List all agents
      assert {:ok, agent_list} = ClusterSupervisor.list_agents()
      assert length(agent_list) == 3

      # Verify all agents are present
      agent_ids = Enum.map(agent_list, & &1.id)
      assert "agent-1" in agent_ids
      assert "agent-2" in agent_ids
      assert "agent-3" in agent_ids
    end

    test "returns empty list when no agents" do
      # Set up expectation
      expect_supervisor_list({:ok, []})

      assert {:ok, []} = ClusterSupervisor.list_agents()
    end

    test "gets detailed agent information" do
      agent_id = "info-test-agent"

      expected_info = %{
        id: agent_id,
        pid: self(),
        node: node(),
        status: :running,
        restart_count: 0,
        metadata: %{type: :test_agent, session_id: "session-789"},
        spec: %{restart_strategy: :permanent, max_restarts: 10},
        memory: 1024,
        message_queue_len: 0,
        restart_history: []
      }

      # Set up expectation
      expect_supervisor_info(agent_id, {:ok, expected_info})

      assert {:ok, info} = ClusterSupervisor.get_agent_info(agent_id)

      # Verify comprehensive information
      assert info.id == agent_id
      assert info.pid == self()
      assert info.node == node()
      assert info.status == :running
      assert info.restart_count == 0
      assert info.metadata.type == :test_agent
      assert info.spec.restart_strategy == :permanent
      assert info.spec.max_restarts == 10
      assert is_integer(info.memory)
      assert is_integer(info.message_queue_len)
      assert is_list(info.restart_history)
    end

    test "handles info request for non-existent agent" do
      # Set up expectation
      expect_supervisor_info("non-existent", {:error, :agent_not_found})

      assert {:error, :agent_not_found} = ClusterSupervisor.get_agent_info("non-existent")
    end
  end

  describe "health and monitoring with Mox" do
    test "reports supervision health metrics" do
      expected_health = %{
        total_agents: 3,
        running_agents: 3,
        restarting_agents: 0,
        failed_agents: 0,
        nodes: [node()],
        restart_intensity: 0.1,
        memory_usage: 4096
      }

      # Set up expectation
      expect_supervisor_health({:ok, expected_health})

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
  end

  describe "event handling with Mox" do
    test "registers event handlers for lifecycle events" do
      # For event handlers, we might need to set up expectations differently
      # This shows how Mox can handle more complex scenarios
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event_received, event})
      end

      # Set up expectations for event handler registration
      Arbor.Core.MockSupervisor
      |> expect(:set_event_handler, 2, fn event_type, handler
                                          when event_type in [:agent_started, :agent_stopped] ->
        # Verify the handler is a function
        assert is_function(handler)
        :ok
      end)

      assert :ok = ClusterSupervisor.set_event_handler(:agent_started, callback)
      assert :ok = ClusterSupervisor.set_event_handler(:agent_stopped, callback)
    end
  end
end
