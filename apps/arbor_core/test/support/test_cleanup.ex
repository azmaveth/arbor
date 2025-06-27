defmodule Arbor.Test.Support.TestCleanup do
  @moduledoc """
  Provides utilities to clean up test infrastructure between test runs.

  This module helps ensure a clean state by stopping all test-related
  processes and clearing any persistent state.
  """

  @doc """
  Performs a complete cleanup of test infrastructure.

  This should be called before starting tests to ensure a clean state.
  """
  def cleanup_all do
    cleanup_horde_components()
    cleanup_test_processes()
    cleanup_distributed_erlang()
    :ok
  end

  @doc """
  Cleans up Horde components (registries, supervisors).
  """
  def cleanup_horde_components do
    horde_processes = [
      # Coordinator components
      Arbor.Core.HordeCoordinationRegistry,
      Arbor.Core.HordeCoordinatorSupervisor,
      # Supervisor components  
      Arbor.Core.HordeAgentRegistry,
      Arbor.Core.HordeCheckpointRegistry,
      Arbor.Core.HordeAgentSupervisor,
      Arbor.Core.HordeSupervisorSupervisor
    ]

    for process_name <- horde_processes do
      if pid = Process.whereis(process_name) do
        try do
          Process.exit(pid, :shutdown)
          wait_for_process_exit(process_name)
        catch
          :exit, _ -> :ok
        end
      end
    end
  end

  @doc """
  Cleans up other test processes.
  """
  def cleanup_test_processes do
    test_processes = [
      Arbor.Core.PubSub,
      Arbor.TaskSupervisor,
      Arbor.Core.AgentReconciler,
      Arbor.Core.ClusterManager,
      Arbor.Core.Sessions.Manager,
      Arbor.Core.Gateway,
      Arbor.Test.Support.InfrastructureManager
    ]

    for process_name <- test_processes do
      if pid = Process.whereis(process_name) do
        try do
          case process_name do
            Arbor.Core.PubSub ->
              # PubSub needs special handling
              Supervisor.stop(pid, :shutdown)

            Arbor.TaskSupervisor ->
              # Task supervisor also needs special handling
              Supervisor.stop(pid, :shutdown)

            _ ->
              # GenServers can be stopped normally
              GenServer.stop(pid, :shutdown)
          end

          wait_for_process_exit(process_name)
        catch
          :exit, _ -> :ok
        end
      end
    end
  end

  @doc """
  Cleans up distributed Erlang if it was started for tests.
  """
  def cleanup_distributed_erlang do
    if node() != :nonode@nohost do
      try do
        :net_kernel.stop()
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp wait_for_process_exit(process_name, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    wait_loop(process_name, deadline)
  end

  defp wait_loop(process_name, deadline) do
    if Process.whereis(process_name) == nil do
      :ok
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        {:error, :timeout}
      else
        Process.sleep(10)
        wait_loop(process_name, deadline)
      end
    end
  end
end
