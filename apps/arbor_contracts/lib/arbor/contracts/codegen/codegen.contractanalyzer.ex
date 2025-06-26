defmodule Arbor.Contracts.Codegen.CodeGen.ContractAnalyzer do
  @moduledoc """
  Contract for codegen.contractanalyzer codegen operations.

  This contract defines the interface for codegen components in the Arbor system.
  Original implementation: Arbor.CodeGen.ContractAnalyzer

  ## Responsibilities

  - Define the core interface for codegen operations
  - Ensure consistent behavior across implementations
  - Provide clear contracts for testing and mocking
  - Enable dependency injection and modularity

  @version "1.0.0"
  """

  @callback process(input :: any()) :: {:ok, output :: any()} | {:error, term()}

  @callback configure(options :: keyword()) :: :ok | {:error, term()}
end
