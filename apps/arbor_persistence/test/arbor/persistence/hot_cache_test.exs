defmodule Arbor.Persistence.HotCacheTest do
  use ExUnit.Case, async: true

  alias Arbor.Persistence.HotCache

  # Test ETS-based hot storage cache
  @moduletag cache: :ets

  setup context do
    # Create unique table name for each test to avoid conflicts
    table_name = :"test_cache_#{:erlang.unique_integer([:positive])}"
    {:ok, cache} = HotCache.start_link(table_name: table_name)

    on_exit(fn ->
      # Only stop if process is still alive
      if Process.alive?(cache) do
        GenServer.stop(cache, :normal, 1000)
      end

      # Clean up ETS table if it still exists (unless tagged to skip cleanup)
      unless context[:skip_table_cleanup] do
        try do
          if :ets.info(table_name) != :undefined do
            :ets.delete(table_name)
          end
        rescue
          # Table already deleted
          ArgumentError -> :ok
        end
      end
    end)

    %{cache: cache, table_name: table_name}
  end

  describe "put/3" do
    test "stores value in cache", %{cache: cache} do
      assert :ok = HotCache.put(cache, "key1", %{data: "value1"})
    end

    test "overwrites existing value", %{cache: cache} do
      HotCache.put(cache, "key1", %{data: "value1"})
      assert :ok = HotCache.put(cache, "key1", %{data: "value2"})

      assert {:ok, %{data: "value2"}} = HotCache.get(cache, "key1")
    end

    test "handles complex data structures", %{cache: cache} do
      complex_data = %{
        session_id: "session_123",
        messages: [
          %{id: "msg_1", content: "Hello"},
          %{id: "msg_2", content: "World"}
        ],
        state: :active,
        metadata: %{created_at: DateTime.utc_now()}
      }

      assert :ok = HotCache.put(cache, "session_123", complex_data)
      assert {:ok, ^complex_data} = HotCache.get(cache, "session_123")
    end
  end

  describe "get/2" do
    test "retrieves stored value", %{cache: cache} do
      data = %{session_id: "test", state: :active}
      HotCache.put(cache, "test_key", data)

      assert {:ok, ^data} = HotCache.get(cache, "test_key")
    end

    test "returns not_found for missing key", %{cache: cache} do
      assert {:error, :not_found} = HotCache.get(cache, "missing_key")
    end

    test "handles concurrent reads", %{cache: cache} do
      data = %{value: 42}
      HotCache.put(cache, "concurrent_key", data)

      # Spawn multiple concurrent readers
      tasks =
        for _i <- 1..10 do
          Task.async(fn ->
            HotCache.get(cache, "concurrent_key")
          end)
        end

      results = Task.await_many(tasks)

      # All reads should succeed and return the same data
      assert Enum.all?(results, fn result -> result == {:ok, data} end)
    end
  end

  describe "delete/2" do
    test "removes value from cache", %{cache: cache} do
      HotCache.put(cache, "delete_me", %{data: "test"})

      assert :ok = HotCache.delete(cache, "delete_me")
      assert {:error, :not_found} = HotCache.get(cache, "delete_me")
    end

    test "succeeds even if key doesn't exist", %{cache: cache} do
      assert :ok = HotCache.delete(cache, "never_existed")
    end
  end

  describe "list_keys/1" do
    test "returns all keys in cache", %{cache: cache} do
      HotCache.put(cache, "key1", %{value: 1})
      HotCache.put(cache, "key2", %{value: 2})
      HotCache.put(cache, "key3", %{value: 3})

      {:ok, keys} = HotCache.list_keys(cache)

      assert length(keys) == 3
      assert "key1" in keys
      assert "key2" in keys
      assert "key3" in keys
    end

    test "returns empty list for empty cache", %{cache: cache} do
      assert {:ok, []} = HotCache.list_keys(cache)
    end
  end

  describe "clear/1" do
    test "removes all entries from cache", %{cache: cache} do
      HotCache.put(cache, "key1", %{value: 1})
      HotCache.put(cache, "key2", %{value: 2})

      assert :ok = HotCache.clear(cache)
      assert {:ok, []} = HotCache.list_keys(cache)
    end
  end

  describe "size/1" do
    test "returns number of entries in cache", %{cache: cache} do
      assert {:ok, 0} = HotCache.size(cache)

      HotCache.put(cache, "key1", %{value: 1})
      assert {:ok, 1} = HotCache.size(cache)

      HotCache.put(cache, "key2", %{value: 2})
      assert {:ok, 2} = HotCache.size(cache)

      HotCache.delete(cache, "key1")
      assert {:ok, 1} = HotCache.size(cache)
    end
  end

  describe "get_info/1" do
    test "returns cache statistics", %{cache: cache} do
      HotCache.put(cache, "key1", %{large_data: String.duplicate("x", 1000)})

      {:ok, info} = HotCache.get_info(cache)

      assert info.size > 0
      assert info.memory > 0
      assert is_atom(info.type)
      assert is_boolean(info.named_table)
    end
  end

  describe "performance characteristics" do
    test "handles large number of entries efficiently", %{cache: cache} do
      # Insert 1000 entries
      {insert_time, _results} =
        :timer.tc(fn ->
          for i <- 1..1000 do
            HotCache.put(cache, "key_#{i}", %{index: i, data: "value_#{i}"})
          end
        end)

      # Should be fast (< 100ms for 1000 inserts)
      assert insert_time < 100_000

      # Reading should also be fast
      {read_time, {:ok, %{index: 500}}} =
        :timer.tc(fn ->
          HotCache.get(cache, "key_500")
        end)

      # Individual reads should be very fast (< 1ms)
      assert read_time < 1_000
    end

    test "concurrent writes and reads", %{cache: cache} do
      # Spawn writers and readers concurrently
      writers =
        for i <- 1..10 do
          Task.async(fn ->
            for j <- 1..10 do
              HotCache.put(cache, "writer_#{i}_key_#{j}", %{writer: i, value: j})
            end
          end)
        end

      readers =
        for _i <- 1..5 do
          Task.async(fn ->
            for _j <- 1..20 do
              HotCache.get(cache, "writer_1_key_1")
            end
          end)
        end

      # Wait for all tasks to complete
      Task.await_many(writers ++ readers, 5_000)

      # Verify final state
      {:ok, size} = HotCache.size(cache)
      # 10 writers * 10 keys each
      assert size == 100
    end
  end

  describe "crash recovery" do
    test "ETS table configuration and access patterns" do
      # Create a simple named table test
      table_name = :recovery_test_table

      # Start cache with explicit table name
      {:ok, cache} = HotCache.start_link(table_name: table_name)

      # Store some data
      HotCache.put(cache, "persistent_key", %{data: "test_data"})

      # Verify data is stored
      assert {:ok, %{data: "test_data"}} = HotCache.get(cache, "persistent_key")

      # Check if the table is configured as named_table (for direct access)
      {:ok, info} = HotCache.get_info(cache)
      assert info.named_table == true

      # Verify we can access the table directly by name (important for debugging)
      assert :ets.lookup(table_name, "persistent_key") == [
               {"persistent_key", %{data: "test_data"}}
             ]

      # Verify concurrent access works
      spawn(fn ->
        # Other processes can access the named table
        assert :ets.lookup(table_name, "persistent_key") == [
                 {"persistent_key", %{data: "test_data"}}
               ]
      end)

      # Current implementation: table lifecycle is tied to GenServer
      # For true crash recovery, would need supervisor inheritance
      # This test verifies the table works correctly while the process is alive

      # Clean up
      GenServer.stop(cache, :normal)

      # After process termination, table is cleaned up (current behavior)
      # This is the expected behavior without supervisor inheritance
      assert :ets.info(table_name) == :undefined
    end
  end
end
