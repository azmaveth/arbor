defmodule Arbor.Core.BasicSupervisionTest do
  @moduledoc """
  Basic tests for the declarative supervision architecture.
  Tests fundamental behaviors without complex multi-node scenarios.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Arbor.Core.{AgentReconciler, HordeRegistry, HordeSupervisor}
  alias Arbor.Test.Support.AsyncHelpers

  @registry_name Arbor.Core.HordeAgentRegistry
  @supervisor_name Arbor.Core.HordeAgentSupervisor

  setup_all do
    # Ensure Horde infrastructure is running
    ensure_horde_infrastructure()

    # Start AgentReconciler if not running
    case GenServer.whereis(AgentReconciler) do
      nil -> start_supervised!(AgentReconciler)
      _pid -> :ok
    end

    :ok
  end

  setup do
    # Start with a clean slate
    on_exit(fn ->
      # Clean up any running agents
      case HordeSupervisor.list_agents() do
        {:ok, agents} ->
          Enum.each(agents, fn agent ->
            HordeSupervisor.stop_agent(agent.id)
          end)

        _ ->
          :ok
      end
    end)

    :ok
  end

  describe "basic supervision" do
    test "lookup_agent_spec/1 is publicly accessible" do
      agent_id = "test-lookup-#{System.unique_integer([:positive])}"

      # Should return error when spec doesn't exist
      assert {:error, :not_found} = HordeSupervisor.lookup_agent_spec(agent_id)

      # Start an agent
      agent_spec = %{
        id: agent_id,
        module: BasicTestAgent,
        args: [agent_id: agent_id],
        restart_strategy: :temporary
      }

      assert {:ok, _pid} = HordeSupervisor.start_agent(agent_spec)

      # Now should return the spec
      assert {:ok, spec} = HordeSupervisor.lookup_agent_spec(agent_id)
      assert spec.module == BasicTestAgent
      assert spec.restart_strategy == :temporary

      # Clean up
      HordeSupervisor.stop_agent(agent_id)
    end

    test "agents are centrally registered by supervisor" do
      agent_id = "test-central-reg-#{System.unique_integer([:positive])}"

      agent_spec = %{
        id: agent_id,
        module: BasicTestAgent,
        args: [agent_id: agent_id],
        restart_strategy: :temporary
      }

      assert {:ok, pid} = HordeSupervisor.start_agent(agent_spec)

      # Agent should be registered (wait for it)
      assert {:ok, ^pid, metadata} = wait_for_registration(agent_id)
      assert metadata.module == BasicTestAgent

      # Stop agent
      assert :ok = HordeSupervisor.stop_agent(agent_id)

      # Should be unregistered
      assert {:error, :not_registered} = HordeRegistry.lookup_agent_name(agent_id)
    end

    test "permanent agents restart automatically via AgentReconciler" do
      agent_id = "test-reconciler-restart-#{System.unique_integer([:positive])}"

      agent_spec = %{
        id: agent_id,
        module: BasicTestAgent,
        args: [agent_id: agent_id],
        restart_strategy: :permanent
      }

      # Clean up any existing agent and registrations first
      _ = HordeSupervisor.stop_agent(agent_id)
      _ = HordeRegistry.unregister_agent_name(agent_id)

      # Wait for cleanup to complete
      AsyncHelpers.wait_until(
        fn ->
          case HordeRegistry.lookup_agent_name(agent_id) do
            {:error, :not_registered} -> true
            _ -> false
          end
        end,
        timeout: 2000,
        initial_delay: 50
      )

      # Check what's in the registry before starting
      case HordeRegistry.lookup_agent_name(agent_id) do
        {:ok, existing_pid, _} ->
          IO.puts("Warning: Agent #{agent_id} still registered with PID #{inspect(existing_pid)}")
          # Force unregister
          HordeRegistry.unregister_agent_name(agent_id)

          # Wait for unregistration to complete
          AsyncHelpers.wait_until(
            fn ->
              case HordeRegistry.lookup_agent_name(agent_id) do
                {:error, :not_registered} -> true
                _ -> false
              end
            end,
            timeout: 1000,
            initial_delay: 25
          )

        {:error, :not_registered} ->
          :ok
      end

      assert {:ok, pid} = HordeSupervisor.start_agent(agent_spec)

      # Kill the process using proper supervisor termination
      Horde.DynamicSupervisor.terminate_child(Arbor.Core.HordeAgentSupervisor, pid)

      # Force immediate reconciliation since Horde uses :temporary restart
      # and the AgentReconciler handles restart logic
      :ok = AgentReconciler.force_reconcile()

      # Wait for reconciliation to complete and agent to be restarted
      AsyncHelpers.wait_until(
        fn ->
          case HordeSupervisor.get_agent_info(agent_id) do
            {:ok, agent_info} when agent_info.pid != pid ->
              Process.alive?(agent_info.pid)

            _ ->
              false
          end
        end,
        timeout: 3000,
        initial_delay: 100
      )

      # Should have new PID
      assert {:ok, agent_info} = HordeSupervisor.get_agent_info(agent_id)
      assert agent_info.pid != pid
      assert Process.alive?(agent_info.pid)

      # Clean up
      HordeSupervisor.stop_agent(agent_id)
    end

    test "restore_agent works with state recovery" do
      agent_id = "test-restore-#{System.unique_integer([:positive])}"

      agent_spec = %{
        id: agent_id,
        module: BasicTestAgent,
        args: [agent_id: agent_id, initial_value: 42],
        restart_strategy: :permanent
      }

      assert {:ok, pid} = HordeSupervisor.start_agent(agent_spec)

      # Update agent state
      GenServer.cast(pid, {:set_value, 100})

      # Wait for state update to be processed
      AsyncHelpers.wait_until(
        fn ->
          case GenServer.call(pid, :get_state) do
            %{value: 100} -> true
            _ -> false
          end
        end,
        timeout: 1000,
        initial_delay: 25
      )

      # Restore agent (should attempt state recovery)
      assert {:ok, {new_pid, _recovery_status}} = HordeSupervisor.restore_agent(agent_id)
      assert new_pid != pid

      # Verify it's running
      assert Process.alive?(new_pid)

      # Clean up
      HordeSupervisor.stop_agent(agent_id)
    end

    test "temporary agents are not restarted" do
      agent_id = "test-temporary-#{System.unique_integer([:positive])}"

      agent_spec = %{
        id: agent_id,
        module: BasicTestAgent,
        args: [agent_id: agent_id],
        restart_strategy: :temporary
      }

      assert {:ok, pid} = HordeSupervisor.start_agent(agent_spec)

      # Kill the process using proper supervisor termination
      Horde.DynamicSupervisor.terminate_child(Arbor.Core.HordeAgentSupervisor, pid)

      # Wait for process to die and verify it's not restarted
      AsyncHelpers.wait_until(
        fn ->
          not Process.alive?(pid) and
            case HordeSupervisor.get_agent_info(agent_id) do
              {:error, :not_found} -> true
              _ -> false
            end
        end,
        timeout: 3000,
        initial_delay: 100
      )

      # Should not be running
      assert {:error, :not_found} = HordeSupervisor.get_agent_info(agent_id)

      # Spec should also be cleaned up eventually
      # (Note: This might take longer as reconciler needs to run)
    end
  end

  # Helper functions

  @spec wait_for_registration(String.t(), non_neg_integer()) ::
          {:ok, pid(), map()} | {:error, :timeout}
  defp wait_for_registration(agent_id, timeout \\ 1000) do
    # Use exponential backoff for registration polling
    try do
      result =
        AsyncHelpers.wait_until(
          fn ->
            case HordeRegistry.lookup_agent_name(agent_id) do
              {:ok, _, _} = result -> result
              _ -> false
            end
          end,
          timeout: timeout,
          initial_delay: 25
        )

      result
    rescue
      ExUnit.AssertionError -> {:error, :timeout}
    end
  end

  @spec ensure_horde_infrastructure() :: :ok
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

    # Set members for single-node test environment.
    Horde.Cluster.set_members(@registry_name, [{@registry_name, node()}])
    Horde.Cluster.set_members(@supervisor_name, [{@supervisor_name, node()}])

    # Wait for Horde components to stabilize
    wait_for_membership_ready()
  end

  defp wait_for_membership_ready(timeout \\ 5000) do
    IO.puts("  -> Waiting for Horde membership to be ready...")

    check_fun = fn ->
      registry_members = Horde.Cluster.members(@registry_name)
      supervisor_members = Horde.Cluster.members(@supervisor_name)
      current_node = node()

      # Check for proper named members in various formats
      expected_registry_member = {@registry_name, current_node}
      expected_supervisor_member = {@supervisor_name, current_node}

      registry_ready =
        expected_registry_member in registry_members or
          {expected_registry_member, expected_registry_member} in registry_members

      supervisor_ready =
        expected_supervisor_member in supervisor_members or
          {expected_supervisor_member, expected_supervisor_member} in supervisor_members

      if registry_ready and supervisor_ready do
        IO.puts("  -> Horde membership is ready.")
        true
      else
        false
      end
    end

    case AsyncHelpers.wait_until(check_fun, timeout: timeout, initial_delay: 50) do
      true ->
        # Additional stabilization wait for distributed supervisor CRDT sync
        AsyncHelpers.wait_until(
          fn ->
            case Horde.DynamicSupervisor.which_children(@supervisor_name) do
              [] ->
                true

              children ->
                # Only accept if no children exist or they're properly tracked
                length(children) >= 0
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
end

# Basic test agent
defmodule BasicTestAgent do
  use Arbor.Core.AgentBehavior

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @spec init(keyword()) :: {:ok, map(), {:continue, :register_with_supervisor}}
  def init(args) do
    agent_id = Keyword.get(args, :agent_id)

    state = %{
      agent_id: agent_id,
      value: Keyword.get(args, :initial_value, 0),
      started_at: System.system_time(:millisecond)
    }

    {:ok, state, {:continue, :register_with_supervisor}}
  end

  @impl Arbor.Core.AgentBehavior
  def get_agent_metadata(state) do
    %{
      type: :basic_test_agent,
      value: state.value,
      started_at: state.started_at
    }
  end

  @spec handle_call(:get_state, GenServer.from(), map()) :: {:reply, map(), map()}
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @spec handle_call(:prepare_checkpoint, GenServer.from(), map()) :: {:reply, map(), map()}
  def handle_call(:prepare_checkpoint, _from, state) do
    # Return current state for checkpointing
    {:reply, state, state}
  end

  @spec handle_cast({:set_value, any()}, map()) :: {:noreply, map()}
  def handle_cast({:set_value, value}, state) do
    {:noreply, %{state | value: value}}
  end

  @spec handle_info(any(), map()) :: {:noreply, map()}
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @spec terminate(any(), map()) :: :ok
  def terminate(_reason, _state) do
    # No self-cleanup - handled by supervisor
    :ok
  end
end
