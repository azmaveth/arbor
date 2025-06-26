defmodule Arbor.Contracts.Agent.Behavior do
  @moduledoc """
  Contract for behavior agent operations.

  This contract defines the interface for agent components in the Arbor system.
  Original implementation: Arbor.Core.AgentBehavior

  ## Responsibilities

  - Define the core interface for agent operations
  - Ensure consistent behavior across implementations
  - Provide clear contracts for testing and mocking
  - Enable dependency injection and modularity

  @version "1.0.0"
  """

  @callback extract_state(state :: any()) :: {:ok, any()} | {:error, any()}
  @callback restore_state(agent_spec :: map(), restored_state :: any()) ::
              {:ok, any()} | {:error, any()}
  @callback get_agent_metadata(state :: any()) :: map()
  @callback handle_registration_result(state :: any(), result :: {:ok, any()} | {:error, any()}) ::
              any()

  @optional_callbacks extract_state: 1,
                      restore_state: 2,
                      get_agent_metadata: 1,
                      handle_registration_result: 2
end
