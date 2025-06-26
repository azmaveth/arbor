defmodule Arbor.Contracts.Agent.Reconciler do
  @moduledoc """
  Contract for reconciler agent operations.

  This contract defines the interface for agent components in the Arbor system.
  Original implementation: Arbor.Core.AgentReconciler

  ## Responsibilities

  - Define the core interface for agent operations
  - Ensure consistent behavior across implementations
  - Provide clear contracts for testing and mocking
  - Enable dependency injection and modularity

  @version "1.0.0"
  """

  @callback execute_task(task :: any()) :: {:ok, result :: any()} | {:error, term()}

  @callback get_state() :: {:ok, state :: any()} | {:error, term()}
end
