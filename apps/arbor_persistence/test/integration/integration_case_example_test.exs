defmodule Arbor.Persistence.Integration.IntegrationCaseExampleTest do
  @moduledoc """
  Example test demonstrating IntegrationCase usage patterns.

  This test shows how to write integration tests that use real PostgreSQL
  (when Docker is available) or gracefully fall back to in-memory persistence.
  """

  use Arbor.Persistence.IntegrationCase

  # IntegrationCase tests are automatically tagged with:
  # - :integration
  # - async: false (required for Ecto Sandbox)

  test "realistic event sourcing with JSON serialization", %{store: store, test_backend: backend} do
    # Create complex event data to test serialization
    complex_data = %{
      agent_config: %{
        model: "claude-4",
        temperature: 0.7,
        max_tokens: 2048,
        system_prompt: "You are a helpful assistant"
      },
      capabilities: ["reasoning", "analysis", "coding"],
      metadata: %{
        created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        version: "1.0.0",
        experimental_features: true
      }
    }

    event = build_test_event(:agent_started, data: complex_data)
    stream_id = unique_stream_id("realistic")

    {:ok, _version} = Store.append_events(stream_id, [event], -1, store)
    {:ok, [retrieved_event]} = Store.read_events(stream_id, 0, :latest, store)

    case backend do
      :postgresql ->
        # PostgreSQL converts atom keys to strings through JSON serialization
        assert retrieved_event.data["agent_config"]["model"] == "claude-4"
        assert retrieved_event.data["capabilities"] == ["reasoning", "analysis", "coding"]
        assert retrieved_event.data["metadata"]["experimental_features"] == true

      :in_memory ->
        # In-memory preserves original structure
        assert retrieved_event.data.agent_config.model == "claude-4"
        assert retrieved_event.data.capabilities == ["reasoning", "analysis", "coding"]
        assert retrieved_event.data.metadata.experimental_features == true
    end
  end

  test "transaction rollback behavior", %{store: store, test_backend: backend} do
    case backend do
      :postgresql ->
        # Test that failed operations don't leave partial state
        stream_id = unique_stream_id("transaction-test")

        # First, create a valid event
        valid_event = build_test_event(:agent_started, stream_id: stream_id)
        {:ok, _version} = Store.append_events(stream_id, [valid_event], -1, store)

        # Verify we have 1 event
        {:ok, %{num_rows: [[count_before]]}} =
          Repo.query("SELECT COUNT(*) FROM events WHERE stream_id = $1", [stream_id])

        assert count_before == 1

        # Try to append with wrong expected version (should fail)
        invalid_event = build_test_event(:agent_message_sent, stream_id: stream_id)
        assert {:error, _} = Store.append_events(stream_id, [invalid_event], -1, store)

        # Verify we still have only 1 event (no partial commit)
        {:ok, %{num_rows: [[count_after]]}} =
          Repo.query("SELECT COUNT(*) FROM events WHERE stream_id = $1", [stream_id])

        assert count_after == 1

      :in_memory ->
        # In-memory tests don't have transaction rollback, but we can test basic consistency
        stream_id = unique_stream_id("consistency-test")

        event = build_test_event(:agent_started, stream_id: stream_id)
        {:ok, _version} = Store.append_events(stream_id, [event], -1, store)

        # Verify append with wrong version fails cleanly
        invalid_event = build_test_event(:agent_message_sent, stream_id: stream_id)
        assert {:error, _} = Store.append_events(stream_id, [invalid_event], -1, store)

        # Original event should still be there
        {:ok, events} = Store.read_events(stream_id, 0, :latest, store)
        assert length(events) == 1
    end
  end

  test "large event streams and pagination", %{store: store, test_backend: backend} do
    stream_id = unique_stream_id("large-stream")

    # Create a large number of events to test pagination
    event_count = 50

    events =
      for i <- 0..(event_count - 1) do
        build_test_event(:agent_message_sent,
          stream_id: stream_id,
          stream_version: i,
          data: %{
            sequence_number: i,
            message: "Message #{i}",
            timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
          }
        )
      end

    # Append all events
    {:ok, final_version} = Store.append_events(stream_id, events, -1, store)
    assert final_version == event_count - 1

    case backend do
      :postgresql ->
        # Test database-level pagination
        {:ok, %{num_rows: [[total_count]]}} =
          Repo.query(
            "SELECT COUNT(*) FROM events WHERE stream_id = $1",
            [stream_id]
          )

        assert total_count == event_count

        # Test reading in chunks
        {:ok, first_chunk} = Store.read_events(stream_id, 0, 9, store)
        assert length(first_chunk) == 10

        {:ok, second_chunk} = Store.read_events(stream_id, 10, 19, store)
        assert length(second_chunk) == 10

        # Verify sequence numbers
        first_sequences =
          Enum.map(first_chunk, fn event ->
            case backend do
              :postgresql -> event.data["sequence_number"]
              :in_memory -> event.data.sequence_number
            end
          end)

        assert first_sequences == Enum.to_list(0..9)

      :in_memory ->
        # Test in-memory pagination
        {:ok, all_events} = Store.read_events(stream_id, 0, :latest, store)
        assert length(all_events) == event_count

        # Test reading subsets
        {:ok, first_ten} = Store.read_events(stream_id, 0, 9, store)
        assert length(first_ten) == 10

        sequences = Enum.map(first_ten, & &1.data.sequence_number)
        assert sequences == Enum.to_list(0..9)
    end
  end

  test "snapshot storage and retrieval with complex data", %{store: store, test_backend: backend} do
    aggregate_id = "complex-agent-#{:erlang.unique_integer([:positive])}"

    # Create complex snapshot data
    complex_state = %{
      conversation_history: [
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there!"}
      ],
      agent_memory: %{
        facts: ["User prefers concise responses", "Working on Elixir project"],
        context_window: 4096,
        last_updated: DateTime.utc_now() |> DateTime.to_iso8601()
      },
      performance_metrics: %{
        avg_response_time_ms: 150,
        total_messages: 42,
        error_rate: 0.02
      }
    }

    snapshot =
      build_test_snapshot(aggregate_id,
        snapshot_version: 10,
        state: complex_state
      )

    {:ok, _} = Store.save_snapshot(aggregate_id, snapshot, store)
    {:ok, retrieved_snapshot} = Store.load_snapshot(aggregate_id, store)

    assert retrieved_snapshot.aggregate_id == aggregate_id
    assert retrieved_snapshot.snapshot_version == 10

    case backend do
      :postgresql ->
        # PostgreSQL serializes through JSON
        assert retrieved_snapshot.state["performance_metrics"]["total_messages"] == 42
        assert length(retrieved_snapshot.state["conversation_history"]) == 2

      :in_memory ->
        # In-memory preserves structure
        assert retrieved_snapshot.state.performance_metrics.total_messages == 42
        assert length(retrieved_snapshot.state.conversation_history) == 2
    end
  end

  test "concurrent access simulation", %{store: store, test_backend: backend} do
    case backend do
      :postgresql ->
        # With real PostgreSQL, we can test actual concurrent behavior
        # Note: This is a simple simulation since tests run synchronously
        stream_id = unique_stream_id("concurrent")

        # Create initial event
        initial_event = build_test_event(:agent_started, stream_id: stream_id)
        {:ok, _version} = Store.append_events(stream_id, [initial_event], -1, store)

        # Simulate concurrent appends by multiple processes
        # (In real concurrent scenarios, one would succeed and others would get version conflicts)
        event1 =
          build_test_event(:agent_message_sent,
            stream_id: stream_id,
            data: %{source: "process_1"}
          )

        event2 =
          build_test_event(:agent_message_sent,
            stream_id: stream_id,
            data: %{source: "process_2"}
          )

        # First append should succeed
        {:ok, version1} = Store.append_events(stream_id, [event1], 0, store)
        assert version1 == 1

        # Second append with same expected version should fail
        assert {:error, :version_conflict} = Store.append_events(stream_id, [event2], 0, store)

        # Verify only 2 events total (initial + first append)
        {:ok, events} = Store.read_events(stream_id, 0, :latest, store)
        assert length(events) == 2

      :in_memory ->
        # In-memory store still supports version conflict detection
        stream_id = unique_stream_id("concurrent-memory")

        event = build_test_event(:agent_started, stream_id: stream_id)
        {:ok, _version} = Store.append_events(stream_id, [event], -1, store)

        # Test version conflict in memory
        conflicting_event = build_test_event(:agent_message_sent, stream_id: stream_id)

        assert {:error, :version_conflict} =
                 Store.append_events(stream_id, [conflicting_event], -1, store)
    end
  end
end
