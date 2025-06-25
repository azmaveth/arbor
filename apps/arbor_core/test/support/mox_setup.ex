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
    Arbor.Core.MockRegistry
    |> expect(:lookup_name, fn {:agent, ^agent_id}, _state -> return_value end)
  end

  @doc """
  Sets up expectation for registry registration.
  """
  def expect_registry_register(agent_id, return_value \\ :ok) do
    Arbor.Core.MockRegistry
    |> expect(:register_name, fn {:agent, ^agent_id}, _pid, _metadata, _state -> return_value end)
  end

  @doc """
  Sets up expectation for supervisor start_agent.
  """
  def expect_supervisor_start(agent_spec, return_value) do
    Arbor.Core.MockSupervisor
    |> expect(:start_agent, fn ^agent_spec -> return_value end)
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
end
