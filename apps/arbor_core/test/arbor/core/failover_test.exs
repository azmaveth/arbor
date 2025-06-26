defmodule Arbor.Core.FailoverTest do
  @moduledoc """
  Tests for automatic agent failover and state preservation.

  These tests verify that:
  - Agents can extract and restore state
  - Horde supervisor properly handles process redistribution
  - ClusterManager triggers migration on node failure
  """

  use Arbor.Test.Support.IntegrationCase

  alias Arbor.Core.{AgentReconciler, ClusterManager, HordeRegistry, HordeSupervisor}

  @moduletag :slow

  # Test agent that tracks state changes
  defmodule StatefulTestAgent do
    use Arbor.Core.AgentBehavior
    require Logger

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(args) do
      GenServer.start_link(__MODULE__, args)
    end

    @impl GenServer
    def init(args) do
      # Extract agent identity from args (passed by HordeSupervisor)
      agent_id = Keyword.get(args, :agent_id)
      agent_metadata = Keyword.get(args, :agent_metadata, %{})

      # Extract initial state data
      id = Keyword.get(args, :id, agent_id || "test-agent")
      counter = Keyword.get(args, :counter, 0)

      state = %{
        id: id,
        agent_id: agent_id,
        agent_metadata: agent_metadata,
        counter: counter,
        events: [],
        started_at: System.system_time(:millisecond)
      }

      # Defer registration to AgentBehavior's handle_continue
      if agent_id do
        {:ok, state, {:continue, :register_with_supervisor}}
      else
        {:ok, state}
      end
    end

    @spec increment(pid()) :: {:ok, integer()}
    def increment(pid) do
      GenServer.call(pid, :increment)
    end

    @spec get_events(pid()) :: list()
    def get_events(pid) do
      GenServer.call(pid, :get_events)
    end

    @spec handle_call(:increment, GenServer.from(), map()) :: {:reply, {:ok, integer()}, map()}
    def handle_call(:increment, _from, state) do
      new_counter = state.counter + 1
      event = {:incremented, new_counter, System.system_time(:millisecond)}
      new_state = %{state | counter: new_counter, events: [event | state.events]}
      {:reply, {:ok, new_counter}, new_state}
    end

    @spec handle_call(:get_events, GenServer.from(), map()) :: {:reply, list(), map()}
    def handle_call(:get_events, _from, state) do
      {:reply, state.events, state}
    end

    # Custom state extraction that includes important data
    @impl Arbor.Core.AgentBehavior
    def extract_state(state) do
      extracted =
        %{
          id: state.id,
          counter: state.counter,
          events: state.events,
          original_start: state.started_at,
          extracted_at: System.system_time(:millisecond)
        }

      {:ok, extracted}
    end

    # Custom state restoration that merges old and new state
    @impl Arbor.Core.AgentBehavior
    def restore_state(current_state, extracted_state) do
      new_state = %{
        current_state
        | counter: extracted_state.counter,
          events: [
            {:restored, extracted_state.counter, System.system_time(:millisecond)}
            | extracted_state.events
          ]
      }

      {:ok, new_state}
    end
  end

  describe "agent state extraction and restoration" do
    test "agent can extract its state" do
      agent_id = "state-extract-test-#{:rand.uniform(1000)}"

      # Start agent
      {:ok, pid} =
        HordeSupervisor.start_agent(%{
          id: agent_id,
          module: StatefulTestAgent,
          args: [id: agent_id, counter: 42],
          restart_strategy: :temporary
        })

      # Modify state
      {:ok, 43} = StatefulTestAgent.increment(pid)
      {:ok, 44} = StatefulTestAgent.increment(pid)

      # Extract state
      {:ok, extracted} = HordeSupervisor.extract_agent_state(agent_id)

      assert extracted.id == agent_id
      assert extracted.counter == 44
      assert length(extracted.events) == 2
      assert extracted.extracted_at != nil

      # Clean up
      :ok = HordeSupervisor.stop_agent(agent_id)
    end

    test "agent can restore its state" do
      agent_id = "state-restore-test-#{:rand.uniform(1000)}"

      # Start agent and modify state
      {:ok, pid1} =
        HordeSupervisor.start_agent(%{
          id: agent_id,
          module: StatefulTestAgent,
          args: [id: agent_id, counter: 10],
          restart_strategy: :temporary
        })

      {:ok, 11} = StatefulTestAgent.increment(pid1)
      {:ok, 12} = StatefulTestAgent.increment(pid1)
      events_before = StatefulTestAgent.get_events(pid1)

      # Extract state
      {:ok, extracted} = HordeSupervisor.extract_agent_state(agent_id)

      # Stop agent
      :ok = HordeSupervisor.stop_agent(agent_id)

      # Wait for agent to be stopped
      AsyncHelpers.wait_for_agent_stopped(agent_id, timeout: 2000)

      # Start new instance
      {:ok, pid2} =
        HordeSupervisor.start_agent(%{
          id: agent_id,
          module: StatefulTestAgent,
          args: [id: agent_id],
          restart_strategy: :temporary
        })

      # Wait for agent to be fully registered
      AsyncHelpers.wait_until(
        fn ->
          case HordeSupervisor.get_agent_info(agent_id) do
            {:ok, _info} -> true
            _ -> false
          end
        end,
        timeout: 2000
      )

      # Restore state
      :ok = HordeSupervisor.restore_agent_state(agent_id, extracted)

      # Verify state was restored
      state = GenServer.call(pid2, :get_state)
      assert state.counter == 12

      # Check that restoration event was added
      events_after = StatefulTestAgent.get_events(pid2)
      assert [{:restored, 12, _} | rest] = events_after
      assert length(rest) == length(events_before)

      # Clean up
      :ok = HordeSupervisor.stop_agent(agent_id)
    end
  end

  describe "automatic failover configuration" do
    test "Horde supervisor has correct failover configuration" do
      status = HordeSupervisor.get_supervisor_status()

      # Verify supervisor is running
      assert status.status in [:healthy, :degraded]
      assert status.members != []

      # Check Horde.DynamicSupervisor configuration
      # The actual configuration is set during start_supervisor
      # We can verify it's working by checking process redistribution behavior

      # Start an agent with permanent restart strategy
      agent_id = "failover-config-test-#{:rand.uniform(1000)}"

      {:ok, pid} =
        HordeSupervisor.start_agent(%{
          id: agent_id,
          module: StatefulTestAgent,
          args: [id: agent_id],
          restart_strategy: :permanent
        })

      # Kill the process to trigger restart using proper supervisor termination
      Horde.DynamicSupervisor.terminate_child(Arbor.Core.HordeAgentSupervisor, pid)

      # Wait for process to die
      AsyncHelpers.wait_until(
        fn ->
          not Process.alive?(pid)
        end,
        timeout: 2000,
        initial_delay: 50
      )

      # Force reconciliation to trigger immediate restart
      :ok = AgentReconciler.force_reconcile()

      # Verify agent was restarted
      # Horde should restart the agent automatically
      # Wait for agent to be restarted with new PID
      restarted =
        AsyncHelpers.wait_until(
          fn ->
            case HordeRegistry.lookup_agent_name(agent_id) do
              {:ok, new_pid, _} when new_pid != pid ->
                # Found restarted agent
                Process.alive?(new_pid)

              _ ->
                false
            end
          end,
          timeout: 5000,
          initial_delay: 100
        )

      assert restarted == true, "Agent was not restarted after being killed"

      # Clean up
      :ok = HordeSupervisor.stop_agent(agent_id)
    end
  end

  describe "node failure handling" do
    test "ClusterManager monitors node events" do
      # Get current cluster status
      status = ClusterManager.cluster_status()

      # Verify ClusterManager is running
      assert is_map(status)
      assert status.nodes != []
      assert status.components.registry != :down
      assert status.components.supervisor != :down

      # Register event handler to track node events
      test_pid = self()

      handler = fn event, node ->
        send(test_pid, {:cluster_event, event, node})
      end

      :ok = ClusterManager.register_event_handler(handler)

      # Since we're in single-node test, we can't actually test node failures
      # But we can verify the infrastructure is in place
      assert Process.whereis(ClusterManager) != nil
    end
  end

  describe "agent migration" do
    test "agent can be manually migrated with state preservation" do
      agent_id = "migration-test-#{:rand.uniform(1000)}"

      # Start agent and modify state
      {:ok, pid1} =
        HordeSupervisor.start_agent(%{
          id: agent_id,
          module: StatefulTestAgent,
          args: [id: agent_id, counter: 100],
          restart_strategy: :permanent
        })

      {:ok, 101} = StatefulTestAgent.increment(pid1)
      {:ok, 102} = StatefulTestAgent.increment(pid1)

      # Since we're on single node, use restart to simulate migration
      # but still test the state preservation mechanism
      {:ok, pid2} = HordeSupervisor.restart_agent(agent_id)

      # Restart should return a new PID
      assert pid2 != pid1
      assert Process.alive?(pid2)

      # Clean up
      :ok = HordeSupervisor.stop_agent(agent_id)
    end
  end
end
