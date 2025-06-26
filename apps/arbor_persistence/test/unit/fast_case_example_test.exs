defmodule Arbor.Persistence.Unit.FastCaseExampleTest do
  @moduledoc """
  Example test demonstrating FastCase usage patterns.

  This test shows how to write fast unit tests using in-memory persistence
  for rapid feedback during development.
  """

  use Arbor.Persistence.FastCase

  # FastCase tests are automatically tagged with:
  # - persistence: :mock
  # - :fast 
  # - async: true

  test "basic event sourcing workflow", %{store: store} do
    # Create test events using helpers
    stream_id = unique_stream_id("agent-lifecycle")

    events =
      build_event_sequence(stream_id, [
        :agent_started,
        :agent_message_sent,
        :agent_stopped
      ])

    # Append events to stream
    {:ok, final_version} = Store.append_events(stream_id, events, -1, store)
    assert final_version == 2

    # Read events back
    {:ok, retrieved_events} = Store.read_events(stream_id, 0, :latest, store)
    assert length(retrieved_events) == 3

    # Verify event sequence
    types = Enum.map(retrieved_events, & &1.type)
    assert types == [:agent_started, :agent_message_sent, :agent_stopped]
  end

  test "event validation with custom data", %{store: store} do
    # Create event with custom data
    event =
      build_test_event(:session_created,
        data: %{
          session_id: "test-session-123",
          user_preferences: %{theme: "dark", language: "en"}
        }
      )

    stream_id = unique_stream_id("session")
    {:ok, _version} = Store.append_events(stream_id, [event], -1, store)

    # Verify data preservation in in-memory store
    {:ok, [retrieved_event]} = Store.read_events(stream_id, 0, :latest, store)
    assert retrieved_event.data.session_id == "test-session-123"
    assert retrieved_event.data.user_preferences.theme == "dark"
  end

  test "snapshot operations", %{store: store} do
    # Create and store a snapshot
    snapshot =
      build_test_snapshot("agent-123",
        snapshot_version: 5,
        state: %{
          current_task: "analysis",
          processed_messages: 15,
          status: "active"
        }
      )

    {:ok, _} = Store.save_snapshot("agent-123", snapshot, store)

    # Retrieve the snapshot
    {:ok, retrieved_snapshot} = Store.load_snapshot("agent-123", store)
    assert retrieved_snapshot.snapshot_version == 5
    assert retrieved_snapshot.state.current_task == "analysis"
  end

  test "version conflict detection", %{store: store} do
    stream_id = unique_stream_id("conflict-test")
    event = build_test_event(:agent_started, stream_id: stream_id)

    # First append should succeed
    {:ok, _version} = Store.append_events(stream_id, [event], -1, store)

    # Second append with same expected version should fail
    event2 = build_test_event(:agent_message_sent, stream_id: stream_id)

    assert {:error, :version_conflict} =
             Store.append_events(stream_id, [event2], -1, store)
  end

  test "stream reading with version ranges", %{store: store} do
    stream_id = unique_stream_id("version-range")

    # Create sequence of 5 events
    events =
      for i <- 0..4 do
        build_test_event(:agent_message_sent,
          stream_id: stream_id,
          stream_version: i,
          data: %{message_number: i}
        )
      end

    {:ok, _final_version} = Store.append_events(stream_id, events, -1, store)

    # Read specific range
    {:ok, range_events} = Store.read_events(stream_id, 1, 3, store)
    assert length(range_events) == 3

    # Verify we got the right events
    message_numbers = Enum.map(range_events, & &1.data.message_number)
    assert message_numbers == [1, 2, 3]
  end

  test "concurrent stream operations (simulated)", %{store: store} do
    # FastCase runs async: true, so we can test concurrent-like scenarios
    stream_id = unique_stream_id("concurrent")

    # Simulate multiple operations on same stream
    tasks =
      for i <- 1..5 do
        Task.async(fn ->
          event =
            build_test_event(:agent_message_sent,
              stream_id: stream_id,
              data: %{task_id: i}
            )

          # Each task tries to append (some may fail due to version conflicts)
          Store.append_events(stream_id, [event], -1, store)
        end)
      end

    results = Task.await_many(tasks)

    # At least one should succeed
    successful_appends =
      Enum.count(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    assert successful_appends >= 1
  end
end
