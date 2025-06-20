defmodule Arbor.Security.AuditLogger do
  @moduledoc """
  Audit logging service with telemetry integration.

  This module handles security audit events:
  - Persistent storage of audit events in PostgreSQL
  - Real-time telemetry emission for monitoring
  - Structured logging for compliance and debugging
  - Event querying and filtering capabilities

  All security-related actions generate audit events that are
  stored for compliance and can be queried for analysis.
  """

  use GenServer

  alias Arbor.Contracts.Security.AuditEvent

  require Logger

  defstruct [
    :db_module,
    :telemetry_enabled,
    :event_buffer,
    :buffer_size,
    :flush_interval
  ]

  @type state :: %__MODULE__{
          db_module: module(),
          telemetry_enabled: boolean(),
          event_buffer: [AuditEvent.t()],
          buffer_size: pos_integer(),
          flush_interval: pos_integer()
        }

  @default_buffer_size 100
  # 5 seconds
  @default_flush_interval 5_000

  # Client API

  @doc """
  Start the audit logger.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Log a security audit event.
  """
  @spec log_event(AuditEvent.t()) :: :ok
  def log_event(%AuditEvent{} = event) do
    GenServer.cast(__MODULE__, {:log_event, event})
  end

  @doc """
  Get audit events based on filters.

  ## Filters

  - `:capability_id` - Events for specific capability
  - `:principal_id` - Events for specific agent
  - `:event_type` - Filter by event type
  - `:reason` - Filter by reason
  - `:from` - Start timestamp
  - `:to` - End timestamp
  - `:limit` - Maximum events to return
  """
  @spec get_events(keyword()) :: {:ok, [AuditEvent.t()]} | {:error, term()}
  def get_events(filters \\ []) do
    GenServer.call(__MODULE__, {:get_events, filters})
  end

  @doc """
  Force flush of buffered events to storage.
  """
  @spec flush_events() :: :ok
  def flush_events do
    GenServer.call(__MODULE__, :flush_events)
  end

  @doc """
  Get audit logger statistics.
  """
  @spec get_stats() :: map()
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    # Use real PostgreSQL repo by default, mock for testing
    db_module =
      opts[:db_module] ||
        (Application.get_env(:arbor_security, :env, :dev) == :test && opts[:use_mock] == true &&
           __MODULE__.PostgresDB) ||
        Arbor.Security.Persistence.AuditRepo

    state = %__MODULE__{
      db_module: db_module,
      telemetry_enabled: opts[:telemetry_enabled] != false,
      event_buffer: [],
      buffer_size: opts[:buffer_size] || @default_buffer_size,
      flush_interval: opts[:flush_interval] || @default_flush_interval
    }

    # Start periodic flush timer
    schedule_flush(state.flush_interval)

    # Start the database module
    start_db_module(state.db_module)

    Logger.info("AuditLogger started with buffer size #{state.buffer_size}")

    {:ok, state}
  end

  @impl true
  def handle_cast({:log_event, event}, state) do
    # Add event to buffer
    new_buffer = [event | state.event_buffer]

    # Emit telemetry
    if state.telemetry_enabled do
      emit_audit_telemetry(event)
    end

    # Log structured event
    log_structured_event(event)

    # Flush if buffer is full
    if length(new_buffer) >= state.buffer_size do
      {:ok, flushed_state} = flush_buffer(%{state | event_buffer: new_buffer})
      {:noreply, flushed_state}
    else
      {:noreply, %{state | event_buffer: new_buffer}}
    end
  end

  @impl true
  def handle_call({:get_events, filters}, _from, state) do
    case state.db_module.get_audit_events(filters) do
      {:ok, events} ->
        {:reply, {:ok, events}, state}

      {:error, reason} = error ->
        Logger.error("Failed to get audit events: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:flush_events, _from, state) do
    case flush_buffer(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason} ->
        Logger.error("Failed to flush audit events: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{
      buffered_events: length(state.event_buffer),
      buffer_size: state.buffer_size,
      flush_interval: state.flush_interval,
      telemetry_enabled: state.telemetry_enabled
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:flush_buffer, state) do
    # Periodic flush
    case flush_buffer(state) do
      {:ok, new_state} ->
        schedule_flush(state.flush_interval)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error(
          "CRITICAL: Failed to flush audit events to persistent storage. Events remain in buffer. Reason: #{inspect(reason)}"
        )

        # Schedule retry but alert operations
        :telemetry.execute(
          [:arbor, :security, :audit, :flush_failed],
          %{buffer_size: length(state.event_buffer)},
          %{reason: reason}
        )

        schedule_flush(state.flush_interval)
        {:noreply, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("AuditLogger terminating: #{inspect(reason)}")

    # Flush any remaining events
    case flush_buffer(state) do
      {:ok, _state} ->
        Logger.info("Flushed remaining audit events on termination")

      {:error, reason} ->
        Logger.error("Failed to flush events on termination: #{inspect(reason)}")
    end

    :ok
  end

  # Private helper functions

  defp flush_buffer(%{event_buffer: []} = state) do
    # Nothing to flush
    {:ok, state}
  end

  defp flush_buffer(state) do
    # Restore chronological order
    events = Enum.reverse(state.event_buffer)

    case state.db_module.insert_audit_events(events) do
      :ok ->
        Logger.debug("Flushed #{length(events)} audit events to storage")
        {:ok, %{state | event_buffer: []}}

      {:error, reason} ->
        Logger.error("Failed to flush audit events: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp emit_audit_telemetry(event) do
    # Emit telemetry based on event type
    event_name =
      case event.event_type do
        :authorization_success -> [:arbor, :security, :authorization, :success]
        :authorization_denied -> [:arbor, :security, :authorization, :denied]
        :capability_granted -> [:arbor, :security, :capability, :granted]
        :capability_revoked -> [:arbor, :security, :capability, :revoked]
        :capability_delegated -> [:arbor, :security, :capability, :delegated]
        _ -> [:arbor, :security, :audit, :event]
      end

    measurements = %{count: 1}

    metadata = %{
      event_id: event.id,
      event_type: event.event_type,
      principal_id: event.principal_id,
      capability_id: event.capability_id,
      resource_uri: event.resource_uri,
      decision: event.decision,
      reason: event.reason,
      severity: AuditEvent.severity(event)
    }

    :telemetry.execute(event_name, measurements, metadata)
  end

  defp log_structured_event(event) do
    # Create structured log entry
    log_level =
      case AuditEvent.severity(event) do
        :critical -> :error
        :high -> :warning
        :medium -> :info
        :low -> :info
        :info -> :debug
      end

    message = AuditEvent.to_log_message(event)

    metadata = [
      event_id: event.id,
      event_type: event.event_type,
      principal_id: event.principal_id,
      capability_id: event.capability_id,
      resource_uri: event.resource_uri
    ]

    Logger.log(log_level, message, metadata)
  end

  defp schedule_flush(interval) do
    Process.send_after(self(), :flush_buffer, interval)
  end

  defp start_db_module_process(db_module) do
    case db_module.start_link([]) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to start audit DB module: #{inspect(reason)}")
        :error
    end
  end

  defp start_db_module(db_module) do
    # Only start if it's the mock module (real repos are started by the app supervisor)
    if db_module == __MODULE__.PostgresDB do
      case Process.whereis(db_module) do
        nil ->
          start_db_module_process(db_module)

        _pid ->
          :ok
      end
    else
      # Real repo is managed by the supervisor
      :ok
    end
  end

  # Mock PostgreSQL module for development/testing
  defmodule PostgresDB do
    @moduledoc """
    Mock PostgreSQL database module for audit events.

    TODO: This is a mock implementation for testing only!
    In production, use Arbor.Security.Persistence.AuditRepo instead.
    This uses Agent-based in-memory storage which is NOT suitable for production.

    FIXME: All audit events are lost on restart - non-compliant for production!
    """

    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(fn -> %{events: [], sequence: 0} end, name: __MODULE__)
    end

    def insert_audit_events(events) when is_list(events) do
      Agent.update(__MODULE__, fn state ->
        new_events = events ++ state.events
        %{state | events: new_events, sequence: state.sequence + length(events)}
      end)

      :ok
    end

    def get_audit_events(filters) do
      events = Agent.get(__MODULE__, fn state -> state.events end)

      filtered_events = apply_filters(events, filters)

      {:ok, filtered_events}
    end

    def clear_all do
      Agent.update(__MODULE__, fn _state ->
        %{events: [], sequence: 0}
      end)

      :ok
    end

    defp apply_filters(events, filters) do
      Enum.reduce(filters, events, fn {key, value}, acc ->
        case key do
          :capability_id ->
            Enum.filter(acc, &(&1.capability_id == value))

          :principal_id ->
            Enum.filter(acc, &(&1.principal_id == value))

          :event_type ->
            Enum.filter(acc, &(&1.event_type == value))

          :reason ->
            Enum.filter(acc, &(&1.reason == value))

          :limit ->
            Enum.take(acc, value)

          :from ->
            filter_events_from(acc, value)

          :to ->
            filter_events_until(acc, value)

          _ ->
            acc
        end
      end)
    end

    defp filter_events_until(events, end_time) do
      Enum.filter(events, fn event ->
        DateTime.compare(event.timestamp, end_time) != :gt
      end)
    end

    defp filter_events_from(events, start_time) do
      Enum.filter(events, fn event ->
        DateTime.compare(event.timestamp, start_time) != :lt
      end)
    end
  end
end
