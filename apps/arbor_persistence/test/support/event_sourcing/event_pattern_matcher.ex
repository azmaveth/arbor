defmodule Arbor.Persistence.EventPatternMatcher do
  @moduledoc """
  High-level assertions for common event sourcing patterns.

  This module provides domain-specific assertions for testing common
  patterns in event-sourced systems like command-event causality,
  saga completion, compensation patterns, and workflow transitions.

  ## Usage

      use Arbor.Persistence.FastCase
      import Arbor.Persistence.EventPatternMatcher
      
      test "command triggers expected events", %{store: store} do
        command_id = Ecto.UUID.generate()
        
        # Execute command that should produce events...
        
        assert_command_event_pattern(command_id, [
          {:agent_started, %{status: :initializing}},
          {:agent_configured, %{model: "claude-3"}},
          {:agent_activated, %{status: :active}}
        ], store)
      end
  """

  import ExUnit.Assertions
  import Arbor.Persistence.EventStreamAssertions
  alias Arbor.Persistence.Store

  @doc """
  Asserts that a command produced expected events with causality.

  ## Parameters
  - `command_id` - The command ID (used as correlation_id)
  - `expected_patterns` - List of {event_type, data_matcher} tuples
  - `store` - The store instance
  - `opts` - Options (optional)
    - `:stream_id` - Specific stream to check (default: searches all)
    - `:timeout` - Max time to wait for events (default: 1000ms)

  ## Examples

      assert_command_event_pattern(command_id, [
        {:order_placed, %{total: 99.99}},
        {:payment_processed, %{status: "success"}},
        {:order_confirmed, %{}}
      ], store)
  """
  def assert_command_event_pattern(command_id, expected_patterns, store, opts \\ []) do
    stream_id = Keyword.get(opts, :stream_id)
    timeout = Keyword.get(opts, :timeout, 1000)

    deadline = System.monotonic_time(:millisecond) + timeout

    assert_command_pattern_loop(command_id, expected_patterns, store, stream_id, deadline)
  end

  @doc """
  Asserts that a saga completed successfully with all expected steps.

  ## Parameters
  - `saga_id` - The saga identifier (correlation_id)
  - `expected_steps` - List of expected event types in order
  - `store` - The store instance
  - `opts` - Options (optional)
    - `:allow_compensation` - Allow compensation events (default: false)

  ## Examples

      assert_saga_completion("transfer-123", [
        :transfer_initiated,
        :source_account_debited,
        :destination_account_credited,
        :transfer_completed
      ], store)
  """
  def assert_saga_completion(saga_id, expected_steps, store, opts \\ []) do
    allow_compensation = Keyword.get(opts, :allow_compensation, false)

    # Find all events with this saga_id as correlation_id
    events = find_events_by_correlation(saga_id, store)

    assert length(events) > 0,
           "No events found for saga #{saga_id}"

    event_types = Enum.map(events, & &1.type)

    # Check for compensation events
    compensation_events = Enum.filter(event_types, &is_compensation_event?/1)

    if compensation_events != [] and not allow_compensation do
      flunk("""
      Saga #{saga_id} included compensation events: #{inspect(compensation_events)}
      This indicates the saga was rolled back.
      Event sequence: #{inspect(event_types)}
      """)
    end

    # Verify expected steps occurred
    assert_event_sequence_flexible(event_types, expected_steps, saga_id)

    # Verify causality chain
    assert_causality_chain(events, allow_gaps: true)
  end

  @doc """
  Asserts that a compensation/rollback pattern was executed correctly.

  ## Parameters
  - `transaction_id` - The transaction identifier
  - `forward_events` - Expected forward path events
  - `compensation_events` - Expected compensation events
  - `store` - The store instance

  ## Examples

      assert_compensation_pattern("order-123", 
        forward: [:order_placed, :inventory_reserved, :payment_failed],
        compensation: [:inventory_released, :order_cancelled],
        store: store
      )
  """
  def assert_compensation_pattern(transaction_id, pattern_spec, store) do
    forward_events = Keyword.fetch!(pattern_spec, :forward)
    compensation_events = Keyword.fetch!(pattern_spec, :compensation)

    events = find_events_by_correlation(transaction_id, store)
    event_types = Enum.map(events, & &1.type)

    # Find the pivot point (where compensation starts)
    {forward_actual, compensation_actual} =
      split_at_compensation(event_types)

    # Verify forward path (may be incomplete)
    assert_event_prefix(
      forward_actual,
      forward_events,
      "Forward path mismatch for transaction #{transaction_id}"
    )

    # Verify compensation path
    assert compensation_actual == compensation_events,
           """
           Compensation path mismatch for transaction #{transaction_id}
           Expected: #{inspect(compensation_events)}
           Actual:   #{inspect(compensation_actual)}
           Full sequence: #{inspect(event_types)}
           """
  end

  @doc """
  Asserts workflow state transitions follow expected pattern.

  ## Parameters
  - `workflow_id` - The workflow identifier
  - `transitions` - List of {from_state, event, to_state} tuples
  - `store` - The store instance

  ## Examples

      assert_workflow_transitions("job-123", [
        {:pending, :job_started, :running},
        {:running, :job_progress, :running},
        {:running, :job_completed, :completed}
      ], store)
  """
  def assert_workflow_transitions(workflow_id, transitions, store) do
    events = find_events_by_aggregate(workflow_id, store)

    # Build state timeline
    states = build_state_timeline(events)

    # Verify each transition
    Enum.each(transitions, fn {from_state, event_type, to_state} ->
      assert_transition_occurred(states, from_state, event_type, to_state, workflow_id)
    end)
  end

  @doc """
  Asserts events follow a specific temporal pattern.

  ## Parameters
  - `pattern` - Pattern specification
  - `store` - The store instance

  ## Examples

      # Events must occur within time window
      assert_temporal_pattern([
        {:agent_started, within: {0, :seconds}},
        {:agent_configured, within: {5, :seconds}},
        {:agent_activated, within: {10, :seconds}}
      ], "agent-123", store)
  """
  def assert_temporal_pattern(pattern, aggregate_id, store) do
    {:ok, events} = Store.read_events(aggregate_id, 0, :latest, store)

    assert length(events) >= length(pattern),
           "Not enough events to match temporal pattern"

    base_time = hd(events).timestamp

    pattern
    |> Enum.with_index()
    |> Enum.each(fn {{expected_type, constraints}, index} ->
      event = Enum.at(events, index)

      assert event.type == expected_type,
             "Event type mismatch at position #{index}. Expected #{expected_type}, got #{event.type}"

      case constraints[:within] do
        {max_duration, unit} ->
          max_ms = time_to_ms(max_duration, unit)
          actual_ms = DateTime.diff(event.timestamp, base_time, :millisecond)

          assert actual_ms <= max_ms,
                 """
                 Event #{expected_type} occurred too late
                 Expected within: #{max_duration} #{unit}
                 Actual: #{actual_ms}ms
                 """

        _ ->
          :ok
      end
    end)
  end

  @doc """
  Asserts that concurrent operations resolved correctly.

  ## Parameters
  - `resource_id` - The resource being operated on
  - `expected_winner` - The operation that should have won
  - `store` - The store instance

  ## Examples

      # Two concurrent updates, only one should succeed
      assert_concurrent_resolution("account-123", 
        winner: :credit_operation,
        loser: :debit_operation,
        store: store
      )
  """
  def assert_concurrent_resolution(resource_id, resolution_spec, store) do
    winner = Keyword.fetch!(resolution_spec, :winner)
    loser = Keyword.fetch!(resolution_spec, :loser)

    events = find_events_by_aggregate(resource_id, store)
    event_types = Enum.map(events, & &1.type)

    # Winner should have succeeded
    assert winner in event_types,
           "Expected winning operation #{winner} not found in events: #{inspect(event_types)}"

    # Loser should have been rejected or compensated
    loser_compensated =
      :"#{loser}_rejected" in event_types or
        :"#{loser}_rolled_back" in event_types

    assert loser_compensated,
           "Expected losing operation #{loser} to be rejected or rolled back"
  end

  # Private helpers

  defp assert_command_pattern_loop(command_id, expected_patterns, store, stream_id, deadline) do
    current_time = System.monotonic_time(:millisecond)

    if current_time > deadline do
      events = find_events_by_correlation(command_id, store)

      flunk("""
      Command #{command_id} did not produce expected events within timeout
      Expected patterns: #{inspect(expected_patterns)}
      Actual events: #{inspect(Enum.map(events, & &1.type))}
      """)
    end

    events =
      if stream_id do
        {:ok, stream_events} = Store.read_events(stream_id, 0, :latest, store)
        Enum.filter(stream_events, fn e -> e.correlation_id == command_id end)
      else
        find_events_by_correlation(command_id, store)
      end

    if matches_patterns?(events, expected_patterns) do
      :ok
    else
      Process.sleep(50)
      assert_command_pattern_loop(command_id, expected_patterns, store, stream_id, deadline)
    end
  end

  defp matches_patterns?(events, expected_patterns) do
    length(events) >= length(expected_patterns) and
      expected_patterns
      |> Enum.with_index()
      |> Enum.all?(fn {{expected_type, data_pattern}, index} ->
        case Enum.at(events, index) do
          nil ->
            false

          event ->
            event.type == expected_type and
              matches_data_pattern?(event.data, data_pattern)
        end
      end)
  end

  defp matches_data_pattern?(data, pattern) when is_map(pattern) do
    Enum.all?(pattern, fn {key, expected_value} ->
      Map.get(data, key) == expected_value or
        Map.get(data, to_string(key)) == expected_value
    end)
  end

  defp matches_data_pattern?(_data, nil), do: true

  defp is_compensation_event?(event_type) do
    event_type
    |> to_string()
    |> String.contains?(["rollback", "compensate", "cancel", "revert", "undo"])
  end

  defp find_events_by_correlation(correlation_id, store) do
    # Simplified - in real implementation would query by correlation_id
    all_streams = list_all_streams(store)

    all_streams
    |> Enum.flat_map(fn stream_id ->
      {:ok, events} = Store.read_events(stream_id, 0, :latest, store)
      Enum.filter(events, fn e -> e.correlation_id == correlation_id end)
    end)
    |> Enum.sort_by(& &1.timestamp)
  end

  defp find_events_by_aggregate(aggregate_id, store) do
    {:ok, events} = Store.read_events(aggregate_id, 0, :latest, store)
    events
  end

  defp assert_event_sequence_flexible(actual_types, expected_types, context) do
    expected_set = MapSet.new(expected_types)
    actual_set = MapSet.new(actual_types)

    missing = MapSet.difference(expected_set, actual_set)

    assert MapSet.size(missing) == 0,
           """
           Missing expected events for #{context}
           Missing: #{inspect(MapSet.to_list(missing))}
           Actual sequence: #{inspect(actual_types)}
           """
  end

  defp split_at_compensation(event_types) do
    compensation_index =
      Enum.find_index(event_types, &is_compensation_event?/1)

    if compensation_index do
      Enum.split(event_types, compensation_index)
    else
      {event_types, []}
    end
  end

  defp assert_event_prefix(actual, expected_prefix, message) do
    actual_prefix = Enum.take(actual, length(expected_prefix))
    assert actual_prefix == expected_prefix, message
  end

  defp build_state_timeline(events) do
    events
    |> Enum.map(fn event ->
      %{
        timestamp: event.timestamp,
        event_type: event.type,
        state: Map.get(event.data, :state) || Map.get(event.data, :status)
      }
    end)
  end

  defp assert_transition_occurred(states, from_state, event_type, to_state, context) do
    transition_found =
      states
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.any?(fn [state1, state2] ->
        state1.state == from_state and
          state2.event_type == event_type and
          state2.state == to_state
      end)

    assert transition_found,
           """
           Transition not found in workflow #{context}
           Expected: #{from_state} --[#{event_type}]--> #{to_state}
           States: #{inspect(states, pretty: true)}
           """
  end

  defp time_to_ms(value, :milliseconds), do: value
  defp time_to_ms(value, :seconds), do: value * 1000
  defp time_to_ms(value, :minutes), do: value * 60 * 1000

  defp list_all_streams(store) do
    case store do
      %{backend: :in_memory, backend_state: %{config_table: config_table}} ->
        case :ets.lookup(config_table, :stream_versions) do
          [{:stream_versions, versions}] -> Map.keys(versions)
          [] -> []
        end

      _ ->
        []
    end
  end
end
