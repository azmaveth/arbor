defmodule Arbor.Contracts.Agent.Checkpoint do
  @moduledoc """
  Contract for checkpoint agent operations.

  This contract defines the interface for agent components in the Arbor system.
  Original implementation: Arbor.Core.AgentCheckpoint

  ## Responsibilities

  - Define the core interface for agent operations
  - Ensure consistent behavior across implementations
  - Provide clear contracts for testing and mocking
  - Enable dependency injection and modularity

  @version "1.0.0"
  """

  alias Arbor.Types

  @type checkpoint_data :: any()
  @type agent_state :: any()

  @callback extract_checkpoint_data(agent_state()) :: checkpoint_data()
  @callback restore_from_checkpoint(checkpoint_data(), agent_state()) :: agent_state()
end
