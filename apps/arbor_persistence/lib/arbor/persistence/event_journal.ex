defmodule Arbor.Persistence.EventJournal do
  @moduledoc """
  Event journal batching system for critical events.

  This module implements batched writing of critical events to improve performance
  while maintaining data consistency. Events are buffered and written in batches
  to reduce I/O overhead.

  ## Performance Targets

  - Journal write: <10ms (async buffered write)
  - Batch size: 10 events or 1 second timeout
  - Critical events only (no streaming chunks)

  ## Usage

      # Start the journal writer
      {:ok, _pid} = EventJournal.start_link(batch_size: 10, flush_interval: 1000)
      
      # Write critical events (async)
      :ok = EventJournal.write_critical_event("session_123", {:user_message, message})
      
      # Force flush for testing/shutdown
      :ok = EventJournal.flush_all()
  """

  use GenServer

  @type event_type ::
          :user_message | :assistant_response | :mcp_tool_executed | :session_config_changed
  @type critical_event :: {event_type(), any()}
  @type session_id :: String.t()

  @default_batch_size 10
  # 1 second
  @default_flush_interval 1000

  # Public API

  @doc """
  Start the event journal writer GenServer.

  ## Options

  - `:batch_size` - Number of events to buffer before flushing (default: 10)
  - `:flush_interval` - Maximum time to wait before flushing (default: 1000ms)
  - `:data_dir` - Directory for journal files (default: "./data/journals")
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Write a critical event to the journal (async).

  Events are buffered and written in batches for performance.
  """
  @spec write_critical_event(GenServer.server(), session_id(), critical_event()) :: :ok
  def write_critical_event(server \\ __MODULE__, session_id, event) do
    GenServer.cast(server, {:write_event, session_id, event})
  end

  @doc """
  Force flush all buffered events to disk.

  Used for testing and graceful shutdown.
  """
  @spec flush_all(GenServer.server()) :: :ok
  def flush_all(server \\ __MODULE__) do
    GenServer.call(server, :flush_all)
  end

  @doc """
  Get current buffer status for monitoring.
  """
  @spec get_buffer_status(GenServer.server()) :: %{
          pending_events: non_neg_integer(),
          last_flush: integer(),
          sessions_buffered: non_neg_integer()
        }
  def get_buffer_status(server \\ __MODULE__) do
    GenServer.call(server, :get_buffer_status)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    flush_interval = Keyword.get(opts, :flush_interval, @default_flush_interval)
    data_dir = Keyword.get(opts, :data_dir, "./data/journals")

    # Ensure journal directory exists
    File.mkdir_p!(data_dir)

    # Schedule periodic flush
    schedule_flush(flush_interval)

    state = %{
      batch_size: batch_size,
      flush_interval: flush_interval,
      data_dir: data_dir,
      buffers: %{},
      last_flush: :erlang.monotonic_time(:millisecond)
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:write_event, session_id, event}, state) do
    # Add event to session buffer
    timestamped_event = {DateTime.utc_now(), event}

    updated_buffers =
      Map.update(state.buffers, session_id, [timestamped_event], &[timestamped_event | &1])

    new_state = %{state | buffers: updated_buffers}

    # Check if we should flush this session's buffer
    session_events = Map.get(updated_buffers, session_id, [])

    if length(session_events) >= state.batch_size do
      flush_session_buffer(session_id, session_events, new_state)
    else
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_call(:flush_all, _from, state) do
    new_state = flush_all_buffers(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_buffer_status, _from, state) do
    total_events =
      state.buffers
      |> Map.values()
      |> Enum.map(&length/1)
      |> Enum.sum()

    status = %{
      pending_events: total_events,
      last_flush: state.last_flush,
      sessions_buffered: map_size(state.buffers)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:flush_timer, state) do
    current_time = :erlang.monotonic_time(:millisecond)

    # Flush if enough time has passed
    new_state =
      if current_time - state.last_flush >= state.flush_interval do
        flush_all_buffers(state)
      else
        state
      end

    # Schedule next flush
    schedule_flush(state.flush_interval)

    {:noreply, new_state}
  end

  @impl true
  def terminate(_reason, state) do
    # Flush all pending events on shutdown
    flush_all_buffers(state)
    :ok
  end

  # Private functions

  defp flush_session_buffer(session_id, events, state) do
    write_events_to_disk(session_id, events, state.data_dir)

    # Remove flushed events from buffer
    updated_buffers = Map.delete(state.buffers, session_id)

    new_state = %{
      state
      | buffers: updated_buffers,
        last_flush: :erlang.monotonic_time(:millisecond)
    }

    {:noreply, new_state}
  rescue
    error ->
      # Log error but don't crash the process
      # In production, would use proper logging
      IO.puts("Failed to write journal for session #{session_id}: #{inspect(error)}")
      {:noreply, state}
  end

  defp flush_all_buffers(state) do
    # Flush all session buffers
    Enum.each(state.buffers, fn {session_id, events} ->
      write_events_to_disk(session_id, events, state.data_dir)
    end)

    %{state | buffers: %{}, last_flush: :erlang.monotonic_time(:millisecond)}
  end

  defp write_events_to_disk(session_id, events, data_dir) do
    journal_file = Path.join(data_dir, "session_#{session_id}.journal")

    # Reverse events to maintain chronological order (they were prepended to list)
    ordered_events = Enum.reverse(events)

    # Convert events to binary format
    binary_data =
      Enum.map(ordered_events, fn {timestamp, event} ->
        :erlang.term_to_binary({timestamp, event})
      end)

    # Append to journal file
    File.open!(journal_file, [:append, :binary], fn file ->
      Enum.each(binary_data, fn event_binary ->
        # Write event length followed by event data
        event_length = byte_size(event_binary)
        IO.binwrite(file, <<event_length::32, event_binary::binary>>)
      end)
    end)
  end

  defp schedule_flush(interval) do
    Process.send_after(self(), :flush_timer, interval)
  end

  # Journal reading functions (for recovery)

  @doc """
  Read journal events for a session since a given timestamp.
  """
  @spec read_journal_since(session_id(), DateTime.t(), String.t()) ::
          {:ok, [critical_event()]} | {:error, term()}
  def read_journal_since(session_id, since_timestamp, data_dir \\ "./data/journals") do
    journal_file = Path.join(data_dir, "session_#{session_id}.journal")

    case File.exists?(journal_file) do
      false -> {:ok, []}
      true -> read_journal_file(journal_file, since_timestamp)
    end
  end

  defp read_journal_file(journal_file, since_timestamp) do
    events =
      File.open!(journal_file, [:read, :binary], fn file ->
        read_all_events(file, since_timestamp, [])
      end)

    {:ok, events}
  rescue
    error -> {:error, error}
  end

  defp read_all_events(file, since_timestamp, acc) do
    case IO.binread(file, 4) do
      :eof ->
        Enum.reverse(acc)

      <<event_length::32>> ->
        event_binary = IO.binread(file, event_length)
        {timestamp, event} = :erlang.binary_to_term(event_binary)

        # Only include events after the since_timestamp
        new_acc =
          if DateTime.compare(timestamp, since_timestamp) == :gt do
            [event | acc]
          else
            acc
          end

        read_all_events(file, since_timestamp, new_acc)
    end
  end
end
