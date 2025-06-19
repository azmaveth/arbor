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

  use GenServer
  require Logger

  alias Arbor.Contracts.Core.{Capability, Message}
  alias Arbor.Core.{Security, Sessions}
  alias Arbor.Types

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

  # Client API

  @doc """
  Start the Gateway process.

  ## Options

  - `:name` - Process name (defaults to module name)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
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
  Execute a command asynchronously.

  Commands are executed asynchronously with progress tracking via events.
  Clients can subscribe to execution events to receive real-time updates.

  ## Parameters

  - `session_id` - Session identifier
  - `command` - Command name to execute
  - `params` - Command parameters

  ## Returns

  - `{:async, execution_id}` - Command started, returns execution ID for tracking
  - `{:error, reason}` - Command execution failed to start

  ## Examples

      # Start command execution
      {:async, exec_id} = Gateway.execute(session_id, "analyze_code", %{
        path: "/project/src",
        language: "elixir"
      })

      # Subscribe to progress events
      Gateway.subscribe_execution(exec_id)
  """
  @spec execute(Types.session_id(), String.t(), map()) ::
          {:async, Types.execution_id()} | {:error, term()}
  def execute(session_id, command, params) do
    GenServer.call(__MODULE__, {:execute, session_id, command, params})
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
    Phoenix.PubSub.subscribe(Arbor.PubSub, "execution:#{execution_id}")
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
    Phoenix.PubSub.subscribe(Arbor.PubSub, "session:#{session_id}")
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
    Phoenix.PubSub.subscribe(Arbor.PubSub, "system")

    # Initialize telemetry
    :telemetry.execute([:arbor, :gateway, :start], %{count: 1}, %{node: Node.self()})

    {:ok,
     %{
       sessions: %{},
       active_executions: %{},
       stats: %{
         sessions_created: 0,
         commands_executed: 0,
         start_time: DateTime.utc_now()
       }
     }}
  end

  @impl true
  def handle_call({:create_session, opts}, _from, state) do
    case Sessions.Manager.create_session(opts) do
      {:ok, session_id, _pid} ->
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

        {:reply, {:ok, session_id}, %{state | sessions: new_sessions, stats: new_stats}}

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
  def handle_call({:execute, session_id, command, params}, _from, state) do
    execution_id = Types.generate_execution_id()

    # Start async execution
    task =
      Task.Supervisor.async_nolink(Arbor.TaskSupervisor, fn ->
        execute_command(session_id, command, params, execution_id)
      end)

    # Track execution
    new_executions =
      Map.put(state.active_executions, execution_id, %{
        session_id: session_id,
        command: command,
        params: params,
        task: task,
        started_at: DateTime.utc_now()
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
    case Sessions.Manager.end_session(session_id) do
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
      }
    ]

    {:ok, capabilities}
  end

  defp execute_command(session_id, command, params, execution_id) do
    Logger.info("Executing command",
      command: command,
      session_id: session_id,
      execution_id: execution_id
    )

    try do
      # Broadcast progress
      broadcast_execution_event(execution_id, session_id, :progress, "Processing command...", 25)

      # Simulate command execution
      # In production, this would delegate to appropriate agents
      result =
        case command do
          "analyze_code" ->
            simulate_code_analysis(params)

          "execute_tool" ->
            simulate_tool_execution(params)

          "query_agents" ->
            simulate_agent_query(params)

          _ ->
            {:error, {:unknown_command, command}}
        end

      # Broadcast completion
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

  defp simulate_code_analysis(params) do
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

  defp simulate_tool_execution(params) do
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

  defp simulate_agent_query(_params) do
    {:ok,
     %{
       agents: [
         %{id: "agent_001", type: :coordinator, status: :active, tasks: 2},
         %{id: "agent_002", type: :tool_executor, status: :active, tasks: 1},
         %{id: "agent_003", type: :llm, status: :idle, tasks: 0}
       ],
       total_agents: 3
     }}
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

    Phoenix.PubSub.broadcast(Arbor.PubSub, "execution:#{execution_id}", {:execution_event, event})
    Phoenix.PubSub.broadcast(Arbor.PubSub, "session:#{session_id}", {:execution_event, event})
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

    # Remove from active executions
    new_executions = Map.delete(state.active_executions, execution_id)

    {:noreply, %{state | active_executions: new_executions}}
  end

  defp handle_execution_failure(execution_id, exec_info, reason, state) do
    Logger.error("Execution failed",
      execution_id: execution_id,
      session_id: exec_info.session_id,
      reason: reason
    )

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

    # Remove from active executions
    new_executions = Map.delete(state.active_executions, execution_id)

    {:noreply, %{state | active_executions: new_executions}}
  end
end
