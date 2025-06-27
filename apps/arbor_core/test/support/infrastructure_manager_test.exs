defmodule Arbor.Test.Support.InfrastructureManagerTest do
  @moduledoc """
  Tests for the InfrastructureManager singleton.
  """

  use ExUnit.Case, async: false

  alias Arbor.Test.Support.InfrastructureManager

  describe "singleton behavior" do
    test "multiple calls to ensure_started return same result" do
      # First call
      assert :ok = InfrastructureManager.ensure_started()

      # Second call should also succeed without starting duplicate infrastructure
      assert :ok = InfrastructureManager.ensure_started()

      # Verify infrastructure is running
      assert InfrastructureManager.infrastructure_running?()
    end

    test "infrastructure persists across test module registrations" do
      # Register first module
      cleanup1 = InfrastructureManager.register_user(Module1)

      # Register second module
      cleanup2 = InfrastructureManager.register_user(Module2)

      # Infrastructure should still be running
      assert InfrastructureManager.infrastructure_running?()

      # Clean up first module
      cleanup1.()

      # Infrastructure should still be running (second module still registered)
      assert InfrastructureManager.infrastructure_running?()

      # Clean up second module
      cleanup2.()

      # Give it time to process cleanup
      Process.sleep(100)

      # Note: Infrastructure may still be running due to delayed cleanup
      # This is intentional to handle rapid test restarts
    end
  end

  describe "infrastructure components" do
    setup do
      :ok = InfrastructureManager.ensure_started()
      cleanup = InfrastructureManager.register_user(__MODULE__)

      on_exit(cleanup)

      :ok
    end

    test "all required processes are started" do
      # Verify core processes
      assert Process.whereis(Arbor.Core.PubSub) != nil
      assert Process.whereis(Arbor.TaskSupervisor) != nil
      assert Process.whereis(Arbor.Core.HordeAgentRegistry) != nil
      assert Process.whereis(Arbor.Core.HordeAgentSupervisor) != nil
      assert Process.whereis(Arbor.Core.AgentReconciler) != nil
      assert Process.whereis(Arbor.Core.ClusterManager) != nil
      assert Process.whereis(Arbor.Core.Sessions.Manager) != nil
      assert Process.whereis(Arbor.Core.Gateway) != nil
    end

    test "Horde cluster membership is configured" do
      current_node = node()

      # Check registry membership
      registry_members = Horde.Cluster.members(Arbor.Core.HordeAgentRegistry)

      assert Enum.any?(registry_members, fn
               {Arbor.Core.HordeAgentRegistry, node} when node == current_node -> true
               _ -> false
             end)

      # Check supervisor membership
      supervisor_members = Horde.Cluster.members(Arbor.Core.HordeAgentSupervisor)

      assert Enum.any?(supervisor_members, fn
               {Arbor.Core.HordeAgentSupervisor, node} when node == current_node -> true
               _ -> false
             end)
    end

    test "ETS tables are created" do
      keys_table = :"keys_Elixir.Arbor.Core.HordeAgentRegistry"
      assert :ets.info(keys_table) != :undefined
    end
  end
end
