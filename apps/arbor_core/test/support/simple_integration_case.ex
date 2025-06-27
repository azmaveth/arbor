defmodule Arbor.Test.Support.SimpleIntegrationCase do
  @moduledoc """
  Simplified integration test case for Arbor Core.

  This module provides a minimal setup for integration tests that need
  real Horde components but don't require full distributed infrastructure.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false

      import Arbor.Test.Support.SimpleIntegrationCase
      alias Arbor.Test.Support.AsyncHelpers

      @moduletag :integration
      @moduletag timeout: 30_000
    end
  end

  setup_all do
    # Ensure we're using Horde implementations
    Application.put_env(:arbor_core, :registry_impl, :horde)
    Application.put_env(:arbor_core, :supervisor_impl, :horde)
    Application.put_env(:arbor_core, :coordinator_impl, :horde)

    # Disable libcluster
    Application.put_env(:libcluster, :topologies, [])

    # Start required applications
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

    # Start core services manually
    children = [
      # Phoenix PubSub
      {Phoenix.PubSub, name: Arbor.Core.PubSub},

      # Task Supervisor
      {Task.Supervisor, name: Arbor.TaskSupervisor},

      # Horde infrastructure (simplified)
      %{
        id: Arbor.Core.HordeSupervisor,
        start: {Arbor.Core.HordeSupervisor, :start_supervisor, []},
        type: :supervisor
      },

      # Horde Coordinator
      %{
        id: Arbor.Core.HordeCoordinator,
        start: {Arbor.Core.HordeCoordinator, :start_coordination, []},
        type: :supervisor
      },

      # Agent Reconciler
      Arbor.Core.AgentReconciler,

      # Sessions Manager
      Arbor.Core.Sessions.Manager,

      # Gateway
      Arbor.Core.Gateway
    ]

    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

    # Wait for Horde to be ready
    Process.sleep(500)

    on_exit(fn ->
      try do
        if Process.alive?(sup) do
          Supervisor.stop(sup)
        end
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  setup do
    # Clean up any test agents before each test
    cleanup_test_agents()
    :ok
  end

  @doc """
  Cleans up test agents between tests.
  """
  def cleanup_test_agents do
    try do
      children = Horde.DynamicSupervisor.which_children(Arbor.Core.HordeAgentSupervisor)

      for {agent_id, _pid, _type, _modules} <- children do
        if is_binary(agent_id) and String.contains?(agent_id, "test") do
          Arbor.Core.HordeSupervisor.stop_agent(agent_id)
        end
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end
end
