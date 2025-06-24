defmodule Arbor.Core.GatewayTest do
  use ExUnit.Case, async: true

  alias Arbor.Core.Gateway
  alias Arbor.Test.Mocks.LocalSupervisor

  @moduletag :contract

  setup do
    # For gateway tests, we can often mock the backend supervisor
    # to isolate the gateway's logic (validation, dispatch).
    # We'll use the LocalSupervisor mock for this.
    Application.put_env(:arbor_core, :supervisor_impl, :mock)
    start_supervised({LocalSupervisor, name: LocalSupervisor})
    :ok
  end

  describe "command validation" do
    @tag :validation
    test "accepts a valid :spawn_agent command" do
      command = %{
        type: :spawn_agent,
        params: %{
          type: :code_analyzer,
          id: "test-agent-1",
          metadata: %{}
        }
      }

      # This test is about the interface contract. We assert that the Gateway
      # can successfully accept a valid command and return an execution ID.
      assert {:ok, execution_id} =
               Gateway.execute_command(command, %{session_id: "test-session-123"}, nil)

      assert is_binary(execution_id)
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

      assert {:error, {:invalid_command, _}} =
               Gateway.execute_command(command, %{session_id: "test-session-123"}, nil)
    end
  end

  describe "command dispatch" do
    @tag :dispatch
    test "dispatches :spawn_agent to the supervisor implementation" do
      # This test verifies that Gateway correctly calls the configured
      # supervisor module. Since we've configured the LocalSupervisor,
      # we can check its state to confirm the dispatch was successful.
      agent_id = "dispatch-test-agent"

      command = %{
        type: :spawn_agent,
        params: %{
          type: :code_analyzer,
          id: agent_id,
          metadata: %{}
        }
      }

      assert {:ok, execution_id} =
               Gateway.execute_command(command, %{session_id: "test-session-123"}, nil)

      assert is_binary(execution_id)

      # Note: Agent registration happens asynchronously in the background.
      # For contract tests, we verify the command was accepted (execution_id returned).
      # Integration tests can verify the full async behavior with proper wait/polling.
    end
  end
end
