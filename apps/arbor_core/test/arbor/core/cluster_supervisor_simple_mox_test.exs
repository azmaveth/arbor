defmodule Arbor.Core.ClusterSupervisorSimpleMoxTest do
  @moduledoc """
  Simple demonstration of Mox-based testing approach.

  This shows the minimal example of replacing hand-written mocks with Mox.
  """

  use ExUnit.Case, async: false

  import Mox

  alias Arbor.Core.ClusterSupervisor

  # Define mocks for the contracts we need
  defmock(MockSupervisor, for: Arbor.Contracts.Cluster.Supervisor)

  @moduletag :integration

  setup_all do
    # Configure the application to use our Mox-based mock
    Application.put_env(:arbor_core, :supervisor_impl, MockSupervisor)

    on_exit(fn ->
      # Reset to auto configuration
      Application.put_env(:arbor_core, :supervisor_impl, :auto)
    end)

    :ok
  end

  setup :set_mox_private

  describe "basic Mox demonstration" do
    test "start_agent delegates to mock implementation" do
      agent_spec = %{
        id: "test-agent-123",
        module: Arbor.Test.Mocks.TestAgent,
        args: [name: "test"],
        restart_strategy: :permanent
      }

      expected_pid = self()

      # Set up Mox expectation - this enforces the contract
      # The spec gets normalized with defaults, so we match that
      MockSupervisor
      |> expect(:start_agent, fn normalized_spec ->
        assert normalized_spec.id == "test-agent-123"
        assert normalized_spec.module == Arbor.Test.Mocks.TestAgent
        assert normalized_spec.args == [name: "test"]
        assert normalized_spec.restart_strategy == :permanent
        # Should have defaults added
        assert normalized_spec.max_restarts == 5
        assert normalized_spec.max_seconds == 30
        {:ok, expected_pid}
      end)

      # Call the function under test
      assert {:ok, ^expected_pid} = ClusterSupervisor.start_agent(agent_spec)

      # Mox automatically verifies the expectation was met
    end

    test "stop_agent with timeout delegates correctly" do
      agent_id = "test-agent"
      timeout = 5000

      # Set up expectation
      MockSupervisor
      |> expect(:stop_agent, fn ^agent_id, ^timeout ->
        :ok
      end)

      # Call and verify
      assert :ok = ClusterSupervisor.stop_agent(agent_id, timeout)
    end

    test "get_agent_info delegates to implementation" do
      agent_id = "test-agent"

      expected_info = %{
        id: agent_id,
        pid: self(),
        status: :running
      }

      # Set up expectation
      MockSupervisor
      |> expect(:get_agent_info, fn ^agent_id ->
        {:ok, expected_info}
      end)

      # Call and verify
      assert {:ok, info} = ClusterSupervisor.get_agent_info(agent_id)
      assert info.id == agent_id
      assert info.status == :running
    end
  end
end
