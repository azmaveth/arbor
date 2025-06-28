defmodule Arbor.Contracts.Gateway.API do
  @moduledoc """
  Contract for gateway API operations.

  The gateway provides the primary interface for external clients to
  interact with the Arbor system. It handles command execution,
  event subscriptions, and status tracking while maintaining security
  and session isolation.

  ## Gateway Responsibilities

  - **Command Processing**: Parse and validate client commands
  - **Session Management**: Route commands to appropriate sessions
  - **Event Streaming**: Real-time updates to clients
  - **Security Enforcement**: Validate all operations
  - **Rate Limiting**: Prevent abuse and ensure fairness

  ## Command Flow

  1. Client sends command to gateway
  2. Gateway validates and authorizes
  3. Command routed to session/agents
  4. Execution tracked and monitored
  5. Results streamed back to client

  ## Example Implementation

      defmodule MyGateway do
        @behaviour Arbor.Contracts.Gateway.API

        @impl true
        def execute_command(command, context, state) do
          with :ok <- validate_command(command),
               :ok <- authorize_operation(command, context),
               {:ok, ref} <- route_to_session(command, context.session_id) do
            {:ok, ref}
          end
        end
      end

  @version "1.0.0"
  """

  @type command :: map()
  @type execution_ref :: String.t()
  @type context :: map()
  @type state :: any()
  @type subscription_ref :: reference()

  @type gateway_error ::
          :invalid_command
          | :unauthorized
          | :session_not_found
          | :rate_limit_exceeded
          | :execution_timeout
          | :invalid_subscription
          | :gateway_overloaded
          | {:error, term()}

  @doc """
  Execute a command from a client.

  Processes a command within the context of a session, handling
  validation, authorization, and routing to appropriate agents.

  ## Parameters

  - `command` - Command to execute
  - `context` - Execution context
  - `state` - Gateway state

  ## Command Structure

  ```elixir
  %{
    type: :analyze_code,
    params: %{
      file_path: "lib/app.ex",
      metrics: [:complexity, :coverage]
    },
    options: %{
      timeout: 60_000,
      priority: :high
    }
  }
  ```

  ## Context

  ```elixir
  %{
    session_id: "session_123",
    user_id: "user_456",
    client_id: "client_789",
    capabilities: [cap1, cap2],
    trace_id: "trace_abc"
  }
  ```

  ## Returns

  - `{:ok, execution_ref}` - Command accepted for execution
  - `{:error, :invalid_command}` - Command validation failed
  - `{:error, :unauthorized}` - Lacks required permissions
  - `{:error, reason}` - Execution failed

  ## Example

      command = %{
        type: :create_agent,
        params: %{agent_type: :llm, model: "gpt-4"},
        options: %{timeout: 30_000}
      }

      {:ok, ref} = Gateway.execute_command(command, context, state)
  """
  @callback execute_command(
              command(),
              context(),
              state()
            ) :: {:ok, execution_ref()} | {:error, gateway_error()}

  @doc """
  Get the status of a command execution.

  Returns current status and any available results for a
  previously executed command.

  ## Parameters

  - `execution_ref` - Reference from execute_command/3
  - `state` - Gateway state

  ## Returns

  Status map containing:
  - `:status` - Current execution status
  - `:progress` - Completion percentage (0-100)
  - `:result` - Final result (if completed)
  - `:error` - Error details (if failed)
  - `:events` - Recent execution events
  - `:started_at` - Execution start time
  - `:completed_at` - Completion time (if finished)

  ## Status Values

  - `:queued` - Waiting to execute
  - `:executing` - Currently running
  - `:completed` - Successfully finished
  - `:failed` - Execution failed
  - `:cancelled` - Cancelled by user
  - `:timeout` - Exceeded time limit
  """
  @callback get_execution_status(
              execution_ref(),
              state()
            ) :: {:ok, map()} | {:error, :execution_not_found}

  @doc """
  Cancel a running command execution.

  Attempts to stop a command that is currently executing.
  Some commands may not be cancellable once started.

  ## Parameters

  - `execution_ref` - Execution to cancel
  - `reason` - Cancellation reason
  - `state` - Gateway state

  ## Returns

  - `:ok` - Cancellation initiated
  - `{:error, :not_cancellable}` - Command cannot be cancelled
  - `{:error, :execution_not_found}` - Unknown execution
  """
  @callback cancel_execution(
              execution_ref(),
              reason :: atom(),
              state()
            ) :: :ok | {:error, gateway_error()}

  @doc """
  Subscribe to events for a session or execution.

  Establishes a subscription for real-time event updates.
  Events are delivered as messages to the subscribing process.

  ## Parameters

  - `target` - What to subscribe to
  - `event_types` - Types of events to receive
  - `subscriber` - Process to receive events
  - `state` - Gateway state

  ## Target Specification

  ```elixir
  # Subscribe to session events
  {:session, "session_123"}

  # Subscribe to execution events
  {:execution, execution_ref}

  # Subscribe to agent events
  {:agent, "agent_456"}

  # Subscribe to all events for a user
  {:user, "user_789"}
  ```

  ## Event Types

  - `:status_change` - Execution status updates
  - `:progress` - Progress updates
  - `:log` - Log messages
  - `:error` - Error events
  - `:result` - Final results
  - `:agent_event` - Agent lifecycle events

  ## Returns

  - `{:ok, subscription_ref}` - Subscription established
  - `{:error, :invalid_subscription}` - Invalid target/types
  """
  @callback subscribe_events(
              target :: tuple(),
              event_types :: [atom()],
              subscriber :: pid(),
              state()
            ) :: {:ok, subscription_ref()} | {:error, gateway_error()}

  @doc """
  Unsubscribe from events.

  Stops event delivery for a subscription.

  ## Parameters

  - `subscription_ref` - Subscription to cancel
  - `state` - Gateway state

  ## Returns

  - `:ok` - Unsubscribed successfully
  - `{:error, :subscription_not_found}` - Unknown subscription
  """
  @callback unsubscribe_events(
              subscription_ref(),
              state()
            ) :: :ok | {:error, gateway_error()}

  @doc """
  List available commands.

  Returns information about commands the client can execute
  based on their capabilities and session state.

  ## Parameters

  - `context` - Client context
  - `state` - Gateway state

  ## Returns

  List of command specs, each containing:
  - `:type` - Command type atom
  - `:description` - Human-readable description
  - `:params` - Required and optional parameters
  - `:required_capabilities` - Capabilities needed
  - `:examples` - Usage examples
  """
  @callback list_commands(
              context(),
              state()
            ) :: {:ok, [map()]} | {:error, gateway_error()}

  @doc """
  Validate a command without executing.

  Performs all validation checks to determine if a command
  would be accepted for execution.

  ## Parameters

  - `command` - Command to validate
  - `context` - Execution context
  - `state` - Gateway state

  ## Returns

  - `:ok` - Command is valid
  - `{:error, validation_errors}` - Validation failed

  ## Validation Errors

  Returns a list of validation errors:
  ```elixir
  [
    {:missing_param, :file_path},
    {:invalid_type, :timeout, "must be positive integer"},
    {:unauthorized, :write_permission}
  ]
  ```
  """
  @callback validate_command(
              command(),
              context(),
              state()
            ) :: :ok | {:error, [tuple()]}

  @doc """
  Get gateway health and metrics.

  Returns information about gateway performance and health.

  ## Returns

  Health map containing:
  - `:status` - Overall gateway health
  - `:active_executions` - Currently running commands
  - `:queued_commands` - Commands waiting to execute
  - `:subscriptions` - Active event subscriptions
  - `:rate_limit_status` - Rate limiting information
  - `:latency_ms` - Recent response times
  - `:error_rate` - Recent error percentage
  """
  @callback get_health(state()) :: {:ok, map()} | {:error, gateway_error()}

  @doc """
  Apply rate limiting to a client.

  Checks and updates rate limit counters for a client,
  determining if an operation should be allowed.

  ## Parameters

  - `client_id` - Client identifier
  - `operation` - Type of operation
  - `cost` - Resource cost of operation
  - `state` - Gateway state

  ## Returns

  - `{:ok, remaining}` - Operation allowed, remaining quota
  - `{:error, {:rate_limit_exceeded, reset_at}}` - Limit exceeded
  """
  @callback check_rate_limit(
              client_id :: String.t(),
              operation :: atom(),
              cost :: non_neg_integer(),
              state()
            ) :: {:ok, non_neg_integer()} | {:error, {:rate_limit_exceeded, DateTime.t()}}

  @doc """
  Initialize the gateway implementation.

  Sets up gateway infrastructure and configuration.

  ## Options

  - `:max_concurrent_executions` - Execution limit
  - `:rate_limits` - Rate limiting configuration
  - `:event_buffer_size` - Event queue size
  - `:timeout_defaults` - Default timeouts by command type

  ## Returns

  - `{:ok, state}` - Gateway initialized
  - `{:error, reason}` - Initialization failed
  """
  @callback initialize_gateway(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc """
  Clean up gateway resources when shutting down.

  Should cancel executions and close subscriptions gracefully.
  """
  @callback shutdown_gateway(reason :: term(), state()) :: :ok
end
