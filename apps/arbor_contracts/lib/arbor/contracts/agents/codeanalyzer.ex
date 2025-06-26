defmodule Arbor.Contracts.Agents.CodeAnalyzer do
  @moduledoc """
  Contract for codeanalyzer agents operations.

  This contract defines the interface for agents components in the Arbor system.
  Original implementation: Arbor.Agents.CodeAnalyzer

  ## Responsibilities

  - Define the core interface for agents operations
  - Ensure consistent behavior across implementations
  - Provide clear contracts for testing and mocking
  - Enable dependency injection and modularity

  @version "1.0.0"
  """

  @callback process(input :: any()) :: {:ok, output :: any()} | {:error, term()}

  @callback configure(options :: keyword()) :: :ok | {:error, term()}
end
