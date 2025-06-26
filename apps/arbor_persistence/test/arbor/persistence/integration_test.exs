defmodule Arbor.Persistence.IntegrationTest do
  @moduledoc """
  Integration tests for the persistence layer.

  Tests the full persistence stack including database interaction,
  event sourcing, and snapshot management with a real PostgreSQL
  database.
  """

  use ExUnit.Case

  alias Arbor.Contracts.Events.Event, as: ContractEvent
  alias Arbor.Contracts.Persistence.Snapshot
  alias Arbor.Persistence.{Repo, Store}

  @moduletag :integration

  setup_all do
    # Start the Repo for integration tests
    {:ok, repo_pid} = Repo.start_link()

    # Run migrations if needed
    try do
      Ecto.Migrator.run(Repo, "apps/arbor_persistence/priv/repo/migrations", :up, all: true)
    rescue
      # Migrations may already be run
      _ -> :ok
    end

    # Clean up any existing test data before starting
    try do
      Repo.delete_all("events")
      Repo.delete_all("snapshots")
    rescue
      _ -> :ok
    end

    on_exit(fn ->
      # Clean up test data BEFORE stopping the Repo
      # Use a simpler approach - just attempt cleanup and ignore errors
      try do
        Repo.delete_all("events")
        Repo.delete_all("snapshots")
      rescue
        # Ignore all cleanup errors - database might already be shut down
        _ -> :ok
      catch
        # Ignore all cleanup errors - database might already be shut down
        _, _ -> :ok
      end
    end)

    %{repo_pid: repo_pid}
  end

  setup do
    # Clean up between individual tests
    try do
      Repo.delete_all("events")
      Repo.delete_all("snapshots")
    rescue
      _ -> :ok
    end

    :ok
  end

  describe "complete persistence workflow with database" do
    test "basic event sourcing workflow with PostgreSQL" do
      # This test will initially fail - testing complete workflow

      # Create test events
      event1 = %ContractEvent{
        id: Ecto.UUID.generate(),
        type: :agent_started,
        version: "1.0.0",
        aggregate_id: "agent_test_1",
        aggregate_type: :agent,
        data: %{agent_type: :llm, model: "claude-4"},
        timestamp: DateTime.utc_now(),
        causation_id: nil,
        correlation_id: "corr_123",
        trace_id: "trace_123",
        stream_id: "stream-1",
        stream_version: 0,
        global_position: nil,
        metadata: %{test: true}
      }

      event2 = %ContractEvent{
        id: Ecto.UUID.generate(),
        type: :agent_message_sent,
        version: "1.0.0",
        aggregate_id: "agent_test_1",
        aggregate_type: :agent,
        data: %{message: "Hello from integration test", recipient: "user"},
        timestamp: DateTime.utc_now(),
        causation_id: event1.id,
        correlation_id: "corr_123",
        trace_id: "trace_123",
        stream_id: "stream-1",
        stream_version: 1,
        global_position: nil,
        metadata: %{test: true}
      }

      # Initialize store with PostgreSQL backend
      # Initialize Store with PostgreSQL backend and unique cache table
      cache_table = :"cache_#{:erlang.unique_integer([:positive])}"
      {:ok, store} = Store.init(backend: :postgresql, cache_table: cache_table)

      # Test event append and read
      {:ok, final_version} = Store.append_events("stream-1", [event1, event2], -1, store)
      assert final_version == 1

      {:ok, events} = Store.read_events("stream-1", 0, :latest, store)
      assert length(events) == 2
      assert hd(events).id == event1.id
      assert List.last(events).id == event2.id

      # Verify event data integrity
      first_event = hd(events)
      assert first_event.type == :agent_started
      assert first_event.aggregate_id == "agent_test_1"
      # JSON stores keys as strings, not atoms
      assert first_event.data == %{"agent_type" => "llm", "model" => "claude-4"}

      # Test snapshot save and load
      snapshot = %Snapshot{
        id: Ecto.UUID.generate(),
        aggregate_id: "agent_test_1",
        aggregate_type: :agent,
        aggregate_version: 1,
        state: %{status: :active, message_count: 1},
        state_hash: "hash_integration_test",
        snapshot_version: "1.0.0",
        metadata: %{test: true},
        created_at: DateTime.utc_now()
      }

      {:ok, snapshot_id} = Store.save_snapshot("stream-1", snapshot, store)
      assert is_binary(snapshot_id)

      {:ok, loaded_snapshot} = Store.load_snapshot("stream-1", store)
      assert loaded_snapshot.aggregate_id == "agent_test_1"
      # JSON keys
      assert loaded_snapshot.state == %{"status" => "active", "message_count" => 1}

      # Test transaction support
      {:ok, result} =
        Store.transaction(
          fn store_state ->
            event3 = %ContractEvent{
              id: Ecto.UUID.generate(),
              type: :agent_stopped,
              version: "1.0.0",
              aggregate_id: "agent_test_1",
              aggregate_type: :agent,
              data: %{reason: "test_complete"},
              timestamp: DateTime.utc_now(),
              causation_id: event2.id,
              correlation_id: "corr_123",
              trace_id: "trace_123",
              stream_id: "stream-1",
              stream_version: 2,
              global_position: nil,
              metadata: %{test: true}
            }

            Store.append_events("stream-1", [event3], 1, store_state)
          end,
          [],
          store
        )

      assert result == 2

      # Verify transaction worked
      {:ok, all_events} = Store.read_events("stream-1", 0, :latest, store)
      assert length(all_events) == 3

      # Test stream metadata (PostgreSQL only feature)
      {:ok, metadata} = Store.get_stream_metadata("stream-1", store)
      # Final version after transaction
      assert metadata.version == 2
      assert metadata.event_count == 3
      assert metadata.has_snapshot == true
    end

    test "ETS cache improves read performance" do
      # Test that hot cache provides performance benefits
      # Initialize Store with PostgreSQL backend and unique cache table
      cache_table = :"cache_#{:erlang.unique_integer([:positive])}"
      {:ok, store} = Store.init(backend: :postgresql, cache_table: cache_table)

      # Create test data
      events =
        for i <- 1..10 do
          %ContractEvent{
            id: Ecto.UUID.generate(),
            type: :agent_message_sent,
            version: "1.0.0",
            aggregate_id: "perf_agent",
            aggregate_type: :agent,
            data: %{message: "Performance test #{i}"},
            timestamp: DateTime.utc_now(),
            causation_id: nil,
            correlation_id: "perf_test",
            trace_id: "perf_trace",
            stream_id: "perf-stream",
            stream_version: i - 1,
            global_position: nil,
            metadata: %{}
          }
        end

      # Append events
      {:ok, _} = Store.append_events("perf-stream", events, -1, store)

      # First read (cold - from database)
      {cold_time, {:ok, cold_events}} =
        :timer.tc(fn ->
          Store.read_events("perf-stream", 0, :latest, store)
        end)

      # Second read (should be faster with ETS cache)
      {hot_time, {:ok, hot_events}} =
        :timer.tc(fn ->
          Store.read_events("perf-stream", 0, :latest, store)
        end)

      # Verify same data
      assert length(cold_events) == length(hot_events)
      assert length(cold_events) == 10

      # ETS cache should provide significant speedup
      # (This assertion may need adjustment based on actual performance)
      # At least 20% faster
      assert hot_time < cold_time * 0.8
    end

    test "state recovery after restart simulation" do
      # Test that state can be recovered from persistence
      # Initialize Store with PostgreSQL backend and unique cache table
      cache_table = :"cache_#{:erlang.unique_integer([:positive])}"
      {:ok, store} = Store.init(backend: :postgresql, cache_table: cache_table)

      # Create initial state
      recovery_event = %ContractEvent{
        id: Ecto.UUID.generate(),
        type: :agent_started,
        version: "1.0.0",
        aggregate_id: "recovery_agent",
        aggregate_type: :agent,
        data: %{initial_state: %{count: 42, status: :running}},
        timestamp: DateTime.utc_now(),
        causation_id: nil,
        correlation_id: "recovery_test",
        trace_id: "recovery_trace",
        stream_id: "recovery-stream",
        stream_version: 0,
        global_position: nil,
        metadata: %{recovery_test: true}
      }

      {:ok, _} = Store.append_events("recovery-stream", [recovery_event], -1, store)

      # Save snapshot
      recovery_snapshot = %Snapshot{
        id: Ecto.UUID.generate(),
        aggregate_id: "recovery_agent",
        aggregate_type: :agent,
        aggregate_version: 0,
        state: %{count: 42, status: :running},
        state_hash: "recovery_hash",
        created_at: DateTime.utc_now(),
        snapshot_version: "1.0.0",
        metadata: %{recovery_test: true}
      }

      {:ok, _} = Store.save_snapshot("recovery-stream", recovery_snapshot, store)

      # Simulate restart by creating new store instance
      # Initialize new Store with PostgreSQL backend and unique cache table
      new_cache_table = :"cache_#{:erlang.unique_integer([:positive])}"
      {:ok, new_store} = Store.init(backend: :postgresql, cache_table: new_cache_table)

      # Verify state can be recovered
      {:ok, recovered_snapshot} = Store.load_snapshot("recovery-stream", new_store)
      # JSON keys/values
      assert recovered_snapshot.state == %{"count" => 42, "status" => "running"}

      {:ok, recovered_events} = Store.read_events("recovery-stream", 0, :latest, new_store)
      assert length(recovered_events) == 1
      # JSON converts nested data too
      assert hd(recovered_events).data == %{
               "initial_state" => %{"count" => 42, "status" => "running"}
             }
    end
  end
end
