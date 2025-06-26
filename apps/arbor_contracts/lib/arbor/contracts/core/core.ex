defmodule Arbor.Contracts.Core.Core do
  @moduledoc """
  Contract for core core operations.

  This contract defines the interface for core components in the Arbor system.
  Original implementation: Arbor.Core

  ## Responsibilities

  - Define the core interface for core operations
  - Ensure consistent behavior across implementations
  - Provide clear contracts for testing and mocking
  - Enable dependency injection and modularity

  @version "1.0.0"
  """

  @callback process(input :: any()) :: {:ok, output :: any()} | {:error, term()}

  @callback configure(options :: keyword()) :: :ok | {:error, term()}
end
