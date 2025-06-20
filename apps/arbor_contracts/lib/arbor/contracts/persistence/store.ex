defmodule Arbor.Contracts.Persistence.Store do
  @moduledoc """
  Defines the contract for persistence backends in the Arbor system.

  This behaviour provides the foundation for event sourcing, CQRS, and 
  general state persistence. All persistence implementations (PostgreSQL, 
  Redis, DETS) must conform to this contract.

  ## Design Principles

  - **Event Sourcing First**: Optimized for append-only event storage
  - **Immutability**: Events are never modified, only appended
  - **Stream-based**: Events are organized in streams (e.g., per agent)
  - **Snapshots**: Support for periodic state snapshots to optimize recovery
  - **Transactions**: Atomic operations for consistency

  ## Error Handling

  All errors follow a consistent pattern with specific atoms for common cases:
  - `:not_found` - Resource does not exist
  - `:already_exists` - Resource already exists
  - `:transaction_failed` - Transaction could not be completed
  - `:connection_error` - Backend connection issues
  - `:invalid_data` - Data validation failed

  ## Example Implementation

      defmodule MyStore do
        @behaviour Arbor.Contracts.Persistence.Store
        
        @impl true
        def init(opts) do
          # Initialize connection pool, tables, etc.
          {:ok, %{conn: establish_connection(opts)}}
        end
        
        @impl true
        def append_events(stream_id, events, expected_version, state) do
          # Append events with optimistic concurrency control
        end
      end

  @version "1.0.0"
  """

  alias Arbor.Contracts.Events.Event
  alias Arbor.Contracts.Persistence.Snapshot

  @type stream_id :: String.t()
  @type event_number :: non_neg_integer()
  @type version :: non_neg_integer()
  @type state :: any()
  @type opts :: keyword()

  @type error_reason ::
          :not_found
          | :already_exists
          | :transaction_failed
          | :connection_error
          | :invalid_data
          | :version_conflict
          | :snapshot_not_found
          | :stream_deleted
          | {:error, term()}

  @doc """
  Initialize the persistence store with given options.

  Called once when the store process starts. Should establish connections,
  create tables/indexes if needed, and return the initial state.

  ## Options

  - `:connection_string` - Database connection parameters
  - `:pool_size` - Connection pool size
  - `:timeout` - Operation timeout in milliseconds

  ## Returns

  - `{:ok, state}` - Store initialized successfully
  - `{:error, reason}` - Initialization failed
  """
  @callback init(opts()) :: {:ok, state()} | {:error, error_reason()}

  @doc """
  Append events to a stream with optimistic concurrency control.

  This is the primary write operation for event sourcing. Events are appended
  atomically with version checking to prevent concurrent modification conflicts.

  ## Parameters

  - `stream_id` - Unique identifier for the event stream
  - `events` - List of events to append
  - `expected_version` - Expected current version of the stream (use -1 for new streams)
  - `state` - Store state

  ## Returns

  - `{:ok, new_version}` - Events appended successfully, returns new stream version
  - `{:error, :version_conflict}` - Stream version doesn't match expected
  - `{:error, reason}` - Other errors

  ## Example

      events = [
        %Event{type: :agent_started, data: %{agent_id: "agent_123"}},
        %Event{type: :capability_granted, data: %{cap_id: "cap_456"}}
      ]
      
      {:ok, version} = Store.append_events("agent_123", events, 0, state)
  """
  @callback append_events(
              stream_id(),
              [Event.t()],
              version(),
              state()
            ) :: {:ok, version()} | {:error, error_reason()}

  @doc """
  Read events from a stream within a version range.

  Retrieves events in order from the specified stream. Used for event replay
  and state reconstruction.

  ## Parameters

  - `stream_id` - Stream to read from
  - `from_version` - Starting version (inclusive)
  - `to_version` - Ending version (inclusive), or `:latest` for all events
  - `state` - Store state

  ## Returns

  - `{:ok, events}` - List of events in version order
  - `{:error, :not_found}` - Stream doesn't exist
  - `{:error, reason}` - Other errors
  """
  @callback read_events(
              stream_id(),
              event_number(),
              event_number() | :latest,
              state()
            ) :: {:ok, [Event.t()]} | {:error, error_reason()}

  @doc """
  Read all events from all streams within a time range.

  Used for global event replay, analytics, and debugging. Returns events
  from all streams ordered by timestamp.

  ## Parameters

  - `from` - Start timestamp (inclusive)
  - `to` - End timestamp (inclusive)
  - `opts` - Additional options like filters, limits
  - `state` - Store state

  ## Options

  - `:limit` - Maximum number of events to return
  - `:stream_filter` - Regex pattern to filter stream IDs
  - `:event_types` - List of event types to include
  """
  @callback read_all_events(
              from :: DateTime.t(),
              to :: DateTime.t(),
              opts :: keyword(),
              state()
            ) :: {:ok, [Event.t()]} | {:error, error_reason()}

  @doc """
  Save a snapshot of current state for a stream.

  Snapshots optimize recovery by storing periodic state checkpoints.
  Only the latest snapshot per stream is retained.

  ## Parameters

  - `stream_id` - Stream this snapshot belongs to
  - `snapshot` - Snapshot data
  - `state` - Store state

  ## Returns

  - `{:ok, snapshot_id}` - Snapshot saved successfully
  - `{:error, reason}` - Save failed
  """
  @callback save_snapshot(
              stream_id(),
              Snapshot.t(),
              state()
            ) :: {:ok, String.t()} | {:error, error_reason()}

  @doc """
  Load the latest snapshot for a stream.

  Returns the most recent snapshot if one exists, used during state recovery.

  ## Parameters

  - `stream_id` - Stream to load snapshot for
  - `state` - Store state

  ## Returns

  - `{:ok, snapshot}` - Latest snapshot
  - `{:error, :snapshot_not_found}` - No snapshot exists
  - `{:error, reason}` - Other errors
  """
  @callback load_snapshot(
              stream_id(),
              state()
            ) :: {:ok, Snapshot.t()} | {:error, error_reason()}

  @doc """
  Delete a stream and all its events.

  Permanently removes a stream. This is a destructive operation that should
  be used carefully, typically only for GDPR compliance or testing.

  ## Parameters

  - `stream_id` - Stream to delete
  - `state` - Store state

  ## Returns

  - `:ok` - Stream deleted
  - `{:error, :not_found}` - Stream doesn't exist
  - `{:error, reason}` - Deletion failed
  """
  @callback delete_stream(
              stream_id(),
              state()
            ) :: :ok | {:error, error_reason()}

  @doc """
  List all stream IDs matching a pattern.

  Used for discovery and management operations.

  ## Parameters

  - `pattern` - Glob pattern (e.g., "agent_*")
  - `state` - Store state

  ## Returns

  - `{:ok, stream_ids}` - List of matching stream IDs
  - `{:error, reason}` - Query failed
  """
  @callback list_streams(
              pattern :: String.t(),
              state()
            ) :: {:ok, [stream_id()]} | {:error, error_reason()}

  @doc """
  Get metadata about a stream.

  Returns information about the stream without reading all events.

  ## Returns

  Stream metadata map containing:
  - `:version` - Current stream version
  - `:event_count` - Total number of events
  - `:created_at` - When stream was created
  - `:updated_at` - Last event timestamp
  - `:has_snapshot` - Whether a snapshot exists
  """
  @callback get_stream_metadata(
              stream_id(),
              state()
            ) :: {:ok, map()} | {:error, error_reason()}

  @doc """
  Execute a function within a transaction.

  Provides ACID guarantees for complex operations that span multiple
  streams or require consistency.

  ## Parameters

  - `fun` - Function to execute within transaction
  - `opts` - Transaction options
  - `state` - Store state

  ## Options

  - `:timeout` - Transaction timeout in milliseconds
  - `:isolation_level` - Transaction isolation level

  ## Returns

  - `{:ok, result}` - Transaction completed successfully
  - `{:error, :transaction_failed}` - Transaction rolled back
  - `{:error, reason}` - Other errors
  """
  @callback transaction(
              fun :: (state() -> {:ok, result :: any()} | {:error, term()}),
              opts :: keyword(),
              state()
            ) :: {:ok, any()} | {:error, error_reason()}

  @doc """
  Clean up resources when shutting down.

  Called when the store process is terminating. Should close connections,
  flush buffers, and perform any necessary cleanup.
  """
  @callback terminate(reason :: term(), state()) :: :ok
end
