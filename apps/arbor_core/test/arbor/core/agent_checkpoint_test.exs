defmodule Arbor.Core.AgentCheckpointTest do
  @moduledoc """
  Tests for the agent checkpoint and recovery functionality.

  Validates that agents can save state to checkpoints and restore
  from them after failures or restarts.
  """

  use Arbor.Test.Support.IntegrationCase

  alias Arbor.Core.{AgentCheckpoint, AgentReconciler, HordeSupervisor, StatefulTestAgent}

  describe "checkpoint persistence" do
    test "agents can save and load checkpoints" do
      agent_id = "test-checkpoint-agent-#{System.unique_integer([:positive])}"

      # Create test state
      test_state = %{
        agent_id: agent_id,
        counter: 42,
        data: %{message: "hello world"},
        checkpoint_count: 1
      }

      # Save checkpoint
      assert :ok = AgentCheckpoint.save_checkpoint(agent_id, test_state)

      # Load checkpoint (includes retry mechanism for CRDT sync)
      assert {:ok, loaded_state} = AgentCheckpoint.load_checkpoint(agent_id)
      assert loaded_state.agent_id == agent_id
      assert loaded_state.counter == 42
      assert loaded_state.data.message == "hello world"

      # Clean up
      AgentCheckpoint.remove_checkpoint(agent_id)
    end

    test "loading non-existent checkpoint returns error" do
      agent_id = "non-existent-agent-#{System.unique_integer([:positive])}"

      assert {:error, :not_found} = AgentCheckpoint.load_checkpoint(agent_id)
    end

    test "checkpoint info provides metadata without loading state" do
      agent_id = "test-info-agent-#{System.unique_integer([:positive])}"

      test_state = %{agent_id: agent_id, data: "some data"}

      # Save checkpoint
      assert :ok = AgentCheckpoint.save_checkpoint(agent_id, test_state)

      # Get checkpoint info
      assert {:ok, info} = AgentCheckpoint.get_checkpoint_info(agent_id)
      assert is_integer(info.timestamp)
      assert info.node == node()
      assert info.snapshot_version == "1.0.0"
      assert is_integer(info.age_ms)

      # Clean up
      AgentCheckpoint.remove_checkpoint(agent_id)
    end

    test "can list all checkpointed agents" do
      agent1_id = "checkpoint-list-1-#{System.unique_integer([:positive])}"
      agent2_id = "checkpoint-list-2-#{System.unique_integer([:positive])}"

      # Save checkpoints for multiple agents
      AgentCheckpoint.save_checkpoint(agent1_id, %{agent_id: agent1_id})
      AgentCheckpoint.save_checkpoint(agent2_id, %{agent_id: agent2_id})

      # List checkpointed agents
      checkpointed = AgentCheckpoint.list_checkpointed_agents()
      assert agent1_id in checkpointed
      assert agent2_id in checkpointed

      # Clean up
      AgentCheckpoint.remove_checkpoint(agent1_id)
      AgentCheckpoint.remove_checkpoint(agent2_id)
    end
  end

  describe "stateful agent recovery" do
    test "stateful agent recovers state after restart" do
      agent_id = "test-stateful-recovery-#{System.unique_integer([:positive])}"

      # Start stateful agent
      agent_spec = %{
        id: agent_id,
        module: StatefulTestAgent,
        args: [agent_id: agent_id],
        restart_strategy: :permanent
      }

      assert {:ok, original_pid} = HordeSupervisor.start_agent(agent_spec)

      # Modify agent state
      StatefulTestAgent.increment_counter(original_pid)
      StatefulTestAgent.increment_counter(original_pid)
      StatefulTestAgent.set_value(original_pid, :test_key, "test_value")

      # Force a checkpoint
      StatefulTestAgent.save_checkpoint_now(original_pid)

      # Wait for checkpoint to be persisted using exponential backoff
      AsyncHelpers.wait_until(
        fn ->
          case AgentCheckpoint.get_checkpoint_info(agent_id) do
            {:ok, _info} -> true
            _ -> false
          end
        end,
        timeout: 2000,
        initial_delay: 50
      )

      # Give extra time for Horde CRDT to fully synchronize across the distributed registry
      Process.sleep(200)

      # Verify state before restart
      original_state = StatefulTestAgent.get_state(original_pid)
      assert original_state.counter == 2
      assert original_state.data.test_key == "test_value"

      # Verify checkpoint was actually saved
      {:ok, checkpoint_info} = AgentCheckpoint.get_checkpoint_info(agent_id)
      assert checkpoint_info.timestamp != nil

      # Kill the agent to simulate failure using proper supervisor termination
      Horde.DynamicSupervisor.terminate_child(Arbor.Core.HordeAgentSupervisor, original_pid)

      # Wait for process to actually die using exponential backoff
      AsyncHelpers.wait_until(
        fn ->
          not Process.alive?(original_pid)
        end,
        timeout: 2000,
        initial_delay: 25
      )

      # Force reconciliation to restart the agent
      assert_eventually(
        fn ->
          AgentReconciler.force_reconcile()

          # The assert_eventually helper already handles delays, no need for sleep
          case HordeSupervisor.get_agent_info(agent_id) do
            {:ok, new_agent_info} when new_agent_info.pid != original_pid ->
              if Process.alive?(new_agent_info.pid) do
                {:ok, new_agent_info}
              else
                :retry
              end

            _ ->
              :retry
          end
        end,
        "Agent should be restarted by reconciler"
      )

      # Verify agent was restarted
      {:ok, new_agent_info} = HordeSupervisor.get_agent_info(agent_id)
      new_pid = new_agent_info.pid
      assert new_pid != original_pid
      assert Process.alive?(new_pid)

      # Verify state was recovered
      recovered_state = StatefulTestAgent.get_state(new_pid)
      assert recovered_state.counter == 2
      assert recovered_state.data.test_key == "test_value"
      assert recovered_state.recovered == true

      # Cleanup
      HordeSupervisor.stop_agent(agent_id)
    end

    test "agent without checkpoint behavior starts normally" do
      agent_id = "test-no-checkpoint-#{System.unique_integer([:positive])}"

      # Start a regular test agent (doesn't implement checkpoint behavior)
      agent_spec = %{
        id: agent_id,
        module: CheckpointTestPersistentAgent,
        args: [agent_id: agent_id],
        restart_strategy: :permanent
      }

      assert {:ok, original_pid} = HordeSupervisor.start_agent(agent_spec)

      # Kill the agent using proper supervisor termination
      Horde.DynamicSupervisor.terminate_child(Arbor.Core.HordeAgentSupervisor, original_pid)

      # Wait for process to die
      AsyncHelpers.wait_until(
        fn ->
          not Process.alive?(original_pid)
        end,
        timeout: 2000,
        initial_delay: 25
      )

      # Force reconciliation to restart the agent
      assert_eventually(
        fn ->
          AgentReconciler.force_reconcile()

          # The assert_eventually helper already handles delays, no need for sleep
          case HordeSupervisor.get_agent_info(agent_id) do
            {:ok, new_agent_info} when new_agent_info.pid != original_pid ->
              if Process.alive?(new_agent_info.pid) do
                {:ok, new_agent_info}
              else
                :retry
              end

            _ ->
              :retry
          end
        end,
        "Non-checkpointing agent should restart normally"
      )

      # Verify agent was restarted (but without state recovery)
      {:ok, new_agent_info} = HordeSupervisor.get_agent_info(agent_id)
      assert new_agent_info.pid != original_pid
      assert Process.alive?(new_agent_info.pid)

      # Cleanup
      HordeSupervisor.stop_agent(agent_id)
    end

    test "checkpoint cleanup on agent stop" do
      agent_id = "test-checkpoint-cleanup-#{System.unique_integer([:positive])}"

      # Start stateful agent
      agent_spec = %{
        id: agent_id,
        module: StatefulTestAgent,
        args: [agent_id: agent_id],
        restart_strategy: :temporary
      }

      assert {:ok, pid} = HordeSupervisor.start_agent(agent_spec)

      # Modify state and save checkpoint
      StatefulTestAgent.increment_counter(pid)
      StatefulTestAgent.save_checkpoint_now(pid)

      # Wait for checkpoint to be saved
      AsyncHelpers.wait_until(
        fn ->
          match?({:ok, _}, AgentCheckpoint.get_checkpoint_info(agent_id))
        end,
        timeout: 2000,
        initial_delay: 50
      )

      # Verify checkpoint exists
      assert {:ok, _info} = AgentCheckpoint.get_checkpoint_info(agent_id)

      # Stop the agent
      HordeSupervisor.stop_agent(agent_id)

      # Wait for agent to be stopped
      AsyncHelpers.wait_for_agent_stopped(agent_id, timeout: 2000)

      # Verify checkpoint was cleaned up
      assert {:error, :not_found} = AgentCheckpoint.get_checkpoint_info(agent_id)
    end
  end

  describe "checkpoint telemetry" do
    test "checkpoint operations emit telemetry events" do
      agent_id = "test-telemetry-#{System.unique_integer([:positive])}"

      # Capture telemetry events
      events = []
      test_pid = self()

      handler_id = :checkpoint_test_handler

      :telemetry.attach_many(
        handler_id,
        [
          [:arbor, :checkpoint, :saved],
          [:arbor, :checkpoint, :loaded],
          [:arbor, :checkpoint, :removed]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      # Save checkpoint
      test_state = %{agent_id: agent_id, data: "test"}
      AgentCheckpoint.save_checkpoint(agent_id, test_state)

      # Load checkpoint
      AgentCheckpoint.load_checkpoint(agent_id)

      # Remove checkpoint
      AgentCheckpoint.remove_checkpoint(agent_id)

      # Verify telemetry events
      assert_received {:telemetry, [:arbor, :checkpoint, :saved], measurements, metadata}
      assert measurements.size_bytes > 0
      assert metadata.agent_id == agent_id

      assert_received {:telemetry, [:arbor, :checkpoint, :loaded], measurements, metadata}
      assert measurements.age_ms >= 0
      assert metadata.agent_id == agent_id

      assert_received {:telemetry, [:arbor, :checkpoint, :removed], _measurements, metadata}
      assert metadata.agent_id == agent_id

      # Cleanup
      :telemetry.detach(handler_id)
    end
  end

  # Helper functions

  defp assert_eventually(fun, message, max_attempts \\ 10) do
    AsyncHelpers.assert_eventually(fun, message, max_attempts: max_attempts)
  end
end

# Test agent without checkpointing behavior
defmodule CheckpointTestPersistentAgent do
  use Arbor.Core.AgentBehavior

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl GenServer
  def init(args) do
    agent_id = Keyword.get(args, :agent_id)

    state = %{
      agent_id: agent_id,
      initial_data: Keyword.get(args, :initial_data),
      started_at: System.system_time(:millisecond)
    }

    # Use AgentBehavior's centralized registration
    {:ok, state, {:continue, :register_with_supervisor}}
  end

  @impl Arbor.Core.AgentBehavior
  def get_agent_metadata(state) do
    %{started_at: state.started_at}
  end
end
