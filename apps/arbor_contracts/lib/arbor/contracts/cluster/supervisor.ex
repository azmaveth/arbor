defmodule Arbor.Contracts.Cluster.Supervisor do
  @moduledoc """
  Contract for supervisor cluster operations.

  This contract defines the interface for cluster components in the Arbor system.
  Original implementation: Arbor.Core.HordeSupervisor

  ## Responsibilities

  - Define the core interface for cluster operations
  - Ensure consistent behavior across implementations
  - Provide clear contracts for testing and mocking
  - Enable dependency injection and modularity

  @version "1.0.0"
  """

  # Service lifecycle
  @callback start_service(config :: map()) :: {:ok, pid()} | {:error, term()}
  @callback stop_service(reason :: term()) :: :ok
  @callback get_status() :: {:ok, map()} | {:error, term()}

  # Agent management
  @callback start_agent(agent_spec :: map()) :: {:ok, pid()} | {:error, term()}
  @callback stop_agent(agent_id :: binary(), timeout :: non_neg_integer()) ::
              :ok | {:error, term()}
  @callback restart_agent(agent_id :: binary()) :: {:ok, pid()} | {:error, term()}
  @callback get_agent_info(agent_id :: binary()) :: {:ok, map()} | {:error, term()}
  @callback list_agents() :: {:ok, [map()]} | {:error, term()}

  # Agent restoration and updates
  @callback restore_agent(agent_id :: binary()) :: {:ok, pid()} | {:error, term()}
  @callback update_agent_spec(agent_id :: binary(), updates :: map()) :: :ok | {:error, term()}

  # Health and monitoring
  @callback health_metrics() :: {:ok, map()} | {:error, term()}

  # Event handling
  @callback set_event_handler(event_type :: atom(), callback :: function()) ::
              :ok | {:error, term()}

  # State management
  @callback extract_agent_state(agent_id :: binary()) :: {:ok, any()} | {:error, term()}
  @callback restore_agent_state(agent_id :: binary(), state :: any()) ::
              {:ok, any()} | {:error, term()}
end
