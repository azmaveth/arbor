defmodule Arbor.Contracts.Cluster.Coordinator do
  @moduledoc """
  Contract for coordinator cluster operations.

  This contract defines the interface for cluster components in the Arbor system.
  Original implementation: Arbor.Core.HordeCoordinator

  ## Responsibilities

  - Define the core interface for cluster operations
  - Ensure consistent behavior across implementations
  - Provide clear contracts for testing and mocking
  - Enable dependency injection and modularity

  @version "1.0.0"
  """

  @callback start_service(config :: map()) :: {:ok, pid()} | {:error, term()}

  @callback stop_service(reason :: term()) :: :ok

  @callback get_status() :: {:ok, map()} | {:error, term()}
end
