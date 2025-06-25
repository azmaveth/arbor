defmodule Arbor.Contracts.Session.Session do
  @moduledoc """
  Contract for session session operations.

  This contract defines the interface for session components in the Arbor system.
  Original implementation: Arbor.Core.Sessions.Session

  ## Responsibilities

  - Define the core interface for session operations
  - Ensure consistent behavior across implementations
  - Provide clear contracts for testing and mocking
  - Enable dependency injection and modularity

  @version "1.0.0"
  """

  alias Arbor.Types

  @callback create_session(params :: map()) :: {:ok, session_id :: binary()} | {:error, term()}

  @callback get_session(session_id :: binary()) :: {:ok, map()} | {:error, term()}

  @callback terminate_session(session_id :: binary()) :: :ok | {:error, term()}
end
