defmodule Arbor.Persistence.StoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Events.Event, as: ContractEvent
  alias Arbor.Contracts.Persistence.Snapshot
  alias Arbor.Persistence.Store

  # Use in-memory mock for unit testing
  @moduletag persistence: :mock
  @moduletag :fast

  setup do
    # MOCK: Use in-memory implementation for unit tests
    {:ok, store_state} = Store.init(backend: :in_memory, table_name: :test_store)
    %{store: store_state}
  end

  describe "append_events/4" do
    test "appends single event to new stream", %{store: store} do
      event = create_test_event("event_1", :agent_started)

      assert {:ok, 0} = Store.append_events("stream_1", [event], -1, store)
    end

    test "appends multiple events to stream", %{store: store} do
      events = [
        create_test_event("event_1", :agent_started),
        create_test_event("event_2", :agent_message_sent)
      ]

      assert {:ok, 1} = Store.append_events("stream_1", events, -1, store)
    end

    test "enforces optimistic concurrency control", %{store: store} do
      event1 = create_test_event("event_1", :agent_started)
      event2 = create_test_event("event_2", :agent_stopped)

      # First append should succeed
      {:ok, 0} = Store.append_events("stream_1", [event1], -1, store)

      # Second append with wrong expected version should fail
      assert {:error, :version_conflict} =
               Store.append_events("stream_1", [event2], -1, store)

      # Correct expected version should succeed
      assert {:ok, 1} = Store.append_events("stream_1", [event2], 0, store)
    end

    test "rejects empty events list", %{store: store} do
      assert {:error, {:invalid_params, :empty_events}} =
               Store.append_events("stream_1", [], -1, store)
    end

    test "validates event data before append", %{store: store} do
      # Invalid event
      invalid_event = %{id: nil, data: %{}}

      assert {:error, {:validation_error, _reason}} =
               Store.append_events("stream_1", [invalid_event], -1, store)
    end
  end

  describe "read_events/4" do
    setup %{store: store} do
      # Setup test data
      events = [
        create_test_event("event_1", :agent_started),
        create_test_event("event_2", :agent_message_sent),
        create_test_event("event_3", :agent_stopped)
      ]

      {:ok, _version} = Store.append_events("test_stream", events, -1, store)
      %{store: store, events: events}
    end

    test "reads all events from stream", %{store: store} do
      assert {:ok, events} = Store.read_events("test_stream", 0, :latest, store)
      assert length(events) == 3
    end

    test "reads events from specific version", %{store: store} do
      assert {:ok, events} = Store.read_events("test_stream", 1, :latest, store)
      assert length(events) == 2
      assert hd(events).stream_version == 1
    end

    test "reads events within version range", %{store: store} do
      assert {:ok, events} = Store.read_events("test_stream", 0, 1, store)
      assert length(events) == 2
      assert List.first(events).stream_version == 0
      assert List.last(events).stream_version == 1
    end

    test "returns empty list for non-existent stream", %{store: store} do
      assert {:ok, []} = Store.read_events("non_existent", 0, :latest, store)
    end

    test "handles invalid version ranges", %{store: store} do
      # from_version > to_version should return error
      assert {:error, {:invalid_params, :invalid_version_range}} =
               Store.read_events("test_stream", 5, 2, store)
    end
  end

  describe "save_snapshot/3" do
    test "saves state snapshot for stream", %{store: store} do
      snapshot = %Snapshot{
        id: "snap_1",
        aggregate_id: "agent_123",
        aggregate_type: :agent,
        aggregate_version: 5,
        state: %{status: :active, messages: []},
        state_hash: "hash123",
        created_at: DateTime.utc_now(),
        snapshot_version: "1.0.0",
        metadata: %{}
      }

      assert {:ok, snapshot_id} = Store.save_snapshot("stream_1", snapshot, store)
      assert is_binary(snapshot_id)
    end

    test "validates snapshot data", %{store: store} do
      # Invalid
      invalid_snapshot = %{aggregate_id: nil}

      assert {:error, {:validation_error, _reason}} =
               Store.save_snapshot("stream_1", invalid_snapshot, store)
    end
  end

  describe "load_snapshot/2" do
    setup %{store: store} do
      snapshot = %Snapshot{
        id: "snap_test",
        aggregate_id: "agent_123",
        aggregate_type: :agent,
        aggregate_version: 5,
        state: %{status: :active, messages: []},
        state_hash: "hash123",
        created_at: DateTime.utc_now(),
        snapshot_version: "1.0.0",
        metadata: %{}
      }

      {:ok, _id} = Store.save_snapshot("test_stream", snapshot, store)
      %{store: store, snapshot: snapshot}
    end

    test "loads existing snapshot", %{store: store, snapshot: snapshot} do
      assert {:ok, loaded} = Store.load_snapshot("test_stream", store)
      assert loaded.aggregate_id == snapshot.aggregate_id
      assert loaded.state == snapshot.state
    end

    test "returns error for non-existent snapshot", %{store: store} do
      assert {:error, :snapshot_not_found} =
               Store.load_snapshot("non_existent", store)
    end
  end

  describe "get_stream_metadata/2" do
    setup %{store: store} do
      events = [
        create_test_event("event_1", :agent_started),
        create_test_event("event_2", :agent_stopped)
      ]

      {:ok, _version} = Store.append_events("meta_stream", events, -1, store)
      %{store: store}
    end

    test "returns stream metadata", %{store: store} do
      assert {:ok, metadata} = Store.get_stream_metadata("meta_stream", store)

      assert metadata.version == 1
      assert metadata.event_count == 2
      assert %DateTime{} = metadata.created_at
      assert %DateTime{} = metadata.updated_at
      assert metadata.has_snapshot == false
    end

    test "returns not_found for non-existent stream", %{store: store} do
      assert {:error, :not_found} =
               Store.get_stream_metadata("non_existent", store)
    end
  end

  describe "transaction/3" do
    test "executes function in transaction context", %{store: store} do
      result =
        Store.transaction(
          fn store_state ->
            event = create_test_event("event_1", :agent_started)
            Store.append_events("txn_stream", [event], -1, store_state)
          end,
          [],
          store
        )

      assert {:ok, 0} = result
    end

    test "rolls back on function error", %{store: store} do
      result =
        Store.transaction(
          fn _store_state ->
            raise "Transaction error"
          end,
          [],
          store
        )

      assert {:error, :transaction_failed} = result
    end
  end

  # Helper functions
  defp create_test_event(id, type) do
    %ContractEvent{
      id: id,
      type: type,
      version: "1.0.0",
      aggregate_id: "test_aggregate",
      aggregate_type: :agent,
      data: %{test: "data"},
      timestamp: DateTime.utc_now(),
      causation_id: nil,
      correlation_id: nil,
      trace_id: nil,
      stream_id: nil,
      stream_version: nil,
      global_position: nil,
      metadata: %{}
    }
  end
end
