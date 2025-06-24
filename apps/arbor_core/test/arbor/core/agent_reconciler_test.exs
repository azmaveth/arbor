defmodule Arbor.Core.AgentReconcilerTest do
  use ExUnit.Case, async: false

  alias Arbor.Core.AgentReconciler
  alias Arbor.Core.HordeSupervisor
  alias Arbor.Test.Support.AsyncHelpers

  @moduletag :integration
  @moduletag timeout: 30_000

  setup do
    # This setup is similar to HordeSupervisorTest, as the reconciler
    # depends on the same Horde infrastructure.
    Application.put_env(:arbor_core, :registry_impl, :horde)
    Application.put_env(:arbor_core, :supervisor_impl, :horde)
    # speed up for test
    Application.put_env(:arbor_core, :reconciliation_interval, 100)

    # Start Horde components
    start_supervised(
      {Horde.Registry, name: Arbor.Core.HordeAgentRegistry, keys: :unique, members: :auto}
    )

    start_supervised(
      {Horde.Registry, name: Arbor.Core.AgentSpecRegistry, keys: :unique, members: :auto}
    )

    start_supervised(
      {Horde.DynamicSupervisor,
       name: Arbor.Core.HordeAgentSupervisor, strategy: :one_for_one, members: :auto}
    )

    start_supervised({HordeSupervisor, []})
    start_supervised({AgentReconciler, []})

    # Wait for Horde components to synchronize
    AsyncHelpers.wait_until(
      fn ->
        # Verify all required processes are running
        horde_supervisor_running = Process.whereis(HordeSupervisor) != nil
        reconciler_running = Process.whereis(AgentReconciler) != nil
        registry_running = Process.whereis(Arbor.Core.HordeAgentRegistry) != nil

        horde_supervisor_running and reconciler_running and registry_running
      end,
      timeout: 1000,
      initial_delay: 50
    )

    on_exit(fn ->
      Application.delete_env(:arbor_core, :reconciliation_interval)
    end)

    :ok
  end

  describe "agent reconciliation" do
    @tag :reconciliation
    test "restarts an agent that has a spec but is not running" do
      agent_id = "reconciler-test-#{System.unique_integer([:positive])}"

      agent_spec = %{
        id: agent_id,
        module: Arbor.Test.Mocks.TestAgent,
        args: [],
        restart_strategy: :permanent
      }

      # 1. Manually create a spec, simulating a persisted spec for an agent
      #    that is not currently running. We use HordeSupervisor to do this,
      #    but then we'll kill the process directly to simulate failure (leaving spec intact).
      {:ok, pid} = HordeSupervisor.start_agent(agent_spec)
      # Terminate only the process but leave the spec (simulate crash/failure)
      # Also clean up registry entry so reconciler sees agent as not running
      Arbor.Core.HordeRegistry.unregister_agent_name(agent_id)
      Horde.DynamicSupervisor.terminate_child(Arbor.Core.HordeAgentSupervisor, pid)

      # Wait for process to actually stop
      AsyncHelpers.wait_until(
        fn ->
          not Process.alive?(pid)
        end,
        timeout: 1000,
        initial_delay: 25
      )

      # Verify it's not running
      assert {:error, :not_found} = HordeSupervisor.get_agent_info(agent_id)

      # 2. Force the reconciler to run immediately instead of waiting for timer
      AgentReconciler.force_reconcile()

      # 3. Verify the agent has been restarted by the reconciler.
      assert {:ok, info} = HordeSupervisor.get_agent_info(agent_id)
      assert is_pid(info.pid)
      assert info.id == agent_id

      # Cleanup
      HordeSupervisor.stop_agent(agent_id)
    end

    @tag :reconciliation
    test "does not restart agents with :temporary restart strategy" do
      agent_id = "reconciler-temporary-test-#{System.unique_integer([:positive])}"

      agent_spec = %{
        id: agent_id,
        module: Arbor.Test.Mocks.TestAgent,
        args: [],
        # This is the key
        restart_strategy: :temporary
      }

      # Start the agent
      {:ok, pid} = HordeSupervisor.start_agent(agent_spec)

      # Wait for agent to be registered
      AsyncHelpers.wait_for_agent_ready(agent_id, timeout: 2000)

      # Kill the agent process directly (without removing spec)
      # This simulates a crash that the reconciler should handle
      Horde.DynamicSupervisor.terminate_child(Arbor.Core.HordeAgentSupervisor, pid)

      # Wait for agent to be dead
      AsyncHelpers.wait_until(
        fn ->
          not Process.alive?(pid)
        end,
        timeout: 1000,
        initial_delay: 25
      )

      # Wait for the reconciler to run at least one cycle
      # With reconciliation_interval set to 100ms, we wait for at least 2 cycles
      Process.sleep(300)

      # Verify the agent was NOT restarted
      # The spec should still exist but no agent should be running
      case HordeSupervisor.get_agent_info(agent_id) do
        {:error, :not_found} ->
          # Agent not running, which is expected
          :ok

        {:ok, _info} ->
          # If we get here, the agent was restarted, which is wrong
          flunk("Temporary agent should not have been restarted")
      end

      # Clean up the spec manually since we didn't use stop_agent
      spec_key = {:agent_spec, agent_id}
      Horde.Registry.unregister(Arbor.Core.HordeAgentRegistry, spec_key)
    end
  end
end
