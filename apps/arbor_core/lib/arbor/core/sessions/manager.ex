defmodule Arbor.Core.Sessions.Manager do
  @moduledoc """
  Manages session lifecycle and provides session discovery.

  The Session Manager is responsible for:
  - Creating and terminating sessions
  - Tracking active sessions across the cluster
  - Providing session discovery and lookup
  - Managing session metadata and state
  - Broadcasting session lifecycle events

  Sessions provide the context for client interactions with the Arbor system.
  Each session maintains its own security context, execution history, and
  event subscriptions, providing isolation between different clients or
  user interactions.

  ## Session Lifecycle

  1. **Creation**: Client requests session via Gateway
  2. **Active**: Session processes commands and manages agents
  3. **Termination**: Session ends normally or due to timeout/error
  4. **Cleanup**: Resources are cleaned up and events broadcasted

  ## Clustering

  Sessions are tracked using Horde for cluster-wide visibility and
  automatic failover. When a node fails, sessions can be migrated
  to other nodes to maintain continuity.

  ## Usage

      # Create a session
      {:ok, session_id, pid} = Manager.create_session(
        metadata: %{user_id: "user123", client_type: :cli}
      )

      # Get session information
      {:ok, pid, metadata} = Manager.get_session(session_id)

      # List all sessions
      sessions = Manager.list_sessions()

      # End a session
      :ok = Manager.end_session(session_id)
  """

  @behaviour Arbor.Contracts.Session.Manager

  use GenServer
  require Logger

  alias Arbor.Core.{ClusterSupervisor, SessionRegistry}
  alias Arbor.Core.Sessions.Session
  alias Arbor.Types

  # Removed @table - using Horde.Registry instead

  # Contract-compliant API (Adapter Pattern)

  @impl Arbor.Contracts.Session.Manager
  def create_session(session_params, manager) do
    manager_pid =
      case manager do
        pid when is_pid(pid) -> pid
        name when is_atom(name) -> Process.whereis(name) || name
        other -> other
      end

    case GenServer.call(manager_pid, {:create_session, session_params}) do
      {:ok, session_struct} ->
        {:ok, session_struct}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Arbor.Contracts.Session.Manager
  def get_session(session_id, manager) do
    manager_pid =
      case manager do
        pid when is_pid(pid) -> pid
        name when is_atom(name) -> Process.whereis(name) || name
        other -> other
      end

    case GenServer.call(manager_pid, {:get_session, session_id}) do
      {:ok, session_struct} ->
        {:ok, session_struct}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Arbor.Contracts.Session.Manager
  def terminate_session(session_id, reason, manager) do
    manager_pid =
      case manager do
        pid when is_pid(pid) -> pid
        name when is_atom(name) -> Process.whereis(name) || name
        other -> other
      end

    case GenServer.call(manager_pid, {:terminate_session, session_id, reason}) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Arbor.Contracts.Session.Manager
  def list_sessions(filters, manager_pid) when is_pid(manager_pid) do
    # Extended timeout
    case GenServer.call(manager_pid, {:list_sessions, filters}, 10_000) do
      {:ok, session_structs} ->
        {:ok, session_structs}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Placeholder implementations for remaining callbacks
  @impl Arbor.Contracts.Session.Manager
  def spawn_agent(_session_id, _agent_type, _agent_config, manager_pid)
      when is_pid(manager_pid) do
    {:error, :not_implemented}
  end

  @impl Arbor.Contracts.Session.Manager
  def list_agents(_session_id, manager_pid) when is_pid(manager_pid) do
    {:ok, []}
  end

  @impl Arbor.Contracts.Session.Manager
  def grant_session_capability(_session_id, _capability, manager_pid) when is_pid(manager_pid) do
    :ok
  end

  @impl Arbor.Contracts.Session.Manager
  def update_session_context(_session_id, _key, _value, manager_pid) when is_pid(manager_pid) do
    :ok
  end

  @impl Arbor.Contracts.Session.Manager
  def get_session_context(_session_id, manager_pid) when is_pid(manager_pid) do
    {:ok, %{}}
  end

  @impl Arbor.Contracts.Session.Manager
  def update_session(_session_id, _updates, manager_pid) when is_pid(manager_pid) do
    {:error, :not_implemented}
  end

  @impl Arbor.Contracts.Session.Manager
  def health_check(_session_id, manager_pid) when is_pid(manager_pid) do
    {:ok, %{status: :healthy}}
  end

  @impl Arbor.Contracts.Session.Manager
  def handle_expired_sessions(manager_pid) when is_pid(manager_pid) do
    {:ok, 0}
  end

  @impl Arbor.Contracts.Session.Manager
  def initialize_manager(_opts) do
    # Session Manager initialization is handled by GenServer.start_link/3
    {:ok, %{}}
  end

  @impl Arbor.Contracts.Session.Manager
  def shutdown_manager(_reason, _state) do
    # Session Manager shutdown is handled by GenServer termination
    :ok
  end

  # Legacy Client API (for backward compatibility)

  @doc """
  Start the Session Manager.

  ## Options

  - `:name` - Process name (defaults to module name)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get session information by ID.

  ## Parameters

  - `session_id` - Session identifier

  ## Returns

  - `{:ok, pid, metadata}` - Session found
  - `{:error, :not_found}` - Session does not exist

  ## Examples

      case Manager.get_session(session_id) do
        {:ok, pid, metadata} ->
          # Session exists, can interact with it
          Session.send_message(pid, message)

        {:error, :not_found} ->
          # Session doesn't exist
          IO.puts("Session not found")
      end
  """
  @spec get_session(Types.session_id()) :: {:ok, pid(), map()} | {:error, :not_found}
  def get_session(session_id) do
    case Application.get_env(:arbor_core, :registry_impl, :auto) do
      :mock ->
        # For tests, lookup in mock registry
        case Registry.lookup(Arbor.Core.MockSessionRegistry, session_id) do
          [{pid, metadata}] when is_pid(pid) ->
            if Process.alive?(pid) do
              {:ok, pid, metadata}
            else
              {:error, :not_found}
            end

          [] ->
            {:error, :not_found}
        end

      _ ->
        # For production, use distributed SessionRegistry
        case SessionRegistry.lookup_session(session_id) do
          {:ok, {pid, metadata}} -> {:ok, pid, metadata}
          {:error, :not_found} -> {:error, :not_found}
        end
    end
  end

  @doc """
  List all active sessions.

  Returns information about all currently active sessions including
  their metadata and status.

  ## Returns

  - List of session information maps

  ## Examples

      sessions = Manager.list_sessions()

      Enum.each(sessions, fn session_data ->
        IO.puts("Session \#{session_data.id}: \#{session_data.metadata.client_type}")
      end)
  """
  @spec list_sessions() :: [map()]
  def list_sessions do
    case Application.get_env(:arbor_core, :registry_impl, :auto) do
      :mock ->
        # For tests, list from mock registry
        Registry.select(Arbor.Core.MockSessionRegistry, [
          {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
        ])
        |> Enum.map(fn {id, pid, metadata} ->
          %{
            id: id,
            pid: pid,
            metadata: metadata,
            alive: Process.alive?(pid),
            node: node(pid)
          }
        end)
        |> Enum.filter(& &1.alive)

      _ ->
        # For production, use distributed SessionRegistry
        SessionRegistry.list_all_sessions()
    end
  end

  @doc """
  End a session and clean up resources.

  ## Parameters

  - `session_id` - Session to terminate

  ## Returns

  - `:ok` - Session ended successfully
  - `{:error, :not_found}` - Session does not exist

  ## Examples

      case Manager.end_session(session_id) do
        :ok ->
          IO.puts("Session ended successfully")

        {:error, :not_found} ->
          IO.puts("Session not found")
      end
  """
  @spec end_session(Types.session_id()) :: :ok | {:error, :not_found}
  def end_session(session_id) do
    GenServer.call(__MODULE__, {:end_session, session_id})
  end

  @doc """
  Get detailed session information.

  Returns comprehensive information about a specific session including
  its metadata, active agents, and current state.

  ## Parameters

  - `session_id` - Session identifier

  ## Returns

  - `{:ok, info}` - Session information
  - `{:error, :not_found}` - Session does not exist

  ## Examples

      {:ok, info} = Manager.get_session_info(session_id)
      IO.puts("Active agents: \#{length(info.active_agents)}")
  """
  @spec get_session_info(Types.session_id()) :: {:ok, map()} | {:error, :not_found}
  def get_session_info(session_id) do
    case get_session(session_id) do
      {:ok, pid, metadata} ->
        # Get additional info from the session process
        case Arbor.Core.Sessions.Session.get_state(pid) do
          {:ok, session_state} ->
            {:ok,
             Map.merge(session_state, %{
               pid: pid,
               metadata: metadata
             })}

          _ ->
            # Fallback if we can't get session state
            {:ok,
             %{
               id: session_id,
               pid: pid,
               metadata: metadata,
               active_agents: []
             }}
        end

      {:error, :not_found} = error ->
        error
    end
  end

  @doc """
  Get session statistics.

  Returns aggregate information about session usage and performance.

  ## Returns

  - `{:ok, stats}` - Session statistics

  ## Examples

      {:ok, session_stats} = Manager.get_stats()
      IO.puts("Active sessions: \#{session_stats.active_sessions}")
      IO.puts("Total sessions created: \#{session_stats.total_created}")
  """
  @spec get_stats() :: {:ok, map()}
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # Server implementation

  @impl GenServer
  def init(opts) do
    Logger.info("Starting Arbor Session Manager", opts: opts)

    # Subscribe to session events
    Phoenix.PubSub.subscribe(Arbor.Core.PubSub, "sessions")

    # Initialize telemetry
    :telemetry.execute([:arbor, :session_manager, :start], %{count: 1}, %{node: Node.self()})

    {:ok,
     %{
       # Maps monitor ref -> session_id
       monitor_refs: %{},
       stats: %{
         total_created: 0,
         total_ended: 0,
         sessions_created: 0,
         start_time: DateTime.utc_now()
       }
     }}
  end

  # Contract-compliant GenServer handlers
  @impl true
  def handle_call({:create_session, session_params}, _from, state) do
    # Transform session_params to internal opts format
    opts = [
      created_by: Map.get(session_params, :user_id, "unknown"),
      metadata:
        Map.put(session_params, :purpose, Map.get(session_params, :purpose, "General session")),
      timeout: Map.get(session_params, :timeout, 3_600_000)
    ]

    case create_session_internal(opts, state) do
      {:ok, session_id, pid, new_state} ->
        # Get the session struct for contract compliance
        case Session.to_struct(pid) do
          {:ok, session_struct} ->
            {:reply, {:ok, session_struct}, new_state}

          {:error, reason} ->
            # Clean up the session if struct creation failed
            cleanup_failed_session(session_id, pid)
            {:reply, {:error, reason}, state}
        end

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_call({:get_session, session_id}, _from, state) do
    case lookup_session_pid(session_id) do
      {:ok, pid} ->
        case Session.to_struct(pid) do
          {:ok, session_struct} ->
            {:reply, {:ok, session_struct}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:terminate_session, session_id, _reason}, _from, state) do
    case end_session_internal(session_id, state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_call({:list_sessions, filters}, _from, state) do
    case list_sessions_with_structs(filters, state) do
      {:ok, session_structs} ->
        {:reply, {:ok, session_structs}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Legacy GenServer handlers
  @impl true
  def handle_call({:end_session, session_id}, _from, state) do
    case get_session(session_id) do
      {:ok, _pid, _metadata} ->
        # Gracefully stop the session using cluster supervisor
        ClusterSupervisor.stop_agent(session_id)

        # Session cleanup will be handled by :DOWN message

        # Update stats
        new_stats = Map.update!(state.stats, :total_ended, &(&1 + 1))

        Logger.info("Session ended via manager", session_id: session_id)

        {:reply, :ok, %{state | stats: new_stats}}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    # Get active session count from distributed registry
    active_sessions =
      case Application.get_env(:arbor_core, :registry_impl, :auto) do
        :mock ->
          length(
            Registry.select(Arbor.Core.MockSessionRegistry, [{{:"$1", :"$2", :"$3"}, [], [true]}])
          )

        _ ->
          SessionRegistry.session_count()
      end

    stats =
      Map.merge(state.stats, %{
        active_sessions: active_sessions,
        uptime_seconds: DateTime.diff(DateTime.utc_now(), state.stats.start_time)
      })

    {:reply, {:ok, stats}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    # Find session ID from monitor ref
    case Map.get(state.monitor_refs, ref) do
      nil ->
        # Unknown process - not a session we're monitoring
        {:noreply, state}

      session_id ->
        # Update state
        new_monitor_refs = Map.delete(state.monitor_refs, ref)
        new_stats = Map.update!(state.stats, :total_ended, &(&1 + 1))

        # Broadcast event
        Phoenix.PubSub.broadcast(
          Arbor.Core.PubSub,
          "sessions",
          {:session_ended, session_id, reason}
        )

        # Emit telemetry
        :telemetry.execute(
          [:arbor, :session, :ended],
          %{count: 1},
          %{session_id: session_id, reason: reason}
        )

        Logger.info("Session ended",
          session_id: session_id,
          reason: reason
        )

        {:noreply, %{state | monitor_refs: new_monitor_refs, stats: new_stats}}
    end
  end

  @impl true
  def handle_info({:session_created, session_id}, state) do
    # External session creation notification
    Logger.debug("Received external session creation notification", session_id: session_id)
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Session Manager received unexpected message", message: msg)
    {:noreply, state}
  end

  # Private functions

  defp create_session_internal(opts, state) do
    session_id = Arbor.Identifiers.generate_session_id()
    timeout = opts[:timeout] || 3_600_000

    # Start session under cluster supervisor for distributed management
    session_spec = %{
      id: session_id,
      module: Session,
      args: [
        session_id: session_id,
        created_by: opts[:created_by],
        metadata: opts[:metadata] || %{},
        timeout: timeout
      ]
    }

    case ClusterSupervisor.start_agent(session_spec) do
      {:ok, pid} ->
        # Monitor the session process to handle termination
        ref = Process.monitor(pid)
        new_monitor_refs = Map.put(state.monitor_refs, ref, session_id)

        # Update session stats
        new_stats = Map.update!(state.stats, :sessions_created, &(&1 + 1))

        # Emit telemetry
        :telemetry.execute(
          [:arbor, :session, :created],
          %{count: 1},
          %{session_id: session_id}
        )

        Logger.info("Session created", session_id: session_id, pid: pid)

        {:ok, session_id, pid, %{state | stats: new_stats, monitor_refs: new_monitor_refs}}

      {:error, reason} ->
        Logger.error("Failed to start session", session_id: session_id, reason: reason)
        {:error, reason, state}
    end
  end

  defp lookup_session_pid(session_id) do
    case Application.get_env(:arbor_core, :registry_impl, :auto) do
      :mock ->
        case Registry.lookup(Arbor.Core.MockSessionRegistry, session_id) do
          [{pid, _metadata}] -> {:ok, pid}
          [] -> {:error, :not_found}
        end

      _ ->
        case SessionRegistry.lookup_session(session_id) do
          {:ok, pid} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp end_session_internal(session_id, state) do
    case lookup_session_pid(session_id) do
      {:ok, _pid} ->
        # Stop the session process
        case ClusterSupervisor.stop_agent(session_id) do
          :ok ->
            Logger.info("Session ended", session_id: session_id)
            {:ok, state}

          {:error, reason} ->
            Logger.error("Failed to end session", session_id: session_id, reason: reason)
            {:error, reason, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp list_sessions_with_structs(filters, _state) do
    try do
      # Get all session PIDs from registry
      session_pids =
        case Application.get_env(:arbor_core, :registry_impl, :auto) do
          :mock ->
            Enum.map(
              Registry.select(Arbor.Core.MockSessionRegistry, [{{:_, :_}, [], [:_]}]),
              fn {_session_id, {pid, _metadata}} -> pid end
            )

          _ ->
            case SessionRegistry.list_all_sessions() do
              {:ok, sessions} -> Enum.map(sessions, fn {_id, pid, _metadata} -> pid end)
              {:error, _} -> []
            end
        end

      # Convert to structs in parallel with timeout
      session_structs =
        session_pids
        |> Task.async_stream(
          fn pid -> Session.to_struct(pid) end,
          timeout: 2000,
          on_timeout: :kill_task
        )
        |> Enum.reduce([], fn
          {:ok, {:ok, session_struct}}, acc -> [session_struct | acc]
          # Skip failed/timeout results
          _, acc -> acc
        end)

      # Apply filters (basic implementation)
      filtered_sessions = apply_session_filters(session_structs, filters)

      {:ok, filtered_sessions}
    rescue
      e ->
        Logger.error("Failed to list sessions", error: Exception.message(e))
        {:error, :list_failed}
    end
  end

  defp apply_session_filters(sessions, filters) when map_size(filters) == 0, do: sessions

  defp apply_session_filters(sessions, filters) do
    Enum.filter(sessions, fn session ->
      Enum.all?(filters, fn
        {:user_id, user_id} ->
          session.user_id == user_id

        {:status, status} ->
          session.status == status

        {:created_after, datetime} ->
          DateTime.compare(session.created_at, datetime) in [:gt, :eq]

        {:created_before, datetime} ->
          DateTime.compare(session.created_at, datetime) in [:lt, :eq]

        # Unknown filter - ignore
        _ ->
          true
      end)
    end)
  end

  defp cleanup_failed_session(session_id, pid) do
    try do
      if Process.alive?(pid) do
        Process.exit(pid, :kill)
      end

      ClusterSupervisor.stop_agent(session_id)
    rescue
      # Best effort cleanup
      _ -> :ok
    end
  end
end
