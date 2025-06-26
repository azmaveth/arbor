defmodule Arbor.Persistence.EventStreamAssertions do
  @moduledoc """
  Core assertions for event stream verification in tests.

  This module provides essential assertions for verifying event sequences,
  ordering, causality chains, and stream integrity. It's the foundation
  module that other event sourcing test utilities build upon.

  ## Usage

      use Arbor.Persistence.FastCase
      import Arbor.Persistence.EventStreamAssertions
      
      test "event ordering", %{store: store} do
        # ... append events ...
        
        assert_event_sequence(stream_id, [:started, :configured, :activated], store)
        assert_stream_version(stream_id, 2, store)
      end
  """

  import ExUnit.Assertions
  alias Arbor.Persistence.Store

  @doc """
  Asserts that events in a stream match the expected sequence of types.

  ## Parameters
  - `stream_id` - The stream to verify
  - `expected_types` - List of expected event types in order
  - `store` - The store instance
  - `opts` - Options (optional)
    - `:from_version` - Start checking from this version (default: 0)
    - `:strict` - If true, no other events allowed (default: true)

  ## Examples

      assert_event_sequence("agent-123", [:agent_started, :agent_configured], store)
      
      # Allow other events between expected ones
      assert_event_sequence("agent-123", [:agent_started, :agent_stopped], store, strict: false)
  """
  def assert_event_sequence(stream_id, expected_types, store, opts \\ []) do
    from_version = Keyword.get(opts, :from_version, 0)
    strict = Keyword.get(opts, :strict, true)

    {:ok, events} = Store.read_events(stream_id, from_version, :latest, store)
    actual_types = Enum.map(events, & &1.type)

    if strict do
      assert actual_types == expected_types,
             """
             Event sequence mismatch for stream #{stream_id}
             Expected: #{inspect(expected_types)}
             Actual:   #{inspect(actual_types)}
             """
    else
      assert_subsequence(actual_types, expected_types, stream_id)
    end
  end

  @doc """
  Asserts that events are linked by causation IDs forming a valid chain.

  ## Parameters
  - `events` - List of events to verify
  - `opts` - Options (optional)
    - `:allow_gaps` - Allow missing events in chain (default: false)

  ## Examples

      {:ok, events} = Store.read_events(stream_id, 0, :latest, store)
      assert_causality_chain(events)
  """
  def assert_causality_chain(events, opts \\ []) do
    allow_gaps = Keyword.get(opts, :allow_gaps, false)

    events
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [event1, event2] ->
      if event2.causation_id do
        if allow_gaps do
          # Just verify causation_id exists somewhere in the chain
          assert event_exists_with_id?(events, event2.causation_id),
                 "Event #{event2.id} has causation_id #{event2.causation_id} which doesn't exist in the chain"
        else
          # Strict: causation_id must point to previous event
          assert event2.causation_id == event1.id,
                 "Event #{event2.id} causation_id doesn't point to previous event. Expected #{event1.id}, got #{event2.causation_id}"
        end
      end
    end)
  end

  @doc """
  Asserts that a stream has reached a specific version.

  ## Parameters
  - `stream_id` - The stream to check
  - `expected_version` - Expected current version
  - `store` - The store instance

  ## Examples

      assert_stream_version("agent-123", 5, store)
  """
  def assert_stream_version(stream_id, expected_version, store) do
    {:ok, events} = Store.read_events(stream_id, 0, :latest, store)

    case events do
      [] ->
        assert expected_version == -1,
               "Expected stream #{stream_id} to have version #{expected_version}, but stream is empty (version -1)"

      events ->
        last_event = List.last(events)
        actual_version = last_event.stream_version

        assert actual_version == expected_version,
               "Expected stream #{stream_id} to have version #{expected_version}, but got #{actual_version}"
    end
  end

  @doc """
  Refutes that any events exist after a specific version or timestamp.

  ## Parameters
  - `stream_id` - The stream to check
  - `boundary` - Either a version number or DateTime
  - `store` - The store instance

  ## Examples

      # No events after version 3
      refute_events_after(stream_id, 3, store)
      
      # No events after timestamp
      refute_events_after(stream_id, ~U[2024-01-01 12:00:00Z], store)
  """
  def refute_events_after(stream_id, boundary, store) when is_integer(boundary) do
    {:ok, events} = Store.read_events(stream_id, boundary + 1, :latest, store)

    assert events == [],
           "Expected no events after version #{boundary} in stream #{stream_id}, but found #{length(events)} events"
  end

  def refute_events_after(stream_id, %DateTime{} = boundary, store) do
    {:ok, events} = Store.read_events(stream_id, 0, :latest, store)

    events_after =
      Enum.filter(events, fn event ->
        DateTime.compare(event.timestamp, boundary) == :gt
      end)

    assert events_after == [],
           "Expected no events after #{boundary} in stream #{stream_id}, but found #{length(events_after)} events"
  end

  @doc """
  Asserts that all events in a stream have valid metadata.

  ## Parameters
  - `stream_id` - The stream to verify
  - `required_keys` - List of required metadata keys
  - `store` - The store instance

  ## Examples

      assert_event_metadata(stream_id, [:user_id, :session_id], store)
  """
  def assert_event_metadata(stream_id, required_keys, store) do
    {:ok, events} = Store.read_events(stream_id, 0, :latest, store)

    Enum.each(events, fn event ->
      Enum.each(required_keys, fn key ->
        assert Map.has_key?(event.metadata, key),
               "Event #{event.id} missing required metadata key: #{key}"
      end)
    end)
  end

  @doc """
  Asserts events have monotonically increasing timestamps.

  ## Parameters
  - `stream_id` - The stream to verify
  - `store` - The store instance

  ## Examples

      assert_timestamp_ordering(stream_id, store)
  """
  def assert_timestamp_ordering(stream_id, store) do
    {:ok, events} = Store.read_events(stream_id, 0, :latest, store)

    events
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [event1, event2] ->
      comparison = DateTime.compare(event1.timestamp, event2.timestamp)

      assert comparison in [:lt, :eq],
             "Event timestamps not in order. Event #{event1.id} at #{event1.timestamp} comes before #{event2.id} at #{event2.timestamp}"
    end)
  end

  # Private helpers

  defp assert_subsequence(actual, expected, stream_id) do
    found = find_subsequence(actual, expected)

    assert found,
           """
           Expected event types not found in sequence for stream #{stream_id}
           Looking for: #{inspect(expected)}
           In sequence: #{inspect(actual)}
           """
  end

  defp find_subsequence([], []), do: true
  defp find_subsequence(_, []), do: true
  defp find_subsequence([], _expected), do: false

  defp find_subsequence([h | rest_actual], [h | rest_expected]) do
    find_subsequence(rest_actual, rest_expected)
  end

  defp find_subsequence([_ | rest_actual], expected) do
    find_subsequence(rest_actual, expected)
  end

  defp event_exists_with_id?(events, event_id) do
    Enum.any?(events, fn event -> event.id == event_id end)
  end
end
