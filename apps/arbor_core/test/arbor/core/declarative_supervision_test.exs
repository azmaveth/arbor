defmodule Arbor.Core.DeclarativeSupervisionTest do
  @moduledoc """
  Comprehensive integration tests for the declarative agent supervision architecture.

  Tests the current stateless HordeSupervisor implementation with:
  - Agent specifications stored in Horde.Registry
  - AgentReconciler for self-healing
  - Agent self-registration pattern
  - Automatic failover via Horde process redistribution
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :cluster
  @moduletag timeout: 60_000

  alias Arbor.Core.{HordeSupervisor, AgentReconciler}

  # Test configuration
  @registry_name Arbor.Core.HordeAgentRegistry
  @supervisor_name Arbor.Core.HordeAgentSupervisor
  # Faster reconciliation for tests
  @reconciler_interval 5_000

  setup_all do
    # Start distributed Erlang if not already started
    case :net_kernel.start([:arbor_test@localhost, :shortnames]) do
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
      # Clean up any remaining agents
      cleanup_all_test_agents()
    end)

    :ok
  end

  setup do
    # Clean state before each test
    cleanup_all_test_agents()
    # Allow cleanup to complete
    :timer.sleep(200)

    # Force reconciliation to ensure clean state
    AgentReconciler.force_reconcile()
    :timer.sleep(100)

    :ok
  end

  describe "agent specifications persistence and reconciliation" do
    test "agent specifications persist across node failures" do
      agent_id = "test-persistent-agent-#{System.unique_integer([:positive])}"

      # Start agent with permanent restart strategy
      agent_spec = %{
        id: agent_id,
        module: TestPersistentAgent,
        args: [initial_data: "important_state"],
        restart_strategy: :permanent,
        metadata: %{test: true}
      }

      assert {:ok, original_pid} = HordeSupervisor.start_agent(agent_spec)
      assert is_pid(original_pid)

      # Verify agent spec is stored in registry
      assert {:ok, stored_spec} = get_agent_spec_from_registry(agent_id)
      assert stored_spec.module == TestPersistentAgent
      assert stored_spec.restart_strategy == :permanent

      # Verify agent is running and has state
      assert {:ok, agent_info} = HordeSupervisor.get_agent_info(agent_id)
      assert agent_info.pid == original_pid

      state = GenServer.call(agent_info.pid, :get_state)
      assert state.initial_data == "important_state"

      # Simulate node failure by killing the agent process
      # This simulates what happens when a node goes down
      Process.exit(agent_info.pid, :kill)

      # Wait for Horde to detect failure and restart
      :timer.sleep(1000)

      # AgentReconciler should detect missing agent and restart it
      # Force reconciliation to speed up test
      AgentReconciler.force_reconcile()
      :timer.sleep(500)

      # Verify agent was restarted - may need a few attempts due to timing
      assert_eventually(
        fn ->
          case HordeSupervisor.get_agent_info(agent_id) do
            {:ok, new_agent_info} when new_agent_info.pid != original_pid ->
              {:ok, new_agent_info}

            _ ->
              # Force another reconciliation if needed
              AgentReconciler.force_reconcile()
              :timer.sleep(200)
              :retry
          end
        end,
        "Agent should be restarted after reconciliation"
      )

      {:ok, new_agent_info} = HordeSupervisor.get_agent_info(agent_id)
      assert new_agent_info.pid != original_pid
      assert Process.alive?(new_agent_info.pid)

      # Verify spec still exists in registry
      assert {:ok, persisted_spec} = get_agent_spec_from_registry(agent_id)
      assert persisted_spec.module == TestPersistentAgent

      # Cleanup
      HordeSupervisor.stop_agent(agent_id)
    end

    test "reconciler detects and restarts missing agents" do
      agent_id = "test-missing-agent-#{System.unique_integer([:positive])}"

      # Start agent
      agent_spec = %{
        id: agent_id,
        module: TestMissingAgent,
        args: [recovery_data: "test_recovery"],
        restart_strategy: :permanent
      }

      assert {:ok, original_pid} = HordeSupervisor.start_agent(agent_spec)

      # Verify agent is registered
      assert {:ok, agent_info} = HordeSupervisor.get_agent_info(agent_id)
      assert agent_info.pid == original_pid

      # Manually kill the agent process (simulating crash)
      Process.exit(original_pid, :kill)

      # Wait a moment to ensure process is dead
      :timer.sleep(100)
      refute Process.alive?(original_pid)

      # Force reconciliation and wait for restart
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
        "Missing agent should be restarted by reconciler"
      )

      # Verify agent was restarted by reconciler
      {:ok, new_agent_info} = HordeSupervisor.get_agent_info(agent_id)
      assert new_agent_info.pid != original_pid
      assert Process.alive?(new_agent_info.pid)

      # Verify restarted agent has expected state
      state = GenServer.call(new_agent_info.pid, :get_state)
      assert state.recovery_data == "test_recovery"

      # Cleanup
      HordeSupervisor.stop_agent(agent_id)
    end

    test "reconciler cleans up orphaned processes" do
      agent_id = "test-orphaned-agent-#{System.unique_integer([:positive])}"

      # Start agent normally
      agent_spec = %{
        id: agent_id,
        module: TestOrphanedAgent,
        args: [],
        restart_strategy: :temporary
      }

      assert {:ok, agent_pid} = HordeSupervisor.start_agent(agent_spec)

      # Manually remove the agent spec from registry to simulate orphaning
      remove_agent_spec_from_registry(agent_id)

      # Verify spec is gone but process still running
      assert {:error, :not_found} = get_agent_spec_from_registry(agent_id)
      assert Process.alive?(agent_pid)

      # Force reconciliation
      AgentReconciler.force_reconcile()
      :timer.sleep(500)

      # Verify orphaned process was cleaned up
      refute Process.alive?(agent_pid)

      case HordeSupervisor.get_agent_info(agent_id) do
        {:error, :not_found} -> :ok
        {:ok, info} -> assert info.status != :running
      end
    end

    test "handles different restart strategies correctly" do
      # Test permanent agent - should always restart
      permanent_id = "test-permanent-#{System.unique_integer([:positive])}"

      assert {:ok, permanent_pid} =
               HordeSupervisor.start_agent(%{
                 id: permanent_id,
                 module: TestRestartAgent,
                 args: [strategy: :permanent],
                 restart_strategy: :permanent
               })

      # Test temporary agent - should not restart
      temporary_id = "test-temporary-#{System.unique_integer([:positive])}"

      assert {:ok, temporary_pid} =
               HordeSupervisor.start_agent(%{
                 id: temporary_id,
                 module: TestRestartAgent,
                 args: [strategy: :temporary],
                 restart_strategy: :temporary
               })

      # Kill both agents
      Process.exit(permanent_pid, :kill)
      Process.exit(temporary_pid, :kill)

      :timer.sleep(100)

      # Force reconciliation and wait for restart
      assert_eventually(
        fn ->
          AgentReconciler.force_reconcile()
          :timer.sleep(300)

          case HordeSupervisor.get_agent_info(permanent_id) do
            {:ok, new_permanent_info} when new_permanent_info.pid != permanent_pid ->
              if Process.alive?(new_permanent_info.pid) do
                {:ok, new_permanent_info}
              else
                :retry
              end

            _ ->
              :retry
          end
        end,
        "Permanent agent should be restarted by reconciler"
      )

      # Permanent agent should be restarted
      {:ok, new_permanent_info} = HordeSupervisor.get_agent_info(permanent_id)
      assert new_permanent_info.pid != permanent_pid
      assert Process.alive?(new_permanent_info.pid)

      # Temporary agent should NOT be restarted and spec should be removed
      # Wait for reconciler to clean up temporary agent spec
      assert_eventually(
        fn ->
          AgentReconciler.force_reconcile()
          :timer.sleep(200)

          case get_agent_spec_from_registry(temporary_id) do
            {:error, :not_found} -> :ok
            {:ok, _spec} -> :retry
          end
        end,
        "Temporary agent spec should be removed by reconciler"
      )

      # Verify temporary agent is not running and spec is gone
      case HordeSupervisor.get_agent_info(temporary_id) do
        {:error, :not_found} -> :ok
        {:ok, info} -> assert info.status != :running
      end

      assert {:error, :not_found} = get_agent_spec_from_registry(temporary_id)

      # Cleanup
      HordeSupervisor.stop_agent(permanent_id)
    end
  end

  describe "agent self-registration pattern" do
    test "agents register themselves correctly on startup" do
      agent_id = "test-self-register-#{System.unique_integer([:positive])}"

      agent_spec = %{
        id: agent_id,
        module: TestSelfRegisterAgent,
        args: [agent_id: agent_id],
        restart_strategy: :temporary
      }

      assert {:ok, agent_pid} = HordeSupervisor.start_agent(agent_spec)

      # Give agent time to self-register
      :timer.sleep(200)

      # Verify agent is properly registered
      assert {:ok, agent_info} = HordeSupervisor.get_agent_info(agent_id)
      assert agent_info.pid == agent_pid

      # Verify agent metadata was set during self-registration
      registration_info = GenServer.call(agent_pid, :get_registration_info)
      assert registration_info.self_registered == true
      assert registration_info.registration_time != nil

      # Cleanup
      HordeSupervisor.stop_agent(agent_id)
    end

    test "agents clean up registration on normal termination" do
      agent_id = "test-cleanup-register-#{System.unique_integer([:positive])}"

      agent_spec = %{
        id: agent_id,
        module: TestCleanupAgent,
        args: [agent_id: agent_id],
        restart_strategy: :temporary
      }

      assert {:ok, agent_pid} = HordeSupervisor.start_agent(agent_spec)
      :timer.sleep(100)

      # Verify agent is registered
      assert {:ok, agent_info} = HordeSupervisor.get_agent_info(agent_id)
      assert agent_info.pid == agent_pid

      # Stop agent normally
      GenServer.stop(agent_pid, :normal)
      :timer.sleep(100)

      # Verify agent cleaned up its registration
      case HordeSupervisor.get_agent_info(agent_id) do
        {:error, :not_found} -> :ok
        {:ok, info} -> assert info.status != :running
      end

      # For temporary agents, the spec should be removed by reconciler eventually
      # but may still exist briefly after termination - allow either state
      case get_agent_spec_from_registry(agent_id) do
        # Expected: spec was cleaned up
        {:error, :not_found} ->
          :ok

        {:ok, _spec} ->
          # Spec still exists - force reconciliation to clean it up
          AgentReconciler.force_reconcile()
          :timer.sleep(100)
          # Now it should be gone
          assert {:error, :not_found} = get_agent_spec_from_registry(agent_id)
      end
    end
  end

  describe "horde automatic failover validation" do
    test "agent reconciler handles process failures" do
      # This test validates that AgentReconciler can detect and restart failed processes
      agent_id = "test-horde-failover-#{System.unique_integer([:positive])}"

      agent_spec = %{
        id: agent_id,
        module: TestFailoverAgent,
        args: [failover_test: true],
        restart_strategy: :permanent
      }

      assert {:ok, original_pid} = HordeSupervisor.start_agent(agent_spec)
      original_node = node(original_pid)

      # Store some state in the agent
      :ok = GenServer.call(original_pid, {:store_state, %{test_data: "failover_test"}})

      # Simulate node failure by killing the process abruptly
      Process.exit(original_pid, :kill)

      # Wait for process to die, then use reconciler to restart
      :timer.sleep(100)
      refute Process.alive?(original_pid)

      # Use reconciler to detect and restart the missing agent
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
        "Agent should be restarted after process failure"
      )

      # Agent should be restarted
      {:ok, new_agent_info} = HordeSupervisor.get_agent_info(agent_id)
      assert new_agent_info.pid != original_pid
      assert Process.alive?(new_agent_info.pid)

      # Verify agent restarted on same or different node (in single node test, same node)
      new_node = node(new_agent_info.pid)
      # In single-node test
      assert new_node == original_node

      # Note: State is lost in current implementation (stateless restart)
      # Future enhancement will add state recovery

      # Cleanup
      HordeSupervisor.stop_agent(agent_id)
    end
  end

  describe "reconciler performance and reliability" do
    test "reconciler handles large numbers of agents" do
      # Reduce count to avoid infrastructure issues
      agent_count = 20
      agent_prefix = "test-scale-agent"

      # Start multiple agents
      test_id = System.unique_integer([:positive])

      agent_ids =
        for i <- 1..agent_count do
          agent_id = "#{agent_prefix}-#{test_id}-#{i}"

          agent_spec = %{
            id: agent_id,
            module: TestScaleAgent,
            args: [index: i],
            restart_strategy: :permanent
          }

          assert {:ok, _pid} = HordeSupervisor.start_agent(agent_spec)
          agent_id
        end

      # Wait for all agents to start
      :timer.sleep(1000)

      # Verify all agents are running
      running_count =
        Enum.count(agent_ids, fn agent_id ->
          case HordeSupervisor.get_agent_info(agent_id) do
            {:ok, info} -> Process.alive?(info.pid)
            _ -> false
          end
        end)

      assert running_count == agent_count

      # Kill half the agents randomly
      killed_agents = Enum.take_random(agent_ids, div(agent_count, 2))

      for agent_id <- killed_agents do
        {:ok, info} = HordeSupervisor.get_agent_info(agent_id)
        Process.exit(info.pid, :kill)
      end

      :timer.sleep(100)

      # Force reconciliation
      start_time = System.monotonic_time(:millisecond)
      AgentReconciler.force_reconcile()
      # Allow time for all restarts
      :timer.sleep(2000)
      end_time = System.monotonic_time(:millisecond)

      reconcile_duration = end_time - start_time
      IO.puts("Reconciliation of #{length(killed_agents)} agents took #{reconcile_duration}ms")

      # Verify all agents are running again
      final_running_count =
        Enum.count(agent_ids, fn agent_id ->
          case HordeSupervisor.get_agent_info(agent_id) do
            {:ok, info} -> Process.alive?(info.pid)
            _ -> false
          end
        end)

      assert final_running_count == agent_count

      # Cleanup
      for agent_id <- agent_ids do
        HordeSupervisor.stop_agent(agent_id)
      end
    end

    test "reconciler status and metrics" do
      # Get initial reconciler status
      initial_status = AgentReconciler.get_status()
      assert is_map(initial_status)
      assert Map.has_key?(initial_status, :reconcile_count)

      initial_count = initial_status.reconcile_count

      # Force a reconciliation
      assert :ok = AgentReconciler.force_reconcile()

      # Check status updated
      new_status = AgentReconciler.get_status()
      assert new_status.reconcile_count > initial_count
      assert new_status.last_reconcile != nil
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

    # Clean up any remaining specs
    try do
      pattern = {{:agent_spec, :"$1"}, :"$2", :"$3"}
      guard = []
      body = [{{:"$1", :"$3"}}]

      specs = Horde.Registry.select(@registry_name, [{pattern, guard, body}])

      for {agent_id, _spec} <- specs do
        if is_binary(agent_id) and String.contains?(agent_id, "test-") do
          spec_key = {:agent_spec, agent_id}
          Horde.Registry.unregister(@registry_name, spec_key)
        end
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp get_agent_spec_from_registry(agent_id) do
    try do
      spec_key = {:agent_spec, agent_id}

      case Horde.Registry.lookup(@registry_name, spec_key) do
        [{_pid, spec_metadata}] -> {:ok, spec_metadata}
        [] -> {:error, :not_found}
      end
    rescue
      _ -> {:error, :not_found}
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  defp remove_agent_spec_from_registry(agent_id) do
    try do
      spec_key = {:agent_spec, agent_id}
      Horde.Registry.unregister(@registry_name, spec_key)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end
end

# Test agent modules

defmodule TestPersistentAgent do
  use GenServer

  alias Arbor.Core.HordeRegistry

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(args) do
    # Extract agent_id for self-registration
    agent_id = Keyword.get(args, :agent_id)
    agent_metadata = Keyword.get(args, :agent_metadata, %{})

    state = %{
      agent_id: agent_id,
      initial_data: Keyword.get(args, :initial_data),
      started_at: System.system_time(:millisecond)
    }

    # Self-register in HordeRegistry if agent_id is provided
    if agent_id do
      runtime_metadata = %{started_at: state.started_at}

      case HordeRegistry.register_agent_name(agent_id, self(), runtime_metadata) do
        {:ok, _} ->
          :ok

        error ->
          # Log but don't fail - the supervisor will handle this
          IO.puts("Agent registration failed: #{inspect(error)}")
      end
    end

    {:ok, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def terminate(_reason, state) do
    # Clean up registration
    if state.agent_id do
      HordeRegistry.unregister_agent_name(state.agent_id)
    end

    :ok
  end
end

defmodule TestMissingAgent do
  use GenServer

  alias Arbor.Core.HordeRegistry

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(args) do
    agent_id = Keyword.get(args, :agent_id)

    state = %{
      agent_id: agent_id,
      recovery_data: Keyword.get(args, :recovery_data),
      restart_count: 0,
      started_at: System.system_time(:millisecond)
    }

    # Self-register in HordeRegistry if agent_id is provided
    if agent_id do
      runtime_metadata = %{started_at: state.started_at}

      case HordeRegistry.register_agent_name(agent_id, self(), runtime_metadata) do
        {:ok, _} -> :ok
        error -> IO.puts("Agent registration failed: #{inspect(error)}")
      end
    end

    {:ok, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def terminate(_reason, state) do
    if state.agent_id do
      HordeRegistry.unregister_agent_name(state.agent_id)
    end

    :ok
  end
end

defmodule TestOrphanedAgent do
  use GenServer

  alias Arbor.Core.HordeRegistry

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(args) do
    agent_id = Keyword.get(args, :agent_id)

    state = %{
      agent_id: agent_id,
      orphaned: true,
      started_at: System.system_time(:millisecond)
    }

    if agent_id do
      runtime_metadata = %{started_at: state.started_at}

      case HordeRegistry.register_agent_name(agent_id, self(), runtime_metadata) do
        {:ok, _} -> :ok
        error -> IO.puts("Agent registration failed: #{inspect(error)}")
      end
    end

    {:ok, state}
  end

  def terminate(_reason, state) do
    if state.agent_id do
      HordeRegistry.unregister_agent_name(state.agent_id)
    end

    :ok
  end
end

defmodule TestRestartAgent do
  use GenServer

  alias Arbor.Core.HordeRegistry

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(args) do
    agent_id = Keyword.get(args, :agent_id)

    state = %{
      agent_id: agent_id,
      strategy: Keyword.get(args, :strategy),
      started_at: System.system_time(:millisecond)
    }

    if agent_id do
      runtime_metadata = %{started_at: state.started_at}

      case HordeRegistry.register_agent_name(agent_id, self(), runtime_metadata) do
        {:ok, _} -> :ok
        error -> IO.puts("Agent registration failed: #{inspect(error)}")
      end
    end

    {:ok, state}
  end

  def terminate(_reason, state) do
    if state.agent_id do
      HordeRegistry.unregister_agent_name(state.agent_id)
    end

    :ok
  end
end

defmodule TestSelfRegisterAgent do
  use GenServer

  alias Arbor.Core.HordeRegistry

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(args) do
    agent_id = Keyword.get(args, :agent_id)

    state = %{
      agent_id: agent_id,
      self_registered: true,
      registration_time: System.system_time(:millisecond)
    }

    if agent_id do
      runtime_metadata = %{started_at: state.registration_time, self_registered: true}

      case HordeRegistry.register_agent_name(agent_id, self(), runtime_metadata) do
        {:ok, _} -> :ok
        error -> IO.puts("Agent registration failed: #{inspect(error)}")
      end
    end

    {:ok, state}
  end

  def handle_call(:get_registration_info, _from, state) do
    {:reply, state, state}
  end

  def terminate(_reason, state) do
    if state.agent_id do
      HordeRegistry.unregister_agent_name(state.agent_id)
    end

    :ok
  end
end

defmodule TestCleanupAgent do
  use GenServer

  alias Arbor.Core.HordeRegistry

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(args) do
    agent_id = Keyword.get(args, :agent_id)

    state = %{
      agent_id: agent_id,
      cleanup_on_exit: true,
      started_at: System.system_time(:millisecond)
    }

    if agent_id do
      runtime_metadata = %{started_at: state.started_at}

      case HordeRegistry.register_agent_name(agent_id, self(), runtime_metadata) do
        {:ok, _} -> :ok
        error -> IO.puts("Agent registration failed: #{inspect(error)}")
      end
    end

    {:ok, state}
  end

  def terminate(_reason, state) do
    # Cleanup registration
    if state.agent_id do
      HordeRegistry.unregister_agent_name(state.agent_id)
    end

    :ok
  end
end

defmodule TestFailoverAgent do
  use GenServer

  alias Arbor.Core.HordeRegistry

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(args) do
    agent_id = Keyword.get(args, :agent_id)

    state = %{
      agent_id: agent_id,
      failover_test: Keyword.get(args, :failover_test, false),
      internal_state: %{},
      started_at: System.system_time(:millisecond)
    }

    if agent_id do
      runtime_metadata = %{started_at: state.started_at}

      case HordeRegistry.register_agent_name(agent_id, self(), runtime_metadata) do
        {:ok, _} -> :ok
        error -> IO.puts("Agent registration failed: #{inspect(error)}")
      end
    end

    {:ok, state}
  end

  def handle_call({:store_state, data}, _from, state) do
    new_state = %{state | internal_state: data}
    {:reply, :ok, new_state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def terminate(_reason, state) do
    if state.agent_id do
      HordeRegistry.unregister_agent_name(state.agent_id)
    end

    :ok
  end
end

defmodule TestScaleAgent do
  use GenServer

  alias Arbor.Core.HordeRegistry

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(args) do
    agent_id = Keyword.get(args, :agent_id)

    state = %{
      agent_id: agent_id,
      index: Keyword.get(args, :index),
      started_at: System.system_time(:millisecond)
    }

    if agent_id do
      runtime_metadata = %{started_at: state.started_at}

      case HordeRegistry.register_agent_name(agent_id, self(), runtime_metadata) do
        {:ok, _} -> :ok
        error -> IO.puts("Agent registration failed: #{inspect(error)}")
      end
    end

    {:ok, state}
  end

  def terminate(_reason, state) do
    if state.agent_id do
      HordeRegistry.unregister_agent_name(state.agent_id)
    end

    :ok
  end
end
