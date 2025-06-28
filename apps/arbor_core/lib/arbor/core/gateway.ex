defmodule Arbor.Core.Gateway do
  @moduledoc """
  Central entry point for all Arbor operations implementing the Gateway pattern.

  The Gateway serves as the single entry point for all client interactions with
  the agent system. It provides a unified API that handles:

  - Session management and lifecycle
  - Capability discovery and validation
  - Asynchronous operation management
  - Event routing and subscription
  - Authentication and authorization

  ## Architecture

  The Gateway acts as a facade over the complex distributed agent system,
  providing a simple, consistent interface for clients while managing the
  underlying complexity of agent coordination, security, and state management.

  ## Client Types

  The Gateway supports multiple client types:
  - CLI clients for interactive command-line usage
  - Web UI clients for browser-based interfaces
  - API clients for programmatic access
  - Other agent systems for inter-system communication

  ## Usage

      # Start a session
      {:ok, session_id} = Gateway.create_session(metadata: %{client_type: :cli})

      # Discover available capabilities
      {:ok, capabilities} = Gateway.discover_capabilities(session_id)

      # Execute a command asynchronously
      {:ok, execution_id} = Gateway.execute(session_id, "analyze", %{target: "file.ex"})

      # Subscribe to execution events
      Gateway.subscribe_execution(execution_id)
  """

  @behaviour Arbor.Contracts.Gateway.Gateway

  @behaviour Arbor.Contracts.Gateway.API

  use GenServer

  alias Arbor.Agents.CodeAnalyzer
  alias Arbor.Contracts.Client.Command
  alias Arbor.Core.ClusterRegistry
  alias Arbor.Core.Sessions.Manager, as: SessionManager
  alias Arbor.{Identifiers, Types}

  require Logger

  # Gateway uses String.t() execution IDs for distributed compatibility

  @typedoc "Information about an available capability"
  @type capability_info :: %{
          name: String.t(),
          description: String.t(),
          parameters: [map()],
          required_permissions: [Types.resource_uri()]
        }

  @typedoc "Gateway state"
  @type state :: %{
          sessions: map(),
          active_executions: map(),
          stats: map()
        }

  # =====================================================
  # Gateway.Gateway Behaviour Callbacks
  # =====================================================

  @impl Arbor.Contracts.Gateway.Gateway
  @spec handle_request(request :: any(), context :: map()) ::
          {:ok, response :: any()} | {:error, reason :: term()}
  def handle_request(request, context) do
    case request do
      %{type: :command, payload: command} ->
        # Delegate to command execution
        execute_command(command, context, [])

      %{type: :query, payload: query} ->
        # Handle query requests
        handle_query(query, context)

      _ ->
        {:error, :invalid_request_type}
    end
  end

  @impl Arbor.Contracts.Gateway.Gateway
  @spec validate_request(request :: any()) ::
          :ok
          | {:error,
             :invalid_request_structure | :invalid_request_type | :invalid_request_payload}
  def validate_request(request) do
    with :ok <- validate_request_structure(request),
         :ok <- validate_request_type(request),
         :ok <- validate_request_payload(request) do
      :ok
    else
      error -> error
    end
  end

  defp validate_request_structure(%{type: _, payload: _}), do: :ok
  defp validate_request_structure(_), do: {:error, :invalid_request_structure}

  defp validate_request_type(%{type: type}) when type in [:command, :query], do: :ok
  defp validate_request_type(_), do: {:error, :invalid_request_type}

  defp validate_request_payload(%{payload: payload}) when is_map(payload), do: :ok
  defp validate_request_payload(_), do: {:error, :invalid_request_payload}

  defp handle_query(query, _context) do
    # Placeholder for query handling
    {:error, {:not_implemented, query}}
  end

  # Contract-compliant API (Adapter Pattern)

  # Note: init/1 and terminate/2 callbacks conflict between GenServer and Gateway.API
  # The GenServer callbacks take precedence. Gateway API init/terminate are handled
  # by start_link/1 and proper GenServer shutdown.

  @doc """
  Executes a command asynchronously via the Gateway.

  This function validates the command and, if valid, dispatches it for
  asynchronous execution. The result is an execution ID that can be used to
  track the command's progress.

  ## Parameters
  - `command` - The `Arbor.Contracts.Client.Command.t()` struct to execute.
  - `context` - A map containing execution context, primarily `:session_id`.
  - `_state` - The Gateway state (unused in this adapter function).

  ## Returns
  - `{:ok, execution_id}` - If the command was successfully dispatched.
  - `{:error, :session_not_found}` - If the session ID is missing from the context.
  - `{:error, {:invalid_command, reason}}` - If the command fails validation.
  """
  @spec execute_command(map(), map(), any()) ::
          {:ok, Types.execution_id()} | {:error, term()}
  @impl Arbor.Contracts.Gateway.API
  def execute_command(command, context, _state) do
    session_id = Map.get(context, :session_id)

    if is_nil(session_id) do
      {:error, :session_not_found}
    else
      # Validate command before starting async execution
      case Command.validate(command) do
        :ok ->
          GenServer.call(__MODULE__, {:execute_command, command, context})

        {:error, reason} ->
          {:error, {:invalid_command, reason}}
      end
    end
  end

  @doc """
  Retrieves the current status of a specific execution.

  ## Parameters
  - `execution_ref` - The ID of the execution to query.
  - `_state` - The Gateway state (unused in this adapter function).

  ## Returns
  - `{:ok, status}` - A map containing the execution's status information.
  - `{:error, :execution_not_found}` - If the execution ID does not exist.
  """
  # Note: The behavior expects reference() but we use String.t() execution IDs
  # This is an intentional design choice for distributed system compatibility
  # Dialyzer warnings are suppressed in .dialyzer_ignore.exs
  @spec get_execution_status(Types.execution_id(), any()) ::
          {:ok, map()} | {:error, :execution_not_found}
  @impl Arbor.Contracts.Gateway.API
  def get_execution_status(execution_ref, _state) do
    GenServer.call(__MODULE__, {:get_execution_status, execution_ref})
  end

  @doc """
  Cancels a running execution.

  ## Parameters
  - `execution_ref` - The ID of the execution to cancel.
  - `reason` - The reason for the cancellation.
  - `_state` - The Gateway state (unused in this adapter function).

  ## Returns
  - `:ok` - If the cancellation request was successfully processed.
  - `{:error, :execution_not_found}` - If the execution ID does not exist.
  """
  # Note: The behavior expects reference() but we use String.t() execution IDs
  # Dialyzer warnings are suppressed in .dialyzer_ignore.exs
  @spec cancel_execution(Types.execution_id(), any(), any()) ::
          :ok | {:error, :execution_not_found}
  @impl Arbor.Contracts.Gateway.API
  def cancel_execution(execution_ref, reason, _state) do
    GenServer.call(__MODULE__, {:cancel_execution, execution_ref, reason})
  end

  @doc """
  Subscribes to events for a specific target.

  Clients can subscribe to events related to sessions or executions to receive
  real-time updates. The current implementation uses `Phoenix.PubSub` and does
  not yet use the `event_types` or `subscriber` parameters.

  ## Parameters
  - `target` - The target to subscribe to, e.g., `{:session, session_id}` or `{:execution, execution_id}`.
  - `event_types` - A list of event types to subscribe to (currently unused).
  - `subscriber` - The PID of the process that will receive event messages (currently unused).
  - `_state` - The Gateway state (unused in this adapter function).

  ## Returns
  - `{:ok, subscription_ref}` - A unique reference for the new subscription.
  - `{:error, :invalid_subscription}` - If the subscription target is not valid.
  """
  @spec subscribe_events(
          target :: {:session, Types.session_id()} | {:execution, Types.execution_id()},
          event_types :: list(atom()),
          subscriber :: pid(),
          state :: any()
        ) :: {:ok, reference()} | {:error, :invalid_subscription}
  @impl Arbor.Contracts.Gateway.API
  def subscribe_events(target, event_types, subscriber, _state) do
    GenServer.call(__MODULE__, {:subscribe_events, target, event_types, subscriber})
  end

  @doc """
  Unsubscribes from events.

  Note: This is currently a placeholder and does not perform any action.

  ## Parameters
  - `subscription_ref` - The reference returned from a successful call to `subscribe_events/4`.
  - `_state` - The Gateway state (unused in this adapter function).

  ## Returns
  - `:ok` - The unsubscription was successful.
  """
  @spec unsubscribe_events(subscription_ref :: reference(), state :: any()) :: :ok
  @impl Arbor.Contracts.Gateway.API
  def unsubscribe_events(subscription_ref, _state) do
    GenServer.call(__MODULE__, {:unsubscribe_events, subscription_ref})
  end

  @doc """
  Lists the commands available within a given context.

  This is typically used to discover what operations are permitted for a
  specific session.

  ## Parameters
  - `context` - A map containing context, primarily `:session_id`.
  - `_state` - The Gateway state (unused in this adapter function).

  ## Returns
  - `{:ok, commands}` - A list of maps, where each map describes an available command.
  """
  @spec list_commands(context :: map(), state :: any()) :: {:ok, list(map())}
  @impl Arbor.Contracts.Gateway.API
  def list_commands(context, _state) do
    GenServer.call(__MODULE__, {:list_commands, context})
  end

  @doc """
  Validates a command without executing it.

  This can be used to check if a command is syntactically correct and if the
  session has the required permissions before attempting execution.

  ## Parameters
  - `command` - The `Arbor.Contracts.Client.Command.t()` struct to validate.
  - `context` - The context for validation (unused in the current implementation).
  - `_state` - The Gateway state (unused in this adapter function).

  ## Returns
  - `:ok` - If the command is valid.
  - `{:error, reason}` - If the command is invalid.
  """
  @spec validate_command(command :: Command.t(), context :: map(), state :: any()) ::
          :ok | {:error, term()}
  @impl Arbor.Contracts.Gateway.API
  def validate_command(command, context, _state) do
    GenServer.call(__MODULE__, {:validate_command, command, context})
  end

  @doc """
  Checks the health of the Gateway.

  Provides a snapshot of the Gateway's operational status, including active
  connections and performance metrics.

  ## Parameters
  - `_state` - The Gateway state (unused in this adapter function).

  ## Returns
  - `{:ok, health_info}` - A map containing health information.
  """
  @spec get_health(state :: any()) :: {:ok, map()}
  @impl Arbor.Contracts.Gateway.API
  def get_health(_state) do
    GenServer.call(__MODULE__, :get_health)
  end

  @doc """
  Checks if an operation is within the defined rate limits for a client.

  Note: This is currently a placeholder and will always return `{:ok, 1000}`.

  ## Parameters
  - `client_id` - The identifier for the client (unused).
  - `operation` - The type of operation being performed (unused).
  - `cost` - The cost of the operation (unused).
  - `_state` - The Gateway state (unused in this adapter function).

  ## Returns
  - `{:ok, remaining_quota}` - If the operation is allowed.
  - `{:error, :rate_limited}` - If the operation should be denied (not currently returned).
  """
  @spec check_rate_limit(
          client_id :: any(),
          operation :: atom(),
          cost :: non_neg_integer(),
          state :: any()
        ) :: {:ok, non_neg_integer()} | {:error, :rate_limited}
  @impl Arbor.Contracts.Gateway.API
  def check_rate_limit(client_id, operation, cost, _state) do
    GenServer.call(__MODULE__, {:check_rate_limit, client_id, operation, cost})
  end

  @doc """
  Initializes the Gateway.

  This function is part of the `Arbor.Contracts.Gateway.API` behaviour.
  The actual Gateway initialization is handled by `GenServer.start_link/1`.

  ## Parameters
  - `_opts` - A keyword list of options (unused).

  ## Returns
  - `{:ok, initial_state}` - An empty map representing the initial state.
  """
  @spec initialize_gateway(opts :: keyword()) :: {:ok, map()}
  @impl Arbor.Contracts.Gateway.API
  def initialize_gateway(_opts) do
    # Gateway initialization is handled by GenServer.start_link/3
    {:ok, %{}}
  end

  @doc """
  Shuts down the Gateway.

  This function is part of the `Arbor.Contracts.Gateway.API` behaviour.
  The actual Gateway shutdown is handled by the `GenServer.terminate/2` callback.

  ## Parameters
  - `_reason` - The reason for shutdown (unused).
  - `_state` - The current Gateway state (unused).

  ## Returns
  - `:ok`
  """
  @spec shutdown_gateway(reason :: any(), state :: any()) :: :ok
  @impl Arbor.Contracts.Gateway.API
  def shutdown_gateway(_reason, _state) do
    # Gateway shutdown is handled by GenServer termination
    :ok
  end

  # Legacy Client API (for backward compatibility)

  @doc """
  Start the Gateway process.

  ## Options

  - `:name` - Process name (defaults to module name)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  @impl true
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Create a new session for client interaction.

  Sessions provide isolation and context for client operations. Each session
  maintains its own security context, execution history, and event subscriptions.

  ## Parameters

  - `opts` - Session creation options

  ## Options

  - `:metadata` - Arbitrary metadata about the session
  - `:client_type` - Type of client (`:cli`, `:web`, `:api`, etc.)
  - `:security_context` - Initial security context

  ## Returns

  - `{:ok, session_id}` - Session created successfully
  - `{:error, reason}` - Session creation failed

  ## Examples

      {:ok, session_id} = Gateway.create_session(
        metadata: %{user_id: "user123", client_type: :cli}
      )
  """
  @spec create_session(keyword()) :: {:ok, Types.session_id()} | {:error, term()}
  def create_session(opts \\ []) do
    GenServer.call(__MODULE__, {:create_session, opts})
  end

  @doc """
  Discover capabilities available to a session.

  Returns a list of capabilities that the session can access based on its
  security context and current permissions.

  ## Parameters

  - `session_id` - Session identifier

  ## Returns

  - `{:ok, [capability_info()]}` - List of available capabilities
  - `{:error, reason}` - Discovery failed

  ## Examples

      {:ok, capabilities} = Gateway.discover_capabilities(session_id)

      Enum.each(capabilities, fn capability ->
        IO.puts("\#{capability.name}: \#{capability.description}")
      end)
  """
  @spec discover_capabilities(Types.session_id()) :: {:ok, [capability_info()]} | {:error, term()}
  def discover_capabilities(session_id) do
    GenServer.call(__MODULE__, {:discover_capabilities, session_id})
  end

  @doc """
  Execute a command asynchronously (legacy interface).

  Use execute_command/3 instead for contract compliance.
  """
  @deprecated "Use execute_command/3 instead"
  @spec execute(Types.session_id(), String.t(), map()) ::
          {:async, Types.execution_id()} | {:error, term()}
  def execute(session_id, command_name, params) do
    command = %{type: String.to_atom(command_name), params: params}
    context = %{session_id: session_id}

    case execute_command(command, context, nil) do
      {:ok, execution_ref} -> {:async, execution_ref}
      error -> error
    end
  end

  @doc """
  Get the status of an execution.
  """
  @spec get_execution_status(Types.execution_id()) :: {:ok, map()} | {:error, term()}
  def get_execution_status(execution_ref) do
    GenServer.call(__MODULE__, {:get_execution_status, execution_ref})
  end

  @doc """
  Subscribe to execution events for real-time progress updates.

  ## Parameters

  - `execution_id` - Execution identifier to subscribe to

  ## Returns

  - `:ok` - Subscription successful
  - `{:error, reason}` - Subscription failed

  ## Examples

      Gateway.subscribe_execution(execution_id)

      # Will receive messages like:
      # {:execution_event, %{status: :started, message: "Beginning analysis..."}}
      # {:execution_event, %{status: :progress, progress: 25, message: "Analyzing files..."}}
      # {:execution_event, %{status: :completed, result: %{...}}}
  """
  @spec subscribe_execution(Types.execution_id()) :: :ok | {:error, term()}
  def subscribe_execution(execution_id) do
    Phoenix.PubSub.subscribe(Arbor.Core.PubSub, "execution:#{execution_id}")
  end

  @doc """
  Subscribe to session events.

  ## Parameters

  - `session_id` - Session identifier to subscribe to

  ## Returns

  - `:ok` - Subscription successful
  - `{:error, reason}` - Subscription failed
  """
  @spec subscribe_session(Types.session_id()) :: :ok | {:error, term()}
  def subscribe_session(session_id) do
    Phoenix.PubSub.subscribe(Arbor.Core.PubSub, "session:#{session_id}")
  end

  @doc """
  End a session and clean up resources.

  ## Parameters

  - `session_id` - Session to terminate

  ## Returns

  - `:ok` - Session ended successfully
  - `{:error, reason}` - Session termination failed
  """
  @spec end_session(Types.session_id()) :: :ok | {:error, term()}
  def end_session(session_id) do
    GenServer.call(__MODULE__, {:end_session, session_id})
  end

  @doc """
  Get current Gateway statistics.

  Returns information about active sessions, executions, and performance metrics.

  ## Returns

  - `{:ok, stats}` - Current statistics
  """
  @spec get_stats() :: {:ok, map()}
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    Logger.info("Starting Arbor Gateway", opts: opts)

    # Subscribe to system events
    Phoenix.PubSub.subscribe(Arbor.Core.PubSub, "system")

    # Initialize telemetry
    :telemetry.execute([:arbor, :gateway, :start], %{count: 1}, %{node: Node.self()})

    {:ok,
     %{
       sessions: %{},
       active_executions: %{},
       completed_executions: %{},
       stats: %{
         sessions_created: 0,
         commands_executed: 0,
         start_time: DateTime.utc_now()
       }
     }}
  end

  @impl true
  def handle_call({:create_session, opts}, _from, state) do
    # Transform opts to session_params format for new API
    session_params = %{
      user_id: opts[:created_by] || "gateway_user",
      purpose: Map.get(opts[:metadata] || %{}, :purpose, "Gateway session"),
      timeout: opts[:timeout] || 3_600_000,
      context: opts[:metadata] || %{}
    }

    case SessionManager.create_session(session_params, SessionManager) do
      {:ok, session_struct} ->
        session_id = session_struct.id

        # Track session in gateway state
        new_sessions =
          Map.put(state.sessions, session_id, %{
            created_at: DateTime.utc_now(),
            metadata: opts[:metadata] || %{}
          })

        # Update stats
        new_stats = Map.update!(state.stats, :sessions_created, &(&1 + 1))

        # Emit telemetry
        :telemetry.execute(
          [:arbor, :gateway, :session, :created],
          %{count: 1},
          %{session_id: session_id}
        )

        Logger.info("Session created via Gateway", session_id: session_id)

        # Return session info map for CLI compatibility
        session_info = %{
          session_id: session_id,
          created_at: session_struct.created_at,
          capabilities: session_struct.capabilities,
          metadata: opts[:metadata] || %{}
        }

        {:reply, {:ok, session_info}, %{state | sessions: new_sessions, stats: new_stats}}

      {:error, reason} = error ->
        Logger.error("Failed to create session", reason: reason)
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:discover_capabilities, session_id}, _from, state) do
    start_time = System.monotonic_time()

    case get_authorized_capabilities(session_id) do
      {:ok, capabilities} ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:arbor, :gateway, :capability, :discovery],
          %{duration: duration, capabilities_found: length(capabilities)},
          %{session_id: session_id}
        )

        {:reply, {:ok, capabilities}, state}

        # Note: get_authorized_capabilities currently always returns {:ok, capabilities}
        # This error case is included for future implementation when it might fail
    end
  end

  @impl true
  def handle_call({:execute_command, command, context}, _from, state) do
    session_id = Map.get(context, :session_id)
    command_type = Map.get(command, :type)
    params = Map.get(command, :params, %{})

    execution_id = Identifiers.generate_execution_id()

    # Start async execution
    task =
      Task.Supervisor.async_nolink(Arbor.TaskSupervisor, fn ->
        execute_command_task(session_id, command_type, params, execution_id)
      end)

    # Track execution
    new_executions =
      Map.put(state.active_executions, execution_id, %{
        session_id: session_id,
        command: command_type,
        params: params,
        task: task,
        started_at: DateTime.utc_now(),
        waiters: []
      })

    # Update stats
    new_stats = Map.update!(state.stats, :commands_executed, &(&1 + 1))

    # Emit telemetry
    :telemetry.execute(
      [:arbor, :gateway, :command, :started],
      %{count: 1},
      %{session_id: session_id, command: command_type, execution_id: execution_id}
    )

    # Broadcast start event
    broadcast_execution_event(execution_id, session_id, :started, "Command execution started")

    Logger.info("Command execution started",
      session_id: session_id,
      command: command_type,
      execution_id: execution_id
    )

    # Return contract-compliant response
    {:reply, {:ok, execution_id}, %{state | active_executions: new_executions, stats: new_stats}}
  end

  @impl true
  def handle_call({:execute, session_id, command, params}, _from, state) do
    execution_id = Identifiers.generate_execution_id()

    # Start async execution
    task =
      Task.Supervisor.async_nolink(Arbor.TaskSupervisor, fn ->
        execute_command_task(session_id, command, params, execution_id)
      end)

    # Track execution
    new_executions =
      Map.put(state.active_executions, execution_id, %{
        session_id: session_id,
        command: command,
        params: params,
        task: task,
        started_at: DateTime.utc_now(),
        waiters: []
      })

    # Update stats
    new_stats = Map.update!(state.stats, :commands_executed, &(&1 + 1))

    # Emit telemetry
    :telemetry.execute(
      [:arbor, :gateway, :command, :started],
      %{count: 1},
      %{session_id: session_id, command: command, execution_id: execution_id}
    )

    # Broadcast start event
    broadcast_execution_event(execution_id, session_id, :started, "Command execution started")

    Logger.info("Command execution started",
      session_id: session_id,
      command: command,
      execution_id: execution_id
    )

    {:reply, {:async, execution_id},
     %{state | active_executions: new_executions, stats: new_stats}}
  end

  @impl true
  def handle_call({:end_session, session_id}, _from, state) do
    case SessionManager.end_session(session_id) do
      :ok ->
        # Remove from gateway tracking
        new_sessions = Map.delete(state.sessions, session_id)

        # Clean up any active executions for this session
        new_executions =
          state.active_executions
          |> Enum.reject(fn {_exec_id, exec_info} ->
            exec_info.session_id == session_id
          end)
          |> Map.new()

        Logger.info("Session ended via Gateway", session_id: session_id)

        {:reply, :ok, %{state | sessions: new_sessions, active_executions: new_executions}}

      {:error, reason} = error ->
        Logger.error("Failed to end session", session_id: session_id, reason: reason)
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        active_sessions: map_size(state.sessions),
        active_executions: map_size(state.active_executions),
        uptime_seconds: DateTime.diff(DateTime.utc_now(), state.stats.start_time)
      })

    {:reply, {:ok, stats}, state}
  end

  # Contract-compliant handle_call clauses

  @impl true
  def handle_call({:get_execution_status, execution_ref}, _from, state) do
    case Map.get(state.active_executions, execution_ref) do
      nil ->
        {:reply, {:error, :execution_not_found}, state}

      exec_info ->
        status = %{
          status: :executing,
          progress: nil,
          result: nil,
          error: nil,
          events: [],
          started_at: exec_info.started_at,
          completed_at: nil
        }

        {:reply, {:ok, status}, state}
    end
  end

  @impl true
  def handle_call({:cancel_execution, execution_ref, reason}, _from, state) do
    case Map.get(state.active_executions, execution_ref) do
      nil ->
        {:reply, {:error, :execution_not_found}, state}

      exec_info ->
        # Cancel the task
        Task.shutdown(exec_info.task, :brutal_kill)

        # Remove from active executions
        new_executions = Map.delete(state.active_executions, execution_ref)

        # Broadcast cancellation
        broadcast_execution_event(
          execution_ref,
          exec_info.session_id,
          :cancelled,
          "Execution cancelled: #{reason}"
        )

        {:reply, :ok, %{state | active_executions: new_executions}}
    end
  end

  @impl true
  def handle_call({:wait_for_completion, execution_ref}, from, state) do
    case Map.get(state.active_executions, execution_ref) do
      nil ->
        handle_completed_execution_lookup(execution_ref, state)

      exec_info ->
        # Execution is active. Add caller to waiters list and don't reply yet.
        new_exec_info =
          Map.update(exec_info, :waiters, [from], fn existing_waiters ->
            [from | existing_waiters]
          end)

        new_active_executions = Map.put(state.active_executions, execution_ref, new_exec_info)
        {:noreply, %{state | active_executions: new_active_executions}}
    end
  end

  @impl true
  def handle_call({:subscribe_events, target, _event_types, _subscriber}, _from, state) do
    # For now, delegate to Phoenix.PubSub for basic event subscription
    case target do
      {:session, session_id} ->
        _result = Phoenix.PubSub.subscribe(Arbor.Core.PubSub, "session:#{session_id}")
        subscription_ref = make_ref()
        {:reply, {:ok, subscription_ref}, state}

      {:execution, execution_id} ->
        _result = Phoenix.PubSub.subscribe(Arbor.Core.PubSub, "execution:#{execution_id}")
        subscription_ref = make_ref()
        {:reply, {:ok, subscription_ref}, state}

      _ ->
        {:reply, {:error, :invalid_subscription}, state}
    end
  end

  @impl true
  def handle_call({:unsubscribe_events, _subscription_ref}, _from, state) do
    # For now, this is a placeholder since we need to track subscriptions properly
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:list_commands, context}, _from, state) do
    # Delegate to existing capability discovery
    session_id = Map.get(context, :session_id)

    case get_authorized_capabilities(session_id) do
      {:ok, capabilities} ->
        # Transform capabilities to command specs format
        commands =
          Enum.map(capabilities, fn cap ->
            %{
              type: String.to_atom(cap.name),
              description: cap.description,
              params: cap.parameters,
              required_capabilities: cap.required_permissions,
              # Could be expanded later
              examples: []
            }
          end)

        {:reply, {:ok, commands}, state}
    end
  end

  @impl true
  def handle_call({:validate_command, command, _context}, _from, state) do
    case Command.validate(command) do
      :ok ->
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_health, _from, state) do
    health = %{
      status: :healthy,
      active_executions: map_size(state.active_executions),
      # We don't queue commands currently
      queued_commands: 0,
      # Would need proper tracking
      subscriptions: 0,
      # Not implemented yet
      rate_limit_status: %{},
      # Would need metrics collection
      latency_ms: [],
      # Would need error tracking
      error_rate: 0.0
    }

    {:reply, {:ok, health}, state}
  end

  @impl true
  def handle_call({:check_rate_limit, _client_id, _operation, _cost}, _from, state) do
    # Placeholder implementation - rate limiting not implemented yet
    # Assume plenty of quota
    remaining = 1000
    {:reply, {:ok, remaining}, state}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    # Task completion
    Process.demonitor(ref, [:flush])

    case find_execution_by_task_ref(ref, state.active_executions) do
      {execution_id, exec_info} ->
        handle_execution_result(execution_id, exec_info, result, state)

      nil ->
        Logger.warning("Received result for unknown execution", ref: ref)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    # Task failure
    case find_execution_by_task_ref(ref, state.active_executions) do
      {execution_id, exec_info} ->
        handle_execution_failure(execution_id, exec_info, reason, state)

      nil ->
        Logger.warning("Received DOWN for unknown execution", ref: ref, reason: reason)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:session_ended, session_id, reason}, state) do
    # Session ended externally, clean up gateway state
    new_sessions = Map.delete(state.sessions, session_id)
    Logger.info("Session ended externally", session_id: session_id, reason: reason)
    {:noreply, %{state | sessions: new_sessions}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Gateway received unexpected message", message: msg)
    {:noreply, state}
  end

  # Private functions

  defp get_supervisor_impl do
    case Application.get_env(:arbor_core, :supervisor_impl, :auto) do
      :mock ->
        Arbor.Test.Mocks.SupervisorMock

      :horde ->
        Arbor.Core.HordeSupervisor

      :auto ->
        if Application.get_env(:arbor_core, :env, :prod) == :test do
          Arbor.Test.Mocks.SupervisorMock
        else
          Arbor.Core.HordeSupervisor
        end

      module when is_atom(module) ->
        # Direct module injection for Mox testing
        module
    end
  end

  defp get_authorized_capabilities(_session_id) do
    # For now, return a basic set of capabilities
    # In production, this would check the session's security context
    # and filter capabilities based on permissions
    capabilities = [
      %{
        name: "analyze_code",
        description: "Analyze code for issues and improvements",
        parameters: [
          %{name: "path", type: :string, required: true, description: "Path to analyze"},
          %{name: "language", type: :string, required: false, description: "Programming language"}
        ],
        required_permissions: ["arbor://fs/read/"]
      },
      %{
        name: "execute_tool",
        description: "Execute a specific tool",
        parameters: [
          %{
            name: "tool_name",
            type: :string,
            required: true,
            description: "Name of tool to execute"
          },
          %{name: "args", type: :map, required: false, description: "Tool arguments"}
        ],
        required_permissions: ["arbor://tool/execute/"]
      },
      %{
        name: "query_agents",
        description: "Query information about active agents",
        parameters: [
          %{name: "filter", type: :map, required: false, description: "Agent filters"}
        ],
        required_permissions: ["arbor://agent/list/"]
      },
      %{
        name: "spawn_agent",
        description: "Spawn a new agent",
        parameters: [
          %{
            name: "type",
            type: :atom,
            required: true,
            description: "Type of agent to spawn (e.g., :code_analyzer)"
          },
          %{
            name: "id",
            type: :string,
            required: false,
            description: "Optional unique ID for the agent"
          },
          %{
            name: "working_dir",
            type: :string,
            required: false,
            description: "Working directory for the agent"
          }
        ],
        required_permissions: ["arbor://agent/spawn/"]
      },
      %{
        name: "get_agent_status",
        description: "Get status of a specific agent",
        parameters: [
          %{name: "agent_id", type: :string, required: true, description: "Agent ID to query"}
        ],
        required_permissions: ["arbor://agent/status/"]
      },
      %{
        name: "execute_agent_command",
        description: "Execute a command on a specific agent",
        parameters: [
          %{name: "agent_id", type: :string, required: true, description: "Agent ID to command"},
          %{name: "command", type: :string, required: true, description: "Command to execute"},
          %{name: "args", type: :list, required: false, description: "Command arguments"}
        ],
        required_permissions: ["arbor://agent/exec/"]
      }
    ]

    {:ok, capabilities}
  end

  defp execute_command_task(session_id, command, params, execution_id) do
    Logger.info("Executing command",
      command: command,
      session_id: session_id,
      execution_id: execution_id
    )

    try do
      # Broadcast progress
      broadcast_execution_event(execution_id, session_id, :progress, "Processing command...", 25)

      # Execute the command
      result = dispatch_command(command, params)

      # Handle result and broadcast completion
      handle_command_result(result, execution_id, session_id, command)

      result
    rescue
      e ->
        error = {:exception, Exception.format(:error, e, __STACKTRACE__)}

        broadcast_execution_event(
          execution_id,
          session_id,
          :failed,
          "Command failed with exception",
          nil,
          nil,
          error
        )

        {:error, error}
    end
  end

  # Helper functions for execute_command_task complexity reduction

  defp dispatch_command(command, params) do
    # Normalize command to atom if it's a string (for backward compatibility)
    normalized_command = normalize_command(command)
    execute_normalized_command(normalized_command, params)
  end

  defp normalize_command(command) when is_atom(command), do: command
  defp normalize_command("analyze_code"), do: :analyze_code
  defp normalize_command("execute_tool"), do: :execute_tool
  defp normalize_command("query_agents"), do: :query_agents
  defp normalize_command(command), do: command

  defp execute_normalized_command(command, params) do
    case command do
      :analyze_code -> handle_code_analysis(params)
      :execute_tool -> handle_tool_execution(params)
      :query_agents -> handle_agent_query(params)
      :spawn_agent -> handle_agent_spawn(params)
      :get_agent_status -> handle_agent_status(params)
      :execute_agent_command -> handle_agent_command_execution(params)
      _ -> {:error, {:unknown_command, command}}
    end
  end

  defp handle_command_result(result, execution_id, session_id, command) do
    case result do
      {:ok, data} ->
        broadcast_execution_event(
          execution_id,
          session_id,
          :completed,
          "Command completed successfully",
          100,
          data
        )

        :telemetry.execute(
          [:arbor, :gateway, :command, :completed],
          # Would be actual duration
          %{duration: 1000},
          %{session_id: session_id, command: command, execution_id: execution_id}
        )

      {:error, reason} ->
        broadcast_execution_event(
          execution_id,
          session_id,
          :failed,
          "Command failed",
          nil,
          nil,
          reason
        )

        :telemetry.execute(
          [:arbor, :gateway, :command, :failed],
          %{count: 1},
          %{
            session_id: session_id,
            command: command,
            execution_id: execution_id,
            reason: reason
          }
        )
    end
  end

  defp handle_code_analysis(params) do
    # Simulate code analysis
    path = params["path"] || params[:path]
    language = params["language"] || params[:language] || "unknown"

    if path do
      {:ok,
       %{
         path: path,
         language: language,
         issues_found: 3,
         suggestions: [
           "Use more descriptive variable names",
           "Add error handling",
           "Consider performance optimization"
         ],
         metrics: %{
           lines_of_code: 150,
           complexity_score: 7.2,
           test_coverage: 85.5
         }
       }}
    else
      {:error, :missing_path_parameter}
    end
  end

  defp handle_tool_execution(params) do
    tool_name = params["tool_name"] || params[:tool_name]

    if tool_name do
      {:ok,
       %{
         tool: tool_name,
         status: "executed",
         output: "Tool execution completed successfully",
         duration_ms: 1250
       }}
    else
      {:error, :missing_tool_name}
    end
  end

  defp handle_agent_query(params) do
    # Use the distributed registry to query agents
    raw_filter = params["filter"] || params[:filter] || %{}

    # Parse filter if it's a string
    filter = parse_filter(raw_filter)

    # Get all agents from the registry
    case ClusterRegistry.list_all_agents() do
      {:ok, all_agents} ->
        # Filter agents based on the provided filter
        filtered_agents = filter_agents(all_agents, filter)

        # Transform to response format
        agent_info =
          Enum.map(filtered_agents, fn {agent_id, _pid, metadata} ->
            %{
              id: agent_id,
              type: metadata[:type] || :unknown,
              # All registered agents are active
              status: :active,
              capabilities: metadata[:capabilities] || [],
              node: metadata[:node] || node()
            }
          end)

        {:ok,
         %{
           agents: agent_info,
           total_agents: length(agent_info)
         }}

      {:error, reason} ->
        Logger.error("Failed to query agents from registry", reason: reason)
        # Return empty result on error
        {:ok, %{agents: [], total_agents: 0}}
    end
  end

  defp parse_filter(filter) when is_binary(filter) do
    # Parse string filters like "type:tool_executor"
    case String.split(filter, ":", parts: 2) do
      [key, value] ->
        # Convert key and value to appropriate types
        %{String.to_atom(key) => String.to_atom(value)}

      _ ->
        # Invalid format, return empty filter
        %{}
    end
  end

  defp parse_filter(filter) when is_map(filter), do: filter
  defp parse_filter(_), do: %{}

  defp filter_agents(agents, filter) when map_size(filter) == 0, do: agents

  defp filter_agents(agents, filter) do
    Enum.filter(agents, fn {_agent_id, _pid, metadata} ->
      Enum.all?(filter, fn {key, value} ->
        metadata[key] == value
      end)
    end)
  end

  defp broadcast_execution_event(
         execution_id,
         session_id,
         status,
         message,
         progress \\ nil,
         result \\ nil,
         error \\ nil
       ) do
    event = %{
      execution_id: execution_id,
      session_id: session_id,
      status: status,
      progress: progress,
      message: message,
      result: result,
      error: error,
      timestamp: DateTime.utc_now()
    }

    Phoenix.PubSub.broadcast(
      Arbor.Core.PubSub,
      "execution:#{execution_id}",
      {:execution_event, event}
    )

    Phoenix.PubSub.broadcast(
      Arbor.Core.PubSub,
      "session:#{session_id}",
      {:execution_event, event}
    )
  end

  defp find_execution_by_task_ref(ref, executions) do
    Enum.find_value(executions, fn {exec_id, exec_info} ->
      if exec_info.task.ref == ref do
        {exec_id, exec_info}
      else
        nil
      end
    end)
  end

  defp handle_execution_result(execution_id, exec_info, result, state) do
    Logger.info("Execution completed",
      execution_id: execution_id,
      session_id: exec_info.session_id,
      result: result
    )

    # Reply to any waiting processes
    data = unwrap_result_data(result)

    completion_result = %{
      execution_id: execution_id,
      status: :completed,
      result: %{
        data: data,
        message: "Command completed successfully"
      }
    }

    for from <- Map.get(exec_info, :waiters, []) do
      GenServer.reply(from, {:ok, completion_result})
    end

    # Move to completed executions instead of deleting
    completed_info =
      exec_info
      |> Map.put(:result, result)
      |> Map.put(:completed_at, DateTime.utc_now())
      |> Map.delete(:waiters)

    # Remove from active and add to completed
    new_active = Map.delete(state.active_executions, execution_id)
    new_completed = Map.put(state.completed_executions, execution_id, completed_info)

    # Clean up old completed executions (older than 5 minutes)
    cutoff = DateTime.add(DateTime.utc_now(), -300, :second)

    new_completed =
      Enum.reduce(new_completed, %{}, fn {id, info}, acc ->
        if DateTime.compare(info.completed_at, cutoff) == :gt do
          Map.put(acc, id, info)
        else
          acc
        end
      end)

    {:noreply, %{state | active_executions: new_active, completed_executions: new_completed}}
  end

  defp handle_execution_failure(execution_id, exec_info, reason, state) do
    Logger.error("Execution failed",
      execution_id: execution_id,
      session_id: exec_info.session_id,
      reason: reason
    )

    # Reply to any waiting processes
    for from <- Map.get(exec_info, :waiters, []) do
      GenServer.reply(from, {:error, reason})
    end

    # Broadcast failure event
    broadcast_execution_event(
      execution_id,
      exec_info.session_id,
      :failed,
      "Execution failed unexpectedly",
      nil,
      nil,
      reason
    )

    # Move to completed executions with error instead of deleting
    completed_info =
      exec_info
      |> Map.put(:error, reason)
      |> Map.put(:completed_at, DateTime.utc_now())
      |> Map.delete(:waiters)

    # Remove from active and add to completed
    new_active = Map.delete(state.active_executions, execution_id)
    new_completed = Map.put(state.completed_executions, execution_id, completed_info)

    {:noreply, %{state | active_executions: new_active, completed_executions: new_completed}}
  end

  # Agent Management Handlers

  defp handle_agent_spawn(params) do
    agent_type = params["type"] || params[:type]
    agent_id = params["id"] || params[:id] || generate_agent_id(agent_type)
    working_dir = params["working_dir"] || params[:working_dir] || "/tmp"

    spawn_agent_by_type(agent_type, agent_id, working_dir)
  end

  # Helper functions for handle_agent_spawn complexity reduction

  defp generate_agent_id(agent_type) do
    "#{agent_type}_#{System.unique_integer([:positive])}"
  end

  defp spawn_agent_by_type(agent_type, agent_id, working_dir) do
    case agent_type do
      :code_analyzer ->
        spawn_code_analyzer_agent(agent_id, working_dir)

      "code_analyzer" ->
        # Handle string type for backward compatibility
        spawn_code_analyzer_agent(agent_id, working_dir)

      _ ->
        {:error, {:unsupported_agent_type, agent_type}}
    end
  end

  defp spawn_code_analyzer_agent(agent_id, working_dir) do
    agent_spec = %{
      id: agent_id,
      module: CodeAnalyzer,
      args: [agent_id: agent_id, working_dir: working_dir],
      restart_strategy: :permanent
    }

    supervisor_impl = get_supervisor_impl()

    case supervisor_impl.start_agent(agent_spec) do
      {:ok, pid} ->
        {:ok,
         %{
           agent_id: agent_id,
           agent_type: :code_analyzer,
           pid: inspect(pid),
           working_dir: working_dir,
           status: :active
         }}

      {:error, reason} ->
        {:error, {:agent_spawn_failed, reason}}
    end
  end

  defp handle_agent_status(params) do
    agent_id = params["agent_id"] || params[:agent_id]

    if agent_id do
      supervisor_impl = get_supervisor_impl()

      case supervisor_impl.get_agent_info(agent_id) do
        {:ok, agent_info} ->
          # Return list format to match query format and test expectations
          agent_data = %{
            agent_id: agent_id,
            status: if(Process.alive?(agent_info.pid), do: :active, else: :inactive)
          }

          {:ok, %{agents: [agent_data], total: 1}}

        {:error, :not_found} ->
          # Return empty list format for non-existent agents (matches test expectation)
          {:ok, %{agents: [], total: 0}}

        {:error, reason} ->
          {:error, {:agent_status_failed, reason}}
      end
    else
      {:error, :missing_agent_id}
    end
  end

  defp handle_agent_command_execution(params) do
    with {:ok, {agent_id, command, args}} <- validate_agent_command_params(params),
         {:ok, _agent_id} <- lookup_target_agent(agent_id),
         {:ok, result} <- execute_command_on_agent(agent_id, command, args) do
      response = format_agent_command_response(agent_id, command, args, result)
      {:ok, response}
    else
      error -> handle_agent_command_errors(error)
    end
  end

  defp validate_agent_command_params(params) do
    {agent_id, command, args} = extract_command_params(params)

    with :ok <- check_missing_params(agent_id, command),
         :ok <- check_agent_id_type(agent_id) do
      {:ok, {agent_id, command, args}}
    end
  end

  defp extract_command_params(params) do
    agent_id = params["agent_id"] || params[:agent_id]
    command = params["command"] || params[:command]
    args = params["args"] || params[:args] || []
    {agent_id, command, args}
  end

  defp check_missing_params(agent_id, command) do
    missing =
      []
      |> add_if_missing(agent_id, :agent_id)
      |> add_if_missing(command, :command)

    if Enum.empty?(missing) do
      :ok
    else
      {:error, {:missing_params, missing}}
    end
  end

  defp add_if_missing(list, value, key) do
    if is_nil(value), do: [key | list], else: list
  end

  defp check_agent_id_type(agent_id) when is_binary(agent_id), do: :ok
  defp check_agent_id_type(_agent_id), do: {:error, :invalid_agent_id}

  defp lookup_target_agent(agent_id) do
    case Arbor.Core.HordeRegistry.lookup_agent_name(agent_id) do
      {:ok, _pid, _metadata} ->
        # We don't need pid or metadata, just confirmation of registration
        {:ok, agent_id}

      {:error, :not_registered} ->
        {:error, :agent_not_found}
    end
  end

  defp execute_command_on_agent(agent_id, command, args) do
    CodeAnalyzer.exec(agent_id, command, args)
  rescue
    e -> {:error, {:agent_command_failed, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:agent_command_failed, reason}}
  end

  defp format_agent_command_response(agent_id, command, args, result) do
    %{
      agent_id: agent_id,
      command: command,
      args: args,
      result: result
    }
  end

  defp handle_agent_command_errors({:error, _reason} = error) do
    # This function centralizes error handling for the agent command execution flow.
    # For now, it passes the error through, but can be used for logging or transformation.
    error
  end

  # Helper functions for handle_call complexity reduction

  defp handle_completed_execution_lookup(execution_ref, state) do
    case Map.get(state.completed_executions, execution_ref) do
      nil ->
        Logger.error("Failed to wait for completion",
          execution_id: execution_ref,
          reason: :execution_not_found
        )

        {:reply, {:error, :execution_not_found}, state}

      completed_info ->
        # Return the completed result, unwrapping :ok tuples
        data = unwrap_result_data(completed_info.result)

        completion_result = %{
          execution_id: execution_ref,
          status: :completed,
          result: %{
            data: data,
            message: "Command completed successfully"
          }
        }

        # Remove from completed executions after retrieval
        new_completed = Map.delete(state.completed_executions, execution_ref)
        {:reply, {:ok, completion_result}, %{state | completed_executions: new_completed}}
    end
  end

  defp unwrap_result_data({:ok, data}), do: data
  defp unwrap_result_data(data), do: data
end
