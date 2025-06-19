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

  use GenServer
  require Logger

  alias Arbor.Core.Sessions.Session
  alias Arbor.Types

  @table :arbor_sessions

  # Client API

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
  Create a new session.

  ## Parameters

  - `opts` - Session creation options

  ## Options

  - `:metadata` - Arbitrary metadata about the session
  - `:created_by` - Identifier of the entity creating the session
  - `:timeout` - Session timeout in milliseconds (default: 1 hour)

  ## Returns

  - `{:ok, session_id, pid}` - Session created successfully
  - `{:error, reason}` - Session creation failed

  ## Examples

      {:ok, session_id, pid} = Manager.create_session(
        metadata: %{user_id: "user123", client_type: :cli},
        created_by: "gateway",
        timeout: 3_600_000  # 1 hour
      )
  """
  @spec create_session(keyword()) :: {:ok, Types.session_id(), pid()} | {:error, term()}
  def create_session(opts \\ []) do
    GenServer.call(__MODULE__, {:create_session, opts})
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
    case :ets.lookup(@table, session_id) do
      [{^session_id, pid, metadata}] when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, pid, metadata}
        else
          # Clean up dead session
          :ets.delete(@table, session_id)
          {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
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
    :ets.tab2list(@table)
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

  @impl true
  def init(opts) do
    Logger.info("Starting Arbor Session Manager", opts: opts)

    # Create ETS table for fast session lookups
    :ets.new(@table, [:named_table, :public, read_concurrency: true])

    # Subscribe to session events
    Phoenix.PubSub.subscribe(Arbor.PubSub, "sessions")

    # Initialize telemetry
    :telemetry.execute([:arbor, :session_manager, :start], %{count: 1}, %{node: Node.self()})

    {:ok,
     %{
       sessions: %{},
       stats: %{
         total_created: 0,
         total_ended: 0,
         start_time: DateTime.utc_now()
       }
     }}
  end

  @impl true
  def handle_call({:create_session, opts}, _from, state) do
    session_id = Types.generate_session_id()
    # 1 hour default
    timeout = opts[:timeout] || 3_600_000

    # Start session under Horde supervisor for clustering
    case Horde.DynamicSupervisor.start_child(
           Arbor.Core.AgentSupervisor,
           {Session,
            [
              session_id: session_id,
              created_by: opts[:created_by],
              metadata: opts[:metadata] || %{},
              timeout: timeout
            ]}
         ) do
      {:ok, pid} ->
        # Store in ETS for fast lookups
        session_metadata = %{
          created_at: DateTime.utc_now(),
          created_by: opts[:created_by],
          timeout: timeout,
          custom: opts[:metadata] || %{}
        }

        :ets.insert(@table, {session_id, pid, session_metadata})

        # Monitor for cleanup
        Process.monitor(pid)

        # Track in manager state
        new_sessions =
          Map.put(state.sessions, session_id, %{
            pid: pid,
            metadata: session_metadata,
            created_at: DateTime.utc_now()
          })

        # Update stats
        new_stats = Map.update!(state.stats, :total_created, &(&1 + 1))

        # Broadcast event
        Phoenix.PubSub.broadcast(
          Arbor.PubSub,
          "sessions",
          {:session_created, session_id, session_metadata}
        )

        # Emit telemetry
        :telemetry.execute(
          [:arbor, :session, :created],
          %{count: 1},
          %{session_id: session_id, created_by: opts[:created_by]}
        )

        Logger.info("Session created",
          session_id: session_id,
          created_by: opts[:created_by],
          metadata: opts[:metadata]
        )

        {:reply, {:ok, session_id, pid}, %{state | sessions: new_sessions, stats: new_stats}}

      {:error, reason} ->
        Logger.error("Failed to create session", reason: reason)

        :telemetry.execute(
          [:arbor, :session, :creation_failed],
          %{count: 1},
          %{reason: reason}
        )

        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:end_session, session_id}, _from, state) do
    case get_session(session_id) do
      {:ok, pid, _metadata} ->
        # Gracefully stop the session
        DynamicSupervisor.terminate_child(Arbor.Core.AgentSupervisor, pid)

        # Remove from ETS (will be handled by :DOWN message as well)
        :ets.delete(@table, session_id)

        # Update state
        new_sessions = Map.delete(state.sessions, session_id)
        new_stats = Map.update!(state.stats, :total_ended, &(&1 + 1))

        Logger.info("Session ended via manager", session_id: session_id)

        {:reply, :ok, %{state | sessions: new_sessions, stats: new_stats}}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    active_sessions = :ets.info(@table, :size) || 0

    stats =
      Map.merge(state.stats, %{
        active_sessions: active_sessions,
        uptime_seconds: DateTime.diff(DateTime.utc_now(), state.stats.start_time)
      })

    {:reply, {:ok, stats}, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    # Find and cleanup session
    case :ets.match_object(@table, {:_, pid, :_}) do
      [{session_id, ^pid, metadata}] ->
        :ets.delete(@table, session_id)

        # Update state
        new_sessions = Map.delete(state.sessions, session_id)
        new_stats = Map.update!(state.stats, :total_ended, &(&1 + 1))

        # Broadcast event
        Phoenix.PubSub.broadcast(Arbor.PubSub, "sessions", {:session_ended, session_id, reason})

        # Emit telemetry
        :telemetry.execute(
          [:arbor, :session, :ended],
          %{count: 1},
          %{session_id: session_id, reason: reason}
        )

        Logger.info("Session ended",
          session_id: session_id,
          reason: reason,
          duration_seconds: calculate_session_duration(metadata)
        )

        {:noreply, %{state | sessions: new_sessions, stats: new_stats}}

      [] ->
        # Not a session process we're tracking
        {:noreply, state}
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

  defp calculate_session_duration(%{created_at: created_at}) do
    DateTime.diff(DateTime.utc_now(), created_at)
  end

  defp calculate_session_duration(_), do: nil
end
