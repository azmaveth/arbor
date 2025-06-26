defmodule Arbor.Contracts.Tasks.Gen.Impl do
  @moduledoc """
  Contract for gen.impl tasks operations.

  This contract defines the interface for tasks components in the Arbor system.
  Original implementation: Mix.Tasks.Arbor.Gen.Impl

  ## Responsibilities

  - Define the core interface for tasks operations
  - Ensure consistent behavior across implementations
  - Provide clear contracts for testing and mocking
  - Enable dependency injection and modularity

  @version "1.0.0"
  """

  @callback process(input :: any()) :: {:ok, output :: any()} | {:error, term()}

  @callback configure(options :: keyword()) :: :ok | {:error, term()}
end
