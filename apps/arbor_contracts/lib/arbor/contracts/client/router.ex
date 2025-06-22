defmodule Arbor.Contracts.Client.Router do
  @moduledoc """
  Contract for client-side command routing and execution.

  This behaviour defines a standardized interface for clients (like the CLI)
  to interact with the Arbor Gateway. It abstracts the complexities of
  session management, command serialization, transport, and result handling.

  ## Router Responsibilities

  - **Configuration Management**: Handle gateway endpoint, timeouts, etc.
  - **Session Lifecycle**: Establish and tear down sessions with the gateway.
  - **Command Routing**: Send commands to the correct gateway endpoint.
  - **Execution Tracking**: Manage the lifecycle of a command from submission to result.
  - **Result Parsing**: Interpret responses from the gateway.

  ## Typical Flow

  1. `init(config)` is called to set up the router.
  2. `execute_command(command, state)` is called by the client application.
  3. The router implementation ensures a session is active.
  4. It sends the command to the gateway via HTTP or another transport.
  5. It waits for the command to complete, potentially polling for status.
  6. It parses the gateway's response into a standardized result format.
  7. The result is returned to the client application.

  ## Example Implementation

      defmodule MyClient.Router do
        @behaviour Arbor.Contracts.Client.Router

        alias Arbor.Contracts.Client.Command

        @impl true
        def init(opts) do
          state = %{
            gateway_url: Keyword.get(opts, :gateway_url),
            http_client: SomeClient.new()
          }
          {:ok, state}
        end

        @impl true
        def execute_command(%Command{} = command, state) do
          with {:ok, state_with_session} <- establish_session(state),
               {:ok, response} <- send_to_gateway(command, state_with_session) do
            {:ok, response.body}
          else
            error -> error
          end
        end

        # ... other callbacks
      end
  """

  alias Arbor.Contracts.Client.Command

  @type command :: Command.t()
  @type config :: keyword()
  @type state :: any()
  @type router_error :: {:error, term()}

  @doc """
  Initializes the router with the given configuration.

  This is called once when the client application starts.

  ## Options

  - `:gateway_url` - The URL of the Arbor Gateway.
  - `:timeout` - Default timeout for commands in milliseconds.
  - `:session_id` - An existing session ID to reuse.

  ## Returns

  - `{:ok, state}` - Router initialized successfully.
  - `{:error, reason}` - Initialization failed.
  """
  @callback init(config()) :: {:ok, state()} | router_error()

  @doc """
  Executes a command and waits for its final result.

  This function encapsulates the entire command lifecycle:
  1. Ensures a session is available.
  2. Sends the command to the gateway.
  3. Polls for status until the command is completed, failed, or timed out.
  4. Returns the final result.

  This is a blocking call, suitable for synchronous clients like a CLI.

  ## Parameters

  - `command` - The `Arbor.Contracts.Client.Command.t()` to execute.
  - `state` - The current router state.

  ## Returns

  - `{:ok, result}` - The command completed successfully. `result` is the payload from the gateway.
  - `{:error, reason}` - The command failed. `reason` could be a gateway error, a timeout, or a transport error.
  """
  @callback execute_command(command(), state()) :: {:ok, map()} | router_error()

  @doc """
  Establishes a session with the gateway.

  If a session is already active in the state, it may be reused.
  Otherwise, a new session is created.

  ## Parameters
  - `state` - The current router state.

  ## Returns
  - `{:ok, new_state}` - Session established. `new_state` contains the session info.
  - `{:error, reason}` - Failed to establish a session.
  """
  @callback establish_session(state()) :: {:ok, state()} | router_error()

  @doc """
  Terminates the session with the gateway.

  ## Parameters
  - `state` - The current router state, which should contain session information.

  ## Returns
  - `{:ok, new_state}` - Session terminated successfully. `new_state` reflects the terminated session.
  - `{:error, reason}` - Failed to terminate the session.
  """
  @callback terminate_session(state()) :: {:ok, state()} | router_error()

  @doc """
  Cleans up router resources.

  Called when the client application is shutting down.

  ## Parameters
  - `reason` - The reason for termination.
  - `state` - The final router state.

  ## Returns
  - `:ok`
  """
  @callback terminate(reason :: term(), state()) :: :ok
end
