defmodule Arbor.Test.Support.MoxSetup do
  @moduledoc """
  Test helper for setting up Mox-based contract mocks.

  This module provides centralized configuration for all contract-based mocks
  used throughout the test suite. It replaces hand-written test mocks with
  Mox-generated stubs that enforce contract compliance.

  ## Usage

      defmodule MyTest do
        use ExUnit.Case
        import Arbor.Test.Support.MoxSetup
        
        setup :setup_mox
        
        test "some functionality" do
          expect_registry_lookup("agent_id", {:ok, {self(), %{}}})
          # test code
        end
      end

  ## Contract Enforcement

  All mocks are generated from actual behaviour contracts defined in 
  arbor_contracts, ensuring implementations stay in sync with interfaces.
  """

  import Mox

  # Define mocks for each contract
  defmock(Arbor.Core.MockRegistry, for: Arbor.Contracts.Cluster.Registry)
  defmock(Arbor.Core.MockSupervisor, for: Arbor.Contracts.Cluster.Supervisor)
  defmock(Arbor.Core.MockCoordinator, for: Arbor.Contracts.Cluster.Coordinator)
  defmock(Arbor.Core.MockSessionManager, for: Arbor.Contracts.Session.Manager)

  # Gateway-specific supervisor mock (replaces LocalSupervisor)
  defmock(Arbor.Test.Mocks.SupervisorMock, for: Arbor.Contracts.Cluster.Supervisor)

  # Mock for LocalCoordinator functions (replaces LocalCoordinator)
  defmock(Arbor.Test.Mocks.LocalCoordinatorMock,
    for: Arbor.Test.Support.LocalCoordinatorBehaviour
  )

  @doc """
  Sets up Mox for the current test process.

  Should be called in test setup blocks.
  """
  def setup_mox(_context) do
    # Set global mode to false to ensure test isolation
    Mox.set_mox_private()
    :ok
  end

  @doc """
  Sets up all mocks for the current test process.

  This is a convenience function that configures all commonly used mocks.
  """
  def setup_all_mocks do
    setup_mox(%{})
    :ok
  end

  @doc """
  Configures the application to use mock implementations.

  Call this in setup_all blocks.
  """
  def setup_mock_implementations do
    Application.put_env(:arbor_core, :registry_impl, Arbor.Core.MockRegistry)
    Application.put_env(:arbor_core, :supervisor_impl, Arbor.Core.MockSupervisor)
    Application.put_env(:arbor_core, :coordinator_impl, Arbor.Core.MockCoordinator)
    Application.put_env(:arbor_core, :session_manager_impl, Arbor.Core.MockSessionManager)

    :ok
  end

  @doc """
  Resets application configuration to use auto-detection.

  Call this in on_exit blocks.
  """
  def reset_implementations do
    Application.put_env(:arbor_core, :registry_impl, :auto)
    Application.put_env(:arbor_core, :supervisor_impl, :auto)
    Application.put_env(:arbor_core, :coordinator_impl, :auto)
    Application.put_env(:arbor_core, :session_manager_impl, :auto)

    :ok
  end

  # Helper functions for common mock expectations

  @doc """
  Sets up expectation for registry lookup.
  """
  def expect_registry_lookup(agent_id, return_value) do
    expect(Arbor.Core.MockRegistry, :lookup_name, fn {:agent, ^agent_id}, _state ->
      return_value
    end)
  end

  @doc """
  Sets up expectation for registry registration.
  """
  def expect_registry_register(agent_id, return_value \\ :ok) do
    expect(Arbor.Core.MockRegistry, :register_name, fn {:agent, ^agent_id},
                                                       _pid,
                                                       _metadata,
                                                       _state ->
      return_value
    end)
  end

  @doc """
  Sets up expectation for supervisor start_agent.
  """
  def expect_supervisor_start(agent_spec, return_value) do
    Arbor.Core.MockSupervisor
    |> expect(:start_agent, fn spec ->
      # Match the spec while ignoring fields added by validate_and_normalize_spec
      # We check the key fields match but allow additional fields
      if spec.id == agent_spec.id &&
           spec.module == agent_spec.module &&
           spec.args == agent_spec.args &&
           spec.restart_strategy == Map.get(agent_spec, :restart_strategy, :permanent) &&
           (!Map.has_key?(agent_spec, :metadata) || spec.metadata == agent_spec.metadata) do
        return_value
      else
        raise "Agent spec mismatch in test"
      end
    end)
  end

  @doc """
  Sets up expectation for supervisor stop_agent.
  """
  def expect_supervisor_stop(agent_id, return_value \\ :ok, timeout \\ 5000) do
    Arbor.Core.MockSupervisor
    |> expect(:stop_agent, fn ^agent_id, ^timeout -> return_value end)
  end

  @doc """
  Sets up expectation for supervisor get_agent_info.
  """
  def expect_supervisor_info(agent_id, return_value) do
    Arbor.Core.MockSupervisor
    |> expect(:get_agent_info, fn ^agent_id -> return_value end)
  end

  @doc """
  Sets up expectation for supervisor list_agents.
  """
  def expect_supervisor_list(return_value) do
    Arbor.Core.MockSupervisor
    |> expect(:list_agents, fn -> return_value end)
  end

  @doc """
  Sets up expectation for supervisor restart_agent.
  """
  def expect_supervisor_restart(agent_id, return_value) do
    Arbor.Core.MockSupervisor
    |> expect(:restart_agent, fn ^agent_id -> return_value end)
  end

  @doc """
  Sets up expectation for supervisor health_metrics.
  """
  def expect_supervisor_health(return_value) do
    Arbor.Core.MockSupervisor
    |> expect(:health_metrics, fn -> return_value end)
  end

  @doc """
  Sets up expectation for session manager create_session.
  """
  def expect_session_create(params, return_value) do
    Arbor.Core.MockSessionManager
    |> expect(:create_session, fn ^params, _state -> return_value end)
  end

  @doc """
  Sets up expectation for session manager get_session.
  """
  def expect_session_get(session_id, return_value) do
    Arbor.Core.MockSessionManager
    |> expect(:get_session, fn ^session_id, _state -> return_value end)
  end

  # Coordinator mock helpers

  @doc """
  Sets up expectation for coordinator handle_node_join.
  """
  def expect_coordinator_handle_node_join(node_info, return_value \\ :ok) do
    Arbor.Test.Mocks.LocalCoordinatorMock
    |> expect(:handle_node_join, fn ^node_info, _state -> return_value end)
  end

  @doc """
  Sets up expectation for coordinator handle_node_leave.
  """
  def expect_coordinator_handle_node_leave(node, reason, return_value \\ :ok) do
    Arbor.Test.Mocks.LocalCoordinatorMock
    |> expect(:handle_node_leave, fn ^node, ^reason, _state -> return_value end)
  end

  @doc """
  Sets up expectation for coordinator handle_node_failure.
  """
  def expect_coordinator_handle_node_failure(node, reason, return_value \\ :ok) do
    Arbor.Test.Mocks.LocalCoordinatorMock
    |> expect(:handle_node_failure, fn ^node, ^reason, _state -> return_value end)
  end

  @doc """
  Sets up expectation for coordinator get_cluster_info.
  """
  def expect_coordinator_get_cluster_info(return_value) do
    Arbor.Test.Mocks.LocalCoordinatorMock
    |> expect(:get_cluster_info, fn _state -> return_value end)
  end

  @doc """
  Sets up expectation for coordinator register_agent_on_node.
  """
  def expect_coordinator_register_agent(agent_info, return_value \\ :ok) do
    Arbor.Test.Mocks.LocalCoordinatorMock
    |> expect(:register_agent_on_node, fn ^agent_info, _state -> return_value end)
  end

  @doc """
  Sets up expectation for coordinator calculate_distribution.
  """
  def expect_coordinator_calculate_distribution(agents, return_value) do
    Arbor.Test.Mocks.LocalCoordinatorMock
    |> expect(:calculate_distribution, fn ^agents, _state -> return_value end)
  end

  @doc """
  Sets up expectation for coordinator suggest_redistribution.
  """
  def expect_coordinator_suggest_redistribution(return_value) do
    Arbor.Test.Mocks.LocalCoordinatorMock
    |> expect(:suggest_redistribution, fn _state -> return_value end)
  end

  @doc """
  Sets up expectation for coordinator update_node_capacity.
  """
  def expect_coordinator_update_capacity(capacity_update, return_value \\ :ok) do
    Arbor.Test.Mocks.LocalCoordinatorMock
    |> expect(:update_node_capacity, fn ^capacity_update, _state -> return_value end)
  end

  @doc """
  Sets up expectation for coordinator get_sync_status.
  """
  def expect_coordinator_get_sync_status(return_value) do
    Arbor.Test.Mocks.LocalCoordinatorMock
    |> expect(:get_sync_status, fn _state -> return_value end)
  end

  @doc """
  Sets up expectation for coordinator get_cluster_health.
  """
  def expect_coordinator_get_cluster_health(return_value) do
    Arbor.Test.Mocks.LocalCoordinatorMock
    |> expect(:get_cluster_health, fn _state -> return_value end)
  end

  @doc """
  Sets up expectation for coordinator process_coordination_event.
  """
  def expect_coordinator_process_event(event, return_value \\ :ok) do
    Arbor.Test.Mocks.LocalCoordinatorMock
    |> expect(:process_coordination_event, fn ^event, _state -> return_value end)
  end
end
