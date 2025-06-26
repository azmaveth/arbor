defmodule Arbor.Persistence.EventTimeMachine do
  @moduledoc """
  Time-travel debugging utilities for event-sourced systems.

  This module provides advanced debugging capabilities by allowing you to
  replay events to specific points in time, create timeline snapshots,
  and analyze system state evolution. Perfect for debugging complex
  event sequences and understanding system behavior over time.

  ## Usage

      use Arbor.Persistence.FastCase
      import Arbor.Persistence.EventTimeMachine
      
      test "debug state at specific time", %{store: store} do
        # ... events have been stored ...
        
        # Replay to specific timestamp
        state = replay_to_timestamp(~U[2024-01-15 10:30:00Z], store)
        assert length(state.active_agents) == 2
        
        # Create timeline visualization
        timeline = create_timeline_snapshot("agent-123", store)
        IO.puts(format_timeline(timeline))
      end
  """

  import ExUnit.Assertions
  alias Arbor.Persistence.Store
  alias Arbor.Persistence.AggregateTestHelper

  @doc """
  Replays all events up to a specific timestamp.

  ## Parameters
  - `timestamp` - DateTime to replay up to
  - `store` - The store instance
  - `opts` - Options (optional)
    - `:projections` - List of projection modules to build
    - `:aggregates` - List of aggregate IDs to reconstruct
    - `:include_future` - Include events with future timestamps (default: false)

  ## Returns
  - Map with :projections and :aggregates keys containing states

  ## Examples

      # Replay to specific time
      state = replay_to_timestamp(~U[2024-01-15 10:30:00Z], store,
        projections: [StatsProjection, AgentListProjection],
        aggregates: ["agent-1", "agent-2"]
      )
      
      assert state.projections.StatsProjection.total_events == 42
      assert state.aggregates["agent-1"].status == :active
  """
  def replay_to_timestamp(timestamp, store, opts \\ []) do
    projections = Keyword.get(opts, :projections, [])
    aggregates = Keyword.get(opts, :aggregates, [])
    include_future = Keyword.get(opts, :include_future, false)

    # Get all events up to timestamp
    all_events = get_all_events_before(timestamp, store, include_future)

    # Build projections
    projection_states =
      projections
      |> Enum.map(fn projection_module ->
        state = build_projection_at_time(projection_module, all_events)
        {projection_module, state}
      end)
      |> Map.new()

    # Build aggregate states
    aggregate_states =
      aggregates
      |> Enum.map(fn aggregate_id ->
        events =
          Enum.filter(all_events, fn e ->
            e.aggregate_id == aggregate_id or e.stream_id == aggregate_id
          end)

        state = replay_events_to_aggregate(events)
        {aggregate_id, state}
      end)
      |> Map.new()

    %{
      timestamp: timestamp,
      total_events: length(all_events),
      projections: projection_states,
      aggregates: aggregate_states
    }
  end

  @doc """
  Replays events until a specific event is encountered.

  ## Parameters
  - `stop_condition` - Function that returns true when to stop
  - `store` - The store instance
  - `opts` - Options passed to replay_to_timestamp

  ## Examples

      # Stop at specific event type
      state = replay_until_event(
        fn event -> event.type == :system_failure end,
        store
      )
      
      # Stop at specific event ID
      state = replay_until_event(
        fn event -> event.id == "event-123" end,
        store
      )
  """
  def replay_until_event(stop_condition, store, opts \\ []) do
    all_events = get_all_events(store)

    stop_index = Enum.find_index(all_events, stop_condition)

    if stop_index do
      stop_event = Enum.at(all_events, stop_index)
      replay_to_timestamp(stop_event.timestamp, store, opts)
    else
      # No matching event found - replay all
      last_event = List.last(all_events)
      timestamp = if last_event, do: last_event.timestamp, else: DateTime.utc_now()
      replay_to_timestamp(timestamp, store, opts)
    end
  end

  @doc """
  Creates a timeline snapshot showing state evolution.

  ## Parameters
  - `aggregate_id` - Aggregate to create timeline for
  - `store` - The store instance
  - `opts` - Options (optional)
    - `:interval` - Time interval for snapshots (default: :event)
    - `:fields` - Specific fields to track (default: all)

  ## Returns
  - List of timeline entries with timestamp, event, and state

  ## Examples

      timeline = create_timeline_snapshot("agent-123", store)
      
      # Track specific fields only
      timeline = create_timeline_snapshot("agent-123", store,
        fields: [:status, :message_count]
      )
  """
  def create_timeline_snapshot(aggregate_id, store, opts \\ []) do
    interval = Keyword.get(opts, :interval, :event)
    fields = Keyword.get(opts, :fields, :all)

    {:ok, events} = Store.read_events(aggregate_id, 0, :latest, store)

    case interval do
      :event ->
        create_event_based_timeline(events, fields)

      {:time, duration, unit} ->
        create_time_based_timeline(events, duration, unit, fields)
    end
  end

  @doc """
  Formats a timeline for display.

  ## Parameters
  - `timeline` - Timeline entries from create_timeline_snapshot
  - `opts` - Options (optional)
    - `:format` - Output format (:text, :markdown, :csv)

  ## Examples

      timeline = create_timeline_snapshot("agent-123", store)
      IO.puts(format_timeline(timeline))
  """
  def format_timeline(timeline, opts \\ []) do
    format = Keyword.get(opts, :format, :text)

    case format do
      :text -> format_timeline_text(timeline)
      :markdown -> format_timeline_markdown(timeline)
      :csv -> format_timeline_csv(timeline)
    end
  end

  @doc """
  Compares system state at two different timestamps.

  ## Parameters
  - `timestamp1` - First timestamp
  - `timestamp2` - Second timestamp  
  - `store` - The store instance
  - `opts` - Options for replay_to_timestamp

  ## Returns
  - Map with :before, :after, and :changes keys

  ## Examples

      comparison = compare_states_at_times(
        ~U[2024-01-15 10:00:00Z],
        ~U[2024-01-15 11:00:00Z],
        store,
        projections: [StatsProjection]
      )
      
      assert comparison.changes.total_events == {10, 25}
  """
  def compare_states_at_times(timestamp1, timestamp2, store, opts \\ []) do
    state1 = replay_to_timestamp(timestamp1, store, opts)
    state2 = replay_to_timestamp(timestamp2, store, opts)

    changes = deep_diff(state1, state2)

    %{
      before: state1,
      after: state2,
      changes: changes,
      time_diff: DateTime.diff(timestamp2, timestamp1)
    }
  end

  @doc """
  Finds events that match a pattern within a time window.

  ## Parameters
  - `pattern` - Pattern function or event type
  - `time_window` - {start_time, end_time} tuple
  - `store` - The store instance

  ## Examples

      # Find all errors in time window
      errors = find_events_in_window(
        fn e -> e.type in [:error, :failure] end,
        {~U[2024-01-15 10:00:00Z], ~U[2024-01-15 11:00:00Z]},
        store
      )
  """
  def find_events_in_window(pattern, {start_time, end_time}, store) do
    all_events = get_all_events(store)

    Enum.filter(all_events, fn event ->
      time_in_range =
        DateTime.compare(event.timestamp, start_time) in [:gt, :eq] and
          DateTime.compare(event.timestamp, end_time) in [:lt, :eq]

      pattern_match =
        case pattern do
          fun when is_function(fun) -> fun.(event)
          type when is_atom(type) -> event.type == type
        end

      time_in_range and pattern_match
    end)
  end

  @doc """
  Creates a debug report for a specific time period.

  ## Parameters
  - `aggregate_id` - Aggregate to debug
  - `time_range` - {start, end} or :all
  - `store` - The store instance

  ## Returns
  - Detailed debug report as string

  ## Examples

      report = create_debug_report("agent-123", 
        {~U[2024-01-15 10:00:00Z], ~U[2024-01-15 11:00:00Z]},
        store
      )
      
      IO.puts(report)
  """
  def create_debug_report(aggregate_id, time_range, store) do
    events =
      case time_range do
        :all ->
          {:ok, all} = Store.read_events(aggregate_id, 0, :latest, store)
          all

        {start_time, end_time} ->
          {:ok, all} = Store.read_events(aggregate_id, 0, :latest, store)

          Enum.filter(all, fn e ->
            DateTime.compare(e.timestamp, start_time) in [:gt, :eq] and
              DateTime.compare(e.timestamp, end_time) in [:lt, :eq]
          end)
      end

    timeline = create_event_based_timeline(events, :all)

    """
    Debug Report for Aggregate: #{aggregate_id}
    Time Range: #{format_time_range(time_range)}
    Total Events: #{length(events)}

    Event Timeline:
    #{format_timeline_text(timeline)}

    Event Details:
    #{format_event_details(events)}

    State Evolution:
    #{format_state_evolution(timeline)}
    """
  end

  # Private helpers

  defp get_all_events_before(timestamp, store, include_future) do
    all_events = get_all_events(store)

    if include_future do
      all_events
    else
      Enum.filter(all_events, fn event ->
        DateTime.compare(event.timestamp, timestamp) in [:lt, :eq]
      end)
    end
  end

  defp get_all_events(store) do
    # Get all events from all streams using the same method as projection helper
    case store do
      %{backend: :in_memory, backend_state: %{config_table: config_table}} ->
        case :ets.lookup(config_table, :stream_versions) do
          [{:stream_versions, versions}] ->
            stream_ids = Map.keys(versions)

            stream_ids
            |> Enum.flat_map(fn stream_id ->
              {:ok, events} = Store.read_events(stream_id, 0, :latest, store)
              events
            end)
            |> Enum.sort_by(& &1.timestamp)

          [] ->
            []
        end

      _ ->
        []
    end
  end

  defp build_projection_at_time(projection_module, events) do
    initial_state = projection_module.init()

    Enum.reduce(events, initial_state, fn event, state ->
      projection_module.handle_event(event, state)
    end)
  end

  defp replay_events_to_aggregate(events) do
    Enum.reduce(events, %{}, fn event, state ->
      default_reducer(event, state)
    end)
  end

  defp default_reducer(event, state) do
    # Use the same reducer logic as AggregateTestHelper for consistency
    case event.type do
      # Common event patterns
      type when type in [:created, :initialized, :started] ->
        Map.merge(state, event.data)

      :updated ->
        Map.merge(state, event.data)

      :terminated ->
        Map.put(state, :status, :terminated)

      # Handle specific Arbor agent events
      :agent_started ->
        state
        |> Map.put(:status, :started)
        |> Map.put(:started_at, event.timestamp)
        |> Map.merge(event.data)

      :agent_configured ->
        # Merge event data first, then explicitly set configured to true
        # This ensures the configured field is always true regardless of what's in event.data
        new_state = Map.merge(state, event.data)
        Map.put(new_state, :configured, true)

      :agent_activated ->
        state
        |> Map.put(:status, :active)
        |> Map.put(:activated_at, event.timestamp)
        |> Map.merge(event.data)

      :agent_message_sent ->
        state
        |> Map.update(:message_count, 1, &(&1 + 1))
        |> Map.put(:last_message_at, event.timestamp)

      :agent_stopped ->
        state
        |> Map.put(:status, :stopped)
        |> Map.put(:stopped_at, event.timestamp)
        |> Map.merge(event.data)

      # Snapshot events
      :snapshot_taken ->
        Map.merge(state, Map.get(event.data, :state, %{}))

      # Generic handler - merge event data
      _ ->
        Map.merge(state, Map.get(event.data, :state_changes, event.data))
    end
  end

  defp create_event_based_timeline(events, fields) do
    {timeline, _} =
      Enum.reduce(events, {[], %{}}, fn event, {timeline_acc, state} ->
        new_state = Map.merge(state, event.data)

        entry = %{
          timestamp: event.timestamp,
          event_type: event.type,
          event_id: event.id,
          version: event.stream_version,
          state: filter_fields(new_state, fields),
          changes: calculate_changes(state, new_state, fields)
        }

        {[entry | timeline_acc], new_state}
      end)

    Enum.reverse(timeline)
  end

  defp create_time_based_timeline(events, duration, unit, fields) do
    # Group events by time intervals
    # Implementation would bucket events and show state at each interval
    create_event_based_timeline(events, fields)
  end

  defp filter_fields(state, :all), do: state

  defp filter_fields(state, fields) when is_list(fields) do
    Map.take(state, fields)
  end

  defp calculate_changes(old_state, new_state, fields) do
    keys =
      case fields do
        :all -> Map.keys(new_state)
        fields -> fields
      end

    Enum.reduce(keys, %{}, fn key, acc ->
      old_val = Map.get(old_state, key)
      new_val = Map.get(new_state, key)

      if old_val != new_val do
        Map.put(acc, key, {old_val, new_val})
      else
        acc
      end
    end)
  end

  defp format_timeline_text(timeline) do
    Enum.map_join(timeline, "\n", fn entry ->
      """
      [#{format_timestamp(entry.timestamp)}] #{entry.event_type} (v#{entry.version})
        State: #{inspect(entry.state)}
        Changes: #{inspect(entry.changes)}
      """
    end)
  end

  defp format_timeline_markdown(timeline) do
    header =
      "| Timestamp | Event | Version | State | Changes |\n|-----------|-------|---------|-------|---------|\n"

    rows =
      Enum.map_join(timeline, "\n", fn entry ->
        "| #{format_timestamp(entry.timestamp)} | #{entry.event_type} | #{entry.version} | #{inspect(entry.state)} | #{inspect(entry.changes)} |"
      end)

    header <> rows
  end

  defp format_timeline_csv(timeline) do
    header = "timestamp,event_type,version,state,changes\n"

    rows =
      Enum.map_join(timeline, "\n", fn entry ->
        ~s("#{format_timestamp(entry.timestamp)}","#{entry.event_type}","#{entry.version}","#{inspect(entry.state)}","#{inspect(entry.changes)}")
      end)

    header <> rows
  end

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_time_range(:all), do: "All Time"

  defp format_time_range({start_time, end_time}) do
    "#{format_timestamp(start_time)} to #{format_timestamp(end_time)}"
  end

  defp format_event_details(events) do
    Enum.map_join(events, "\n", fn event ->
      """
      Event: #{event.id}
        Type: #{event.type}
        Time: #{format_timestamp(event.timestamp)}
        Data: #{inspect(event.data, pretty: true)}
      """
    end)
  end

  defp format_state_evolution(timeline) do
    timeline
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [before_state, after_state] ->
      if after_state.changes != %{} do
        """
        After #{after_state.event_type}:
        #{format_changes(after_state.changes)}
        """
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp format_changes(changes) do
    Enum.map_join(changes, "\n", fn {field, {old, new}} ->
      "  #{field}: #{inspect(old)} → #{inspect(new)}"
    end)
  end

  defp deep_diff(map1, map2) when is_map(map1) and is_map(map2) do
    all_keys =
      MapSet.union(
        MapSet.new(Map.keys(map1)),
        MapSet.new(Map.keys(map2))
      )

    Enum.reduce(all_keys, %{}, fn key, acc ->
      val1 = Map.get(map1, key)
      val2 = Map.get(map2, key)

      cond do
        val1 == val2 ->
          acc

        is_map(val1) and is_map(val2) ->
          nested_diff = deep_diff(val1, val2)

          if map_size(nested_diff) > 0 do
            Map.put(acc, key, nested_diff)
          else
            acc
          end

        true ->
          Map.put(acc, key, {val1, val2})
      end
    end)
  end

  defp deep_diff(val1, val2), do: {val1, val2}
end
