defmodule Arbor.Persistence.AggregateTestHelper do
  @moduledoc """
  Test utilities for aggregate state reconstruction and validation.

  This module helps test aggregate behavior by reconstructing state from
  events and providing assertions for state validation. It supports testing
  aggregate invariants, state transitions, and version-specific states.

  ## Usage

      use Arbor.Persistence.FastCase
      import Arbor.Persistence.AggregateTestHelper
      
      test "aggregate state evolution", %{store: store} do
        # ... append events ...
        
        aggregate = replay_to_aggregate("agent-123", store)
        assert aggregate.status == :active
        
        # Or use direct assertion
        assert_aggregate_state("agent-123", %{status: :active}, store)
      end
  """

  import ExUnit.Assertions
  alias Arbor.Persistence.Store

  @doc """
  Replays events to reconstruct aggregate state.

  ## Parameters
  - `aggregate_id` - The aggregate identifier
  - `store` - The store instance
  - `opts` - Options (optional)
    - `:reducer` - Custom reducer function (default: generic reducer)
    - `:initial_state` - Initial state (default: %{})
    - `:up_to_version` - Stop at specific version (default: :latest)

  ## Examples

      # Simple replay
      state = replay_to_aggregate("agent-123", store)
      
      # With custom reducer
      state = replay_to_aggregate("agent-123", store, 
        reducer: &MyAggregate.apply_event/2
      )
      
      # Up to specific version
      state = replay_to_aggregate("agent-123", store, up_to_version: 5)
  """
  def replay_to_aggregate(aggregate_id, store, opts \\ []) do
    reducer = Keyword.get(opts, :reducer, &default_reducer/2)
    initial_state = Keyword.get(opts, :initial_state, %{})
    up_to_version = Keyword.get(opts, :up_to_version, :latest)

    # Use aggregate_id as stream_id for event sourcing
    stream_id = aggregate_id

    {:ok, events} = Store.read_events(stream_id, 0, up_to_version, store)

    Enum.reduce(events, initial_state, reducer)
  end

  @doc """
  Asserts that aggregate state matches expected values.

  ## Parameters
  - `aggregate_id` - The aggregate identifier
  - `expected_state` - Map of expected state values
  - `store` - The store instance
  - `opts` - Options passed to replay_to_aggregate

  ## Examples

      assert_aggregate_state("agent-123", %{
        status: :active,
        message_count: 5
      }, store)
      
      # With custom reducer
      assert_aggregate_state("agent-123", %{status: :active}, store,
        reducer: &MyAggregate.apply_event/2
      )
  """
  def assert_aggregate_state(aggregate_id, expected_state, store, opts \\ []) do
    actual_state = replay_to_aggregate(aggregate_id, store, opts)

    Enum.each(expected_state, fn {key, expected_value} ->
      actual_value = Map.get(actual_state, key)

      assert actual_value == expected_value,
             """
             Aggregate state mismatch for #{aggregate_id}.#{key}
             Expected: #{inspect(expected_value)}
             Actual:   #{inspect(actual_value)}
             Full state: #{inspect(actual_state)}
             """
    end)
  end

  @doc """
  Gets aggregate state at a specific version.

  ## Parameters
  - `aggregate_id` - The aggregate identifier
  - `version` - The version to replay up to
  - `store` - The store instance
  - `opts` - Options passed to replay_to_aggregate

  ## Examples

      # Get state at version 3
      state_v3 = get_aggregate_at_version("agent-123", 3, store)
      
      # Compare states at different versions
      state_v1 = get_aggregate_at_version("agent-123", 1, store)
      state_v5 = get_aggregate_at_version("agent-123", 5, store)
      assert state_v1.status == :pending
      assert state_v5.status == :active
  """
  def get_aggregate_at_version(aggregate_id, version, store, opts \\ []) do
    replay_to_aggregate(aggregate_id, store, Keyword.put(opts, :up_to_version, version))
  end

  @doc """
  Asserts aggregate invariants hold across all versions.

  ## Parameters
  - `aggregate_id` - The aggregate identifier
  - `invariant_fn` - Function that returns true if invariant holds
  - `store` - The store instance
  - `opts` - Options passed to replay_to_aggregate

  ## Examples

      # Balance should never be negative
      assert_aggregate_invariant("account-123", fn state ->
        Map.get(state, :balance, 0) >= 0
      end, store)
      
      # Status transitions must be valid
      assert_aggregate_invariant("agent-123", fn state ->
        state.status in [:pending, :active, :suspended, :terminated]
      end, store)
  """
  def assert_aggregate_invariant(aggregate_id, invariant_fn, store, opts \\ []) do
    stream_id = aggregate_id
    {:ok, events} = Store.read_events(stream_id, 0, :latest, store)

    reducer = Keyword.get(opts, :reducer, &default_reducer/2)
    initial_state = Keyword.get(opts, :initial_state, %{})

    # Check invariant at each version
    {_, violations} =
      Enum.reduce(events, {initial_state, []}, fn event, {state, violations} ->
        new_state = reducer.(event, state)

        if invariant_fn.(new_state) do
          {new_state, violations}
        else
          violation = %{
            version: event.stream_version,
            event_type: event.type,
            event_id: event.id,
            state: new_state
          }

          {new_state, [violation | violations]}
        end
      end)

    assert violations == [],
           """
           Aggregate invariant violated for #{aggregate_id}
           Violations at versions: #{violations |> Enum.map(& &1.version) |> inspect()}

           Details:
           #{format_violations(violations)}
           """
  end

  @doc """
  Compares aggregate states at two different versions.

  ## Parameters
  - `aggregate_id` - The aggregate identifier
  - `version1` - First version to compare
  - `version2` - Second version to compare
  - `store` - The store instance
  - `opts` - Options passed to replay_to_aggregate

  ## Returns
  - `{:ok, differences}` - Map of fields that changed

  ## Examples

      {:ok, changes} = diff_aggregate_versions("agent-123", 1, 5, store)
      assert changes.status == {:pending, :active}
      assert changes.message_count == {0, 10}
  """
  def diff_aggregate_versions(aggregate_id, version1, version2, store, opts \\ []) do
    state1 = get_aggregate_at_version(aggregate_id, version1, store, opts)
    state2 = get_aggregate_at_version(aggregate_id, version2, store, opts)

    all_keys =
      MapSet.union(
        MapSet.new(Map.keys(state1)),
        MapSet.new(Map.keys(state2))
      )

    differences =
      all_keys
      |> Enum.reduce(%{}, fn key, acc ->
        val1 = Map.get(state1, key)
        val2 = Map.get(state2, key)

        if val1 == val2 do
          acc
        else
          Map.put(acc, key, {val1, val2})
        end
      end)

    {:ok, differences}
  end

  @doc """
  Asserts that applying an event produces expected state changes.

  ## Parameters
  - `initial_state` - Starting state
  - `event` - Event to apply
  - `expected_changes` - Map of expected state changes
  - `opts` - Options
    - `:reducer` - Custom reducer function

  ## Examples

      initial = %{status: :pending, count: 0}
      event = build_test_event(:agent_activated)
      
      assert_state_transition(initial, event, %{
        status: :active,
        count: 1
      })
  """
  def assert_state_transition(initial_state, event, expected_changes, opts \\ []) do
    reducer = Keyword.get(opts, :reducer, &default_reducer/2)

    new_state = reducer.(event, initial_state)

    Enum.each(expected_changes, fn {key, expected_value} ->
      actual_value = Map.get(new_state, key)

      assert actual_value == expected_value,
             """
             State transition failed for key: #{key}
             Event type: #{event.type}
             Expected: #{inspect(expected_value)}
             Actual:   #{inspect(actual_value)}
             Initial state: #{inspect(initial_state)}
             Final state: #{inspect(new_state)}
             """
    end)
  end

  # Private helpers

  # Default generic reducer that builds state from event data
  defp default_reducer(event, state) do
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

  defp format_violations(violations) do
    violations
    |> Enum.reverse()
    |> Enum.map_join("\n", fn v ->
      """
      Version #{v.version} (Event: #{v.event_type}, ID: #{v.event_id})
      State: #{inspect(v.state, pretty: true)}
      """
    end)
  end
end
