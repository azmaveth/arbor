defmodule Arbor.Core.AgentCheckpointTest do
  @moduledoc """
  Tests for the agent checkpoint and recovery functionality.

  Validates that agents can save state to checkpoints and restore
  from them after failures or restarts.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 30_000

  alias Arbor.Core.{HordeSupervisor, AgentCheckpoint, StatefulTestAgent, AgentReconciler}

  # Test configuration
  @registry_name Arbor.Core.HordeAgentRegistry
  @supervisor_name Arbor.Core.HordeAgentSupervisor

  setup_all do
    # Start distributed Erlang if not already started
    case :net_kernel.start([:arbor_checkpoint_test@localhost, :shortnames]) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        :ok

      {:error, reason} ->
        IO.puts("Warning: Could not start distributed Erlang: #{inspect(reason)}")
        :ok
    end

    # Ensure required infrastructure is running
    ensure_horde_infrastructure()

    # Start AgentReconciler if not running
    case GenServer.whereis(AgentReconciler) do
      nil -> start_supervised!(AgentReconciler)
      _pid -> :ok
    end

    on_exit(fn ->
      cleanup_all_test_agents()
    end)

    :ok
  end

  setup do
    # Clean state before each test
    cleanup_all_test_agents()
    :timer.sleep(200)

    :ok
  end

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

      # Load checkpoint
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
      assert info.version == 1
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
      # Allow checkpoint to complete
      :timer.sleep(200)

      # Verify state before restart
      original_state = StatefulTestAgent.get_state(original_pid)
      assert original_state.counter == 2
      assert original_state.data.test_key == "test_value"

      # Verify checkpoint was actually saved
      {:ok, checkpoint_info} = AgentCheckpoint.get_checkpoint_info(agent_id)
      assert checkpoint_info.timestamp != nil
      IO.puts("Checkpoint saved at #{checkpoint_info.timestamp}")

      # Kill the agent to simulate failure
      Process.exit(original_pid, :kill)
      :timer.sleep(100)

      # Force reconciliation to restart the agent
      assert_eventually(
        fn ->
          AgentReconciler.force_reconcile()
          :timer.sleep(300)

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
      IO.puts("Recovered state: #{inspect(recovered_state)}")
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
        # From declarative_supervision_test.exs
        module: TestPersistentAgent,
        args: [agent_id: agent_id],
        restart_strategy: :permanent
      }

      assert {:ok, original_pid} = HordeSupervisor.start_agent(agent_spec)

      # Kill the agent
      Process.exit(original_pid, :kill)
      :timer.sleep(100)

      # Force reconciliation to restart the agent
      assert_eventually(
        fn ->
          AgentReconciler.force_reconcile()
          :timer.sleep(300)

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
      :timer.sleep(200)

      # Verify checkpoint exists
      assert {:ok, _info} = AgentCheckpoint.get_checkpoint_info(agent_id)

      # Stop the agent
      HordeSupervisor.stop_agent(agent_id)
      :timer.sleep(100)

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
    assert_eventually_helper(fun, message, max_attempts, 1)
  end

  defp assert_eventually_helper(fun, message, max_attempts, attempt)
       when attempt <= max_attempts do
    case fun.() do
      :retry when attempt < max_attempts ->
        :timer.sleep(100)
        assert_eventually_helper(fun, message, max_attempts, attempt + 1)

      :retry ->
        flunk("#{message} - max attempts (#{max_attempts}) exceeded")

      result ->
        result
    end
  end

  defp ensure_horde_infrastructure do
    # Start Horde.Registry if not running
    case GenServer.whereis(@registry_name) do
      nil ->
        {:ok, _} =
          start_supervised(
            {Horde.Registry,
             [
               name: @registry_name,
               keys: :unique,
               members: :auto,
               delta_crdt_options: [sync_interval: 100]
             ]}
          )

      _pid ->
        :ok
    end

    # Start Horde.DynamicSupervisor if not running
    case GenServer.whereis(@supervisor_name) do
      nil ->
        {:ok, _} =
          start_supervised(
            {Horde.DynamicSupervisor,
             [
               name: @supervisor_name,
               strategy: :one_for_one,
               distribution_strategy: Horde.UniformRandomDistribution,
               process_redistribution: :active,
               members: :auto,
               delta_crdt_options: [sync_interval: 100]
             ]}
          )

      _pid ->
        :ok
    end

    # Wait for Horde components to stabilize
    :timer.sleep(500)

    # Verify infrastructure is ready
    registry_ready = GenServer.whereis(@registry_name) != nil
    supervisor_ready = GenServer.whereis(@supervisor_name) != nil

    unless registry_ready and supervisor_ready do
      raise "Horde infrastructure failed to start properly"
    end

    :ok
  end

  defp cleanup_all_test_agents do
    # Get all running children and stop test agents
    try do
      children = Horde.DynamicSupervisor.which_children(@supervisor_name)

      for {agent_id, _pid, _type, _modules} <- children do
        if is_binary(agent_id) and String.contains?(agent_id, "test-") do
          HordeSupervisor.stop_agent(agent_id)
        end
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    # Clean up any remaining specs and checkpoints
    try do
      pattern = {{:agent_spec, :"$1"}, :"$2", :"$3"}
      guard = []
      body = [:"$1"]

      specs = Horde.Registry.select(@registry_name, [{pattern, guard, body}])

      for agent_id <- specs do
        if is_binary(agent_id) and String.contains?(agent_id, "test-") do
          spec_key = {:agent_spec, agent_id}
          Horde.Registry.unregister(@registry_name, spec_key)

          checkpoint_key = {:agent_checkpoint, agent_id}
          Horde.Registry.unregister(@registry_name, checkpoint_key)
        end
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end
end

# Re-use test agent from declarative supervision tests
defmodule TestPersistentAgent do
  use GenServer

  alias Arbor.Core.HordeRegistry

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @spec init(keyword()) :: {:ok, map()}
  def init(args) do
    agent_id = Keyword.get(args, :agent_id)

    state = %{
      agent_id: agent_id,
      initial_data: Keyword.get(args, :initial_data),
      started_at: System.system_time(:millisecond)
    }

    if agent_id do
      runtime_metadata = %{started_at: state.started_at}

      case HordeRegistry.register_agent_name(agent_id, self(), runtime_metadata) do
        {:ok, _} ->
          :ok

        error ->
          IO.puts("Agent registration failed: #{inspect(error)}")
      end
    end

    {:ok, state}
  end

  @spec handle_call(:get_state, GenServer.from(), map()) :: {:reply, map(), map()}
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @spec terminate(any(), map()) :: :ok
  def terminate(_reason, state) do
    if state.agent_id do
      HordeRegistry.unregister_agent_name(state.agent_id)
    end

    :ok
  end
end
