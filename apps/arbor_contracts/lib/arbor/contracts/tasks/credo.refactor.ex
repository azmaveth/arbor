defmodule Arbor.Contracts.Tasks.Credo.Refactor do
  @moduledoc """
  Contract for credo.refactor tasks operations.

  This contract defines the interface for tasks components in the Arbor system.
  Original implementation: Mix.Tasks.Credo.Refactor

  ## Responsibilities

  - Define the core interface for tasks operations
  - Ensure consistent behavior across implementations
  - Provide clear contracts for testing and mocking
  - Enable dependency injection and modularity

  @version "1.0.0"
  """

  alias Arbor.Types

  @callback process(input :: any()) :: {:ok, output :: any()} | {:error, term()}

  @callback configure(options :: keyword()) :: :ok | {:error, term()}
end
