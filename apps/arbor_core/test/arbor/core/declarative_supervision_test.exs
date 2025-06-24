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

  alias Arbor.Core.{HordeSupervisor, AgentReconciler}
  alias Arbor.Test.Support.AsyncHelpers

  @moduletag :integration
  @moduletag :cluster
  @moduletag timeout: 60_000

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

    # Wait for cleanup to complete using exponential backoff
    AsyncHelpers.wait_until(
      fn ->
        # Check if cleanup is complete by verifying no test agents remain
        case get_all_test_agent_specs() do
          [] -> true
          _ -> false
        end
      end,
      timeout: 3000,
      initial_delay: 50
    )

    # Force reconciliation to ensure clean state
    AgentReconciler.force_reconcile()

    # Wait for reconciliation to complete
    AsyncHelpers.wait_until(
      fn ->
        # Simple check - reconciler should be responsive
        Process.alive?(Process.whereis(AgentReconciler))
      end,
      timeout: 1000,
      initial_delay: 25
    )

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

      # Wait for agent to complete asynchronous registration
      info = AsyncHelpers.wait_for_agent_ready(agent_id)
      assert info.pid == original_pid

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
      Horde.DynamicSupervisor.terminate_child(Arbor.Core.HordeAgentSupervisor, agent_info.pid)

      # Wait for Horde to detect failure and restart using exponential backoff
      AsyncHelpers.wait_until(
        fn ->
          case HordeSupervisor.get_agent_info(agent_id) do
            # New process restarted
            {:ok, info} when info.pid != original_pid -> true
            _ -> false
          end
        end,
        timeout: 5000,
        initial_delay: 100
      )

      # Force reconciliation to ensure consistency
      AgentReconciler.force_reconcile()

      # Wait for reconciliation to stabilize
      AsyncHelpers.wait_until(
        fn ->
          case HordeSupervisor.get_agent_info(agent_id) do
            {:ok, _info} -> true
            _ -> false
          end
        end,
        timeout: 3000,
        initial_delay: 50
      )

      # Verify agent was restarted - may need a few attempts due to timing
      assert_eventually(
        fn ->
          case HordeSupervisor.get_agent_info(agent_id) do
            {:ok, new_agent_info} when new_agent_info.pid != original_pid ->
              {:ok, new_agent_info}

            _ ->
              # Force another reconciliation if needed
              AgentReconciler.force_reconcile()
              # Use smaller delay for retry pattern
              AsyncHelpers.wait_until(fn -> true end, timeout: 250, initial_delay: 50)
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

      # Wait for agent to complete asynchronous registration
      AsyncHelpers.wait_for_agent_ready(agent_id, timeout: 2000)

      # Verify agent is registered
      assert {:ok, agent_info} = HordeSupervisor.get_agent_info(agent_id)
      assert agent_info.pid == original_pid

      # Manually kill the agent process (simulating crash)
      Horde.DynamicSupervisor.terminate_child(Arbor.Core.HordeAgentSupervisor, original_pid)

      # Wait for process to die using exponential backoff
      AsyncHelpers.wait_until(
        fn ->
          not Process.alive?(original_pid)
        end,
        timeout: 2000,
        initial_delay: 25
      )

      refute Process.alive?(original_pid)

      # Force reconciliation and wait for restart
      assert_eventually(
        fn ->
          AgentReconciler.force_reconcile()

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

      # Wait for orphaned process to be cleaned up
      AsyncHelpers.wait_until(fn -> not Process.alive?(agent_pid) end, timeout: 2000)
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
      Horde.DynamicSupervisor.terminate_child(Arbor.Core.HordeAgentSupervisor, permanent_pid)
      Horde.DynamicSupervisor.terminate_child(Arbor.Core.HordeAgentSupervisor, temporary_pid)

      # Wait for processes to terminate
      AsyncHelpers.wait_until(fn ->
        not Process.alive?(permanent_pid) and not Process.alive?(temporary_pid)
      end)

      # Force reconciliation and wait for restart
      assert_eventually(
        fn ->
          AgentReconciler.force_reconcile()

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

      # Wait for agent to complete self-registration
      agent_info = AsyncHelpers.wait_for_agent_ready(agent_id)
      assert agent_info.pid == agent_pid

      # Debug: Check both spec and runtime lookups
      IO.puts("=== Debug get_agent_info for #{agent_id} ===")
      spec_result = HordeSupervisor.lookup_agent_spec(agent_id)
      IO.puts("Spec lookup: #{inspect(spec_result)}")
      runtime_result = Arbor.Core.HordeRegistry.lookup_agent_name(agent_id)
      IO.puts("Runtime lookup: #{inspect(runtime_result)}")

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

      # Wait for agent registration and verify
      agent_info = AsyncHelpers.wait_for_agent_ready(agent_id)
      assert agent_info.pid == agent_pid

      # Stop agent normally
      GenServer.stop(agent_pid, :normal)

      # Wait for agent to stop and verify cleanup
      AsyncHelpers.wait_for_agent_stopped(agent_id)

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
          # Wait for spec to be cleaned up
          AsyncHelpers.wait_until(fn ->
            case get_agent_spec_from_registry(agent_id) do
              {:error, :not_found} -> true
              _ -> false
            end
          end)

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

      # Allow time for agent to complete asynchronous registration
      # Wait for agent to be ready
      AsyncHelpers.wait_for_agent_ready(agent_id)

      # Store some state in the agent
      :ok = GenServer.call(original_pid, {:store_state, %{test_data: "failover_test"}})

      # Simulate node failure by killing the process abruptly
      Horde.DynamicSupervisor.terminate_child(Arbor.Core.HordeAgentSupervisor, original_pid)

      # Wait for process to die
      AsyncHelpers.wait_until(fn -> not Process.alive?(original_pid) end)
      refute Process.alive?(original_pid)

      # Use reconciler to detect and restart the missing agent
      assert_eventually(
        fn ->
          AgentReconciler.force_reconcile()

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

      # Wait for all agents to start and verify they are running
      assert_eventually(
        fn ->
          running_count =
            Enum.count(agent_ids, fn agent_id ->
              case HordeSupervisor.get_agent_info(agent_id) do
                {:ok, info} when is_pid(info.pid) -> Process.alive?(info.pid)
                _ -> false
              end
            end)

          if running_count == agent_count, do: :ok, else: :retry
        end,
        "All agents should be running after initial start"
      )

      # Kill half the agents randomly
      killed_agents = Enum.take_random(agent_ids, div(agent_count, 2))

      killed_pids =
        for agent_id <- killed_agents do
          {:ok, info} = HordeSupervisor.get_agent_info(agent_id)
          Horde.DynamicSupervisor.terminate_child(Arbor.Core.HordeAgentSupervisor, info.pid)
          info.pid
        end

      # Wait for all processes to terminate
      AsyncHelpers.wait_until(fn ->
        Enum.all?(killed_pids, fn pid -> not Process.alive?(pid) end)
      end)

      # Force reconciliation and wait for all agents to be restarted
      assert_eventually(
        fn ->
          AgentReconciler.force_reconcile()

          final_running_count =
            Enum.count(agent_ids, fn agent_id ->
              case HordeSupervisor.get_agent_info(agent_id) do
                {:ok, info} when is_pid(info.pid) -> Process.alive?(info.pid)
                _ -> false
              end
            end)

          if final_running_count == agent_count do
            :ok
          else
            :retry
          end
        end,
        "All agents should be running again after reconciliation"
      )

      # Final verification to be sure
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
    AsyncHelpers.assert_eventually(fun, message, max_attempts: max_attempts)
  end

  defp ensure_horde_infrastructure do
    # Start Phoenix.PubSub if not running
    case GenServer.whereis(Arbor.Core.PubSub) do
      nil ->
        {:ok, _} = start_supervised({Phoenix.PubSub, name: Arbor.Core.PubSub})

      _pid ->
        :ok
    end

    # Start HordeSupervisor infrastructure if not running
    if Process.whereis(Arbor.Core.HordeSupervisorSupervisor) == nil do
      HordeSupervisor.start_supervisor()
    end

    Horde.Cluster.set_members(@registry_name, [{@registry_name, node()}])
    Horde.Cluster.set_members(@supervisor_name, [{@supervisor_name, node()}])

    # Wait for Horde components to stabilize
    wait_for_membership_ready()

    # Verify infrastructure is ready
    pubsub_ready = GenServer.whereis(Arbor.Core.PubSub) != nil
    registry_ready = GenServer.whereis(@registry_name) != nil
    supervisor_ready = GenServer.whereis(@supervisor_name) != nil
    horde_supervisor_ready = Process.whereis(Arbor.Core.HordeSupervisorSupervisor) != nil

    unless pubsub_ready and registry_ready and supervisor_ready and horde_supervisor_ready do
      raise "Horde infrastructure failed to start properly"
    end

    :ok
  end

  defp wait_for_membership_ready(timeout \\ 5000) do
    IO.puts("  -> Waiting for Horde membership to be ready...")

    check_fun = fn ->
      registry_members = Horde.Cluster.members(@registry_name)
      supervisor_members = Horde.Cluster.members(@supervisor_name)
      current_node = node()

      # Check for proper named members in various formats that Horde can return
      # Handle keyword list format: [arbor_test@localhost: :arbor_test@localhost]
      registry_ready =
        Enum.any?(registry_members, fn
          {@registry_name, node} when node == current_node -> true
          {node, node} when node == current_node -> true
          member when is_atom(member) and member == current_node -> true
          _ -> false
        end) or
          (is_list(registry_members) and
             Keyword.get(registry_members, current_node) == current_node)

      supervisor_ready =
        Enum.any?(supervisor_members, fn
          {@supervisor_name, node} when node == current_node -> true
          {node, node} when node == current_node -> true
          member when is_atom(member) and member == current_node -> true
          _ -> false
        end)

      if registry_ready and supervisor_ready do
        IO.puts("  -> Horde membership is ready.")
        IO.puts("     Registry: #{inspect(registry_members)}")
        IO.puts("     Supervisor: #{inspect(supervisor_members)}")
        true
      else
        IO.puts("  -> Still waiting for membership...")
        IO.puts("     Registry: #{inspect(registry_members)} (ready: #{registry_ready})")
        IO.puts("     Supervisor: #{inspect(supervisor_members)} (ready: #{supervisor_ready})")
        false
      end
    end

    case AsyncHelpers.wait_until(check_fun, timeout: timeout, initial_delay: 50) do
      true ->
        # Additional stabilization wait for distributed supervisor CRDT sync
        # Wait for supervisor to have empty children list after membership sync
        AsyncHelpers.wait_until(
          fn ->
            case Horde.DynamicSupervisor.which_children(@supervisor_name) do
              [] ->
                true

              children ->
                # Only accept if no children exist
                Enum.empty?(children)
            end
          end,
          timeout: 1000,
          initial_delay: 50
        )

        :ok

      _ ->
        registry_members = Horde.Cluster.members(@registry_name)
        supervisor_members = Horde.Cluster.members(@supervisor_name)

        raise """
        Timed out waiting for Horde membership synchronization.
        - Current Node: #{inspect(node())}
        - Registry Members: #{inspect(registry_members)}
        - Supervisor Members: #{inspect(supervisor_members)}
        """
    end
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

  defp get_all_test_agent_specs do
    try do
      pattern = {{:agent_spec, :"$1"}, :"$2", :"$3"}
      guard = []
      body = [:"$1"]

      specs = Horde.Registry.select(@registry_name, [{pattern, guard, body}])

      Enum.filter(specs, fn agent_id ->
        is_binary(agent_id) and String.contains?(agent_id, "test-")
      end)
    rescue
      _ -> []
    catch
      :exit, _ -> []
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

    # Use continue for registration to avoid blocking init
    {:ok, state, {:continue, :register_with_supervisor}}
  end

  @impl GenServer
  def handle_continue(:register_with_supervisor, state) do
    # Self-register in HordeRegistry if agent_id is provided
    if state.agent_id do
      runtime_metadata = %{started_at: state.started_at}

      case HordeRegistry.register_agent_name(state.agent_id, self(), runtime_metadata) do
        {:ok, _} ->
          :ok

        error ->
          # Log but don't fail - the supervisor will handle this
          IO.puts("Agent registration failed: #{inspect(error)}")
      end
    end

    {:noreply, state}
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

    {:ok, state, {:continue, :register_with_supervisor}}
  end

  @impl GenServer
  def handle_continue(:register_with_supervisor, state) do
    # Self-register in HordeRegistry if agent_id is provided
    if state.agent_id do
      runtime_metadata = %{started_at: state.started_at}

      case HordeRegistry.register_agent_name(state.agent_id, self(), runtime_metadata) do
        {:ok, _} -> :ok
        error -> IO.puts("Agent registration failed: #{inspect(error)}")
      end
    end

    {:noreply, state}
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

    {:ok, state, {:continue, :register_with_supervisor}}
  end

  @impl GenServer
  def handle_continue(:register_with_supervisor, state) do
    if state.agent_id do
      runtime_metadata = %{started_at: state.started_at}

      case HordeRegistry.register_agent_name(state.agent_id, self(), runtime_metadata) do
        {:ok, _} -> :ok
        error -> IO.puts("Agent registration failed: #{inspect(error)}")
      end
    end

    {:noreply, state}
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

    {:ok, state, {:continue, :register_with_supervisor}}
  end

  @impl GenServer
  def handle_continue(:register_with_supervisor, state) do
    if state.agent_id do
      runtime_metadata = %{started_at: state.started_at}

      case HordeRegistry.register_agent_name(state.agent_id, self(), runtime_metadata) do
        {:ok, _} -> :ok
        error -> IO.puts("Agent registration failed: #{inspect(error)}")
      end
    end

    {:noreply, state}
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

    {:ok, state, {:continue, :register_with_supervisor}}
  end

  @impl GenServer
  def handle_continue(:register_with_supervisor, state) do
    IO.puts("TestSelfRegisterAgent registering: agent_id=#{inspect(state.agent_id)}")

    if state.agent_id do
      runtime_metadata = %{started_at: state.registration_time, self_registered: true}

      result = HordeRegistry.register_agent_name(state.agent_id, self(), runtime_metadata)

      IO.puts(
        "TestSelfRegisterAgent registration result for #{state.agent_id}: #{inspect(result)}"
      )

      # Also test direct Horde.Registry.lookup with different key formats
      direct_lookup1 = Horde.Registry.lookup(Arbor.Core.HordeAgentRegistry, state.agent_id)
      IO.puts("Direct Horde.Registry.lookup (agent_id): #{inspect(direct_lookup1)}")

      direct_lookup2 =
        Horde.Registry.lookup(Arbor.Core.HordeAgentRegistry, {:agent, state.agent_id})

      IO.puts("Direct Horde.Registry.lookup ({:agent, agent_id}): #{inspect(direct_lookup2)}")

      # Let's try a raw register to see what happens
      raw_register =
        Horde.Registry.register(
          Arbor.Core.HordeAgentRegistry,
          "test-raw-#{state.agent_id}",
          {self(), runtime_metadata}
        )

      IO.puts("Raw Horde.Registry.register result: #{inspect(raw_register)}")

      # Note: CRDT sync happens asynchronously - tests should wait for expected conditions

      raw_lookup =
        Horde.Registry.lookup(Arbor.Core.HordeAgentRegistry, "test-raw-#{state.agent_id}")

      IO.puts("Raw Horde.Registry.lookup result after sync wait: #{inspect(raw_lookup)}")

      # Also check if registry is actually the same instance
      registry_pid = GenServer.whereis(Arbor.Core.HordeAgentRegistry)
      IO.puts("HordeAgentRegistry PID: #{inspect(registry_pid)}")

      # Check which children are actually registered
      all_entries =
        try do
          Horde.Registry.select(Arbor.Core.HordeAgentRegistry, [
            {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
          ])
        rescue
          e -> {:error, e}
        end

      IO.puts("All registry entries (key, pid, value): #{inspect(all_entries)}")

      # Check specifically for our agent ID
      specific_lookup =
        try do
          Horde.Registry.select(Arbor.Core.HordeAgentRegistry, [
            {{state.agent_id, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}
          ])
        rescue
          e -> {:error, e}
        end

      IO.puts("Specific agent entries for #{state.agent_id}: #{inspect(specific_lookup)}")

      # Also try manual lookup with our exact key
      manual_lookup =
        try do
          GenServer.call(Arbor.Core.HordeAgentRegistry, {:lookup, state.agent_id})
        rescue
          e -> {:error, e}
        end

      IO.puts("Manual GenServer lookup: #{inspect(manual_lookup)}")

      case result do
        {:ok, _} ->
          IO.puts("TestSelfRegisterAgent registration SUCCESS for #{state.agent_id}")
          :ok

        error ->
          IO.puts(
            "TestSelfRegisterAgent registration FAILED for #{state.agent_id}: #{inspect(error)}"
          )
      end
    else
      IO.puts("TestSelfRegisterAgent: No agent_id provided!")
    end

    {:noreply, state}
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

    {:ok, state, {:continue, :register_with_supervisor}}
  end

  @impl GenServer
  def handle_continue(:register_with_supervisor, state) do
    if state.agent_id do
      runtime_metadata = %{started_at: state.started_at}

      case HordeRegistry.register_agent_name(state.agent_id, self(), runtime_metadata) do
        {:ok, _} -> :ok
        error -> IO.puts("Agent registration failed: #{inspect(error)}")
      end
    end

    {:noreply, state}
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

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @spec init(keyword()) :: {:ok, map()}
  def init(args) do
    agent_id = Keyword.get(args, :agent_id)

    state = %{
      agent_id: agent_id,
      failover_test: Keyword.get(args, :failover_test, false),
      internal_state: %{},
      started_at: System.system_time(:millisecond)
    }

    {:ok, state, {:continue, :register_with_supervisor}}
  end

  @impl GenServer
  def handle_continue(:register_with_supervisor, state) do
    if state.agent_id do
      runtime_metadata = %{started_at: state.started_at}

      case HordeRegistry.register_agent_name(state.agent_id, self(), runtime_metadata) do
        {:ok, _} -> :ok
        error -> IO.puts("Agent registration failed: #{inspect(error)}")
      end
    end

    {:noreply, state}
  end

  @spec handle_call({:store_state, any()}, GenServer.from(), map()) :: {:reply, :ok, map()}
  def handle_call({:store_state, data}, _from, state) do
    new_state = %{state | internal_state: data}
    {:reply, :ok, new_state}
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

    {:ok, state, {:continue, :register_with_supervisor}}
  end

  @impl GenServer
  def handle_continue(:register_with_supervisor, state) do
    if state.agent_id do
      runtime_metadata = %{started_at: state.started_at}

      case HordeRegistry.register_agent_name(state.agent_id, self(), runtime_metadata) do
        {:ok, _} -> :ok
        error -> IO.puts("Agent registration failed: #{inspect(error)}")
      end
    end

    {:noreply, state}
  end

  def terminate(_reason, state) do
    if state.agent_id do
      HordeRegistry.unregister_agent_name(state.agent_id)
    end

    :ok
  end
end
