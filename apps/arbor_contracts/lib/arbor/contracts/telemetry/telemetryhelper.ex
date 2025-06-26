defmodule Arbor.Contracts.Telemetry.TelemetryHelper do
  @moduledoc """
  Contract for telemetryhelper telemetry operations.

  This contract defines the interface for telemetry components in the Arbor system.
  Original implementation: Arbor.Core.TelemetryHelper

  ## Responsibilities

  - Define the core interface for telemetry operations
  - Ensure consistent behavior across implementations
  - Provide clear contracts for testing and mocking
  - Enable dependency injection and modularity

  @version "1.0.0"
  """

  @callback process(input :: any()) :: {:ok, output :: any()} | {:error, term()}

  @callback configure(options :: keyword()) :: :ok | {:error, term()}
end
