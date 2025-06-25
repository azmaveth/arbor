defmodule Arbor.Contracts.Gateway.Gateway do
  @moduledoc """
  Contract for gateway gateway operations.

  This contract defines the interface for gateway components that handle
  client requests, command processing, and response management.

  ## Responsibilities

  - Request validation and processing
  - Client authentication and authorization
  - Command routing and execution
  - Response formatting and delivery
  - Error handling and recovery

  @version "1.0.0"
  """

  alias Arbor.Types

  @type request :: map()
  @type context :: map()
  @type response :: map()

  @callback handle_request(request :: any(), context :: map()) ::
              {:ok, response :: any()} | {:error, reason :: term()}

  @callback validate_request(request :: any()) :: :ok | {:error, term()}
end
