defmodule Arbor.Core.BasicSupervisionTest do
  @moduledoc """
  Basic tests for the declarative supervision architecture.
  Tests fundamental behaviors without complex multi-node scenarios.
  """

  use ExUnit.Case, async: false

  alias Arbor.Core.{AgentReconciler, HordeRegistry, HordeSupervisor}

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
      :timer.sleep(200)

      # Check what's in the registry before starting
      case HordeRegistry.lookup_agent_name(agent_id) do
        {:ok, existing_pid, _} ->
          IO.puts("Warning: Agent #{agent_id} still registered with PID #{inspect(existing_pid)}")
          # Force unregister
          HordeRegistry.unregister_agent_name(agent_id)
          :timer.sleep(100)

        {:error, :not_registered} ->
          :ok
      end

      assert {:ok, pid} = HordeSupervisor.start_agent(agent_spec)

      # Kill the process
      Process.exit(pid, :kill)

      # Force immediate reconciliation since Horde uses :temporary restart
      # and the AgentReconciler handles restart logic
      :ok = AgentReconciler.force_reconcile()

      # Wait a bit for reconciliation to complete
      :timer.sleep(500)

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
      :timer.sleep(100)

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

      # Kill the process
      Process.exit(pid, :kill)

      # Wait a bit
      :timer.sleep(1000)

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
    # Poll for registration to handle async registration logic
    Enum.find_value(0..div(timeout, 50), fn _ ->
      case HordeRegistry.lookup_agent_name(agent_id) do
        {:ok, _, _} = result ->
          result

        _ ->
          Process.sleep(50)
          nil
      end
    end) || {:error, :timeout}
  end

  @spec ensure_horde_infrastructure() :: :ok
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

    # Start Arbor.Core.HordeSupervisor if not running
    case GenServer.whereis(HordeSupervisor) do
      nil ->
        {:ok, _} = start_supervised({HordeSupervisor, []})

      _pid ->
        :ok
    end

    # Wait for Horde components to stabilize
    :timer.sleep(500)
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
