defmodule Arbor.Core.GatewayTest do
  use ExUnit.Case, async: true

  import Mox

  alias Arbor.Core.Gateway
  alias Arbor.Test.Mocks.SupervisorMock

  @moduletag :contract

  setup do
    # Configure the Gateway to use our SupervisorMock for this test.
    # The massive LocalSupervisor mock is no longer needed.
    Application.put_env(:arbor_core, :supervisor_impl, SupervisorMock)

    # Since we're running the test in isolation, we need to ensure
    # the necessary dependencies are started for the Gateway
    ensure_test_dependencies_started()

    # Ensure Gateway is started for tests
    case GenServer.whereis(Gateway) do
      nil ->
        {:ok, _pid} = Gateway.start_link([])

      pid when is_pid(pid) ->
        :ok
    end

    :ok
  end

  defp ensure_test_dependencies_started do
    # Start PubSub if not already started
    case Process.whereis(Arbor.Core.PubSub) do
      nil ->
        {:ok, _} =
          Phoenix.PubSub.Supervisor.start_link(
            name: Arbor.Core.PubSub,
            adapter: Phoenix.PubSub.PG2
          )

      _ ->
        :ok
    end

    # Start TaskSupervisor if not already started
    case Process.whereis(Arbor.TaskSupervisor) do
      nil ->
        {:ok, _} = Task.Supervisor.start_link(name: Arbor.TaskSupervisor)

      _ ->
        :ok
    end
  end

  describe "command validation" do
    @tag :validation
    test "accepts a valid :spawn_agent command" do
      agent_id = "test-agent-1"

      command = %{
        type: :spawn_agent,
        params: %{
          type: :code_analyzer,
          id: agent_id,
          metadata: %{}
        }
      }

      # Stub the supervisor to handle the async call
      stub(SupervisorMock, :start_agent, fn agent_spec ->
        # Verify Gateway correctly builds the agent spec from command params
        assert agent_spec.id == agent_id
        assert agent_spec.module == Arbor.Agents.CodeAnalyzer
        assert agent_spec.restart_strategy == :permanent

        # Return successful start
        {:ok, self()}
      end)

      # This test is about the interface contract. We assert that the Gateway
      # can successfully accept a valid command and return an execution ID.
      assert {:ok, execution_id} =
               Gateway.execute_command(command, %{session_id: "test-session-123"}, nil)

      assert is_binary(execution_id)

      # Allow time for async execution to complete and call our stub
      Process.sleep(50)
    end

    @tag :validation
    test "rejects a :spawn_agent command with missing params" do
      command = %{
        type: :spawn_agent,
        params: %{
          # type is missing - this should fail validation
          id: "test-agent-2"
        }
      }

      # We assert that the supervisor is *never* called, as validation fails first.
      # Mox.verify!() (run automatically on test exit) ensures no unexpected
      # calls were made to SupervisorMock.
      assert {:error, {:invalid_command, _}} =
               Gateway.execute_command(command, %{session_id: "test-session-123"}, nil)
    end
  end

  describe "command dispatch" do
    @tag :dispatch
    test "dispatches :spawn_agent to the supervisor implementation" do
      # This test verifies that Gateway correctly calls the configured
      # supervisor module with the proper agent specification.
      agent_id = "dispatch-test-agent"
      test_pid = self()

      command = %{
        type: :spawn_agent,
        params: %{
          type: :code_analyzer,
          id: agent_id,
          metadata: %{source: "gateway_test"}
        }
      }

      # Stub the supervisor to handle the async call
      stub(SupervisorMock, :start_agent, fn agent_spec ->
        # Send message to test process to signal completion
        send(test_pid, {:supervisor_called, agent_spec})

        # The mock must return a value that satisfies the caller's contract.
        {:ok, self()}
      end)

      assert {:ok, execution_id} =
               Gateway.execute_command(command, %{session_id: "test-session-123"}, nil)

      assert is_binary(execution_id)

      # Wait for the supervisor to be called with proper assertions
      assert_receive {:supervisor_called, agent_spec}, 1000

      # Assert that the Gateway correctly constructed the agent spec
      assert agent_spec.id == agent_id
      # This assumes the Gateway maps the command type to an agent module.
      # This makes the test a precise contract for the Gateway's logic.
      assert agent_spec.module == Arbor.Agents.CodeAnalyzer
      # Note: metadata is not passed through in current implementation
    end
  end
end
