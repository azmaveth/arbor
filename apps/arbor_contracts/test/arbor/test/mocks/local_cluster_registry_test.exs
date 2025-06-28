defmodule Arbor.Test.Mocks.LocalClusterRegistryTest do
  @moduledoc """
  Tests for LocalClusterRegistry ETS table management and cleanup to ensure
  no table name conflicts occur between test runs.

  This test covers the fixes for Issue: ArgumentError: table name already exists
  when ETS tables weren't properly cleaned up between tests.
  """

  use ExUnit.Case, async: true

  alias Arbor.Test.Mocks.LocalClusterRegistry

  describe "ETS table name uniqueness" do
    test "multiple registry instances create unique table names" do
      # Start multiple registries with the same base name
      registries =
        for i <- 1..5 do
          {:ok, pid} = GenServer.start_link(LocalClusterRegistry, name: :test_registry)
          pid
        end

      # Get table names from each registry
      table_names =
        for pid <- registries do
          state = :sys.get_state(pid)
          [state.names_table, state.groups_table, state.monitors_table, state.ttl_table]
        end

      # All table names should be unique
      all_table_names = List.flatten(table_names)
      unique_table_names = Enum.uniq(all_table_names)

      assert length(all_table_names) == length(unique_table_names),
             "All ETS table names should be unique across registry instances"

      # Verify tables actually exist
      for table_name <- all_table_names do
        assert :ets.info(table_name) != :undefined, "Table #{table_name} should exist"
      end

      # Clean up
      for pid <- registries do
        GenServer.stop(pid)
      end

      # Verify tables are cleaned up after termination
      Process.sleep(100)

      for table_name <- all_table_names do
        assert :ets.info(table_name) == :undefined,
               "Table #{table_name} should be deleted after termination"
      end
    end

    test "table names include unique identifiers" do
      {:ok, pid} = GenServer.start_link(LocalClusterRegistry, name: :unique_test)
      state = :sys.get_state(pid)

      # Table names should contain the base name and a unique suffix
      assert String.contains?(Atom.to_string(state.names_table), "unique_test_names_")
      assert String.contains?(Atom.to_string(state.groups_table), "unique_test_groups_")
      assert String.contains?(Atom.to_string(state.monitors_table), "unique_test_monitors_")
      assert String.contains?(Atom.to_string(state.ttl_table), "unique_test_ttl_")

      # Each table name should be different
      table_names = [state.names_table, state.groups_table, state.monitors_table, state.ttl_table]

      assert length(table_names) == length(Enum.uniq(table_names)),
             "All table names should be unique"

      GenServer.stop(pid)
    end

    test "default name generates unique tables" do
      # Start registry with default name
      {:ok, pid1} = GenServer.start_link(LocalClusterRegistry, [])
      {:ok, pid2} = GenServer.start_link(LocalClusterRegistry, [])

      state1 = :sys.get_state(pid1)
      state2 = :sys.get_state(pid2)

      # Tables from different instances should have different names
      assert state1.names_table != state2.names_table
      assert state1.groups_table != state2.groups_table
      assert state1.monitors_table != state2.monitors_table
      assert state1.ttl_table != state2.ttl_table

      GenServer.stop(pid1)
      GenServer.stop(pid2)
    end
  end

  describe "ETS table cleanup" do
    test "terminate callback properly cleans up all tables" do
      {:ok, pid} = GenServer.start_link(LocalClusterRegistry, name: :cleanup_test)
      state = :sys.get_state(pid)

      table_names = [state.names_table, state.groups_table, state.monitors_table, state.ttl_table]

      # Verify tables exist
      for table_name <- table_names do
        assert :ets.info(table_name) != :undefined, "Table #{table_name} should exist"
      end

      # Stop the process
      GenServer.stop(pid)
      Process.sleep(50)

      # Verify tables are cleaned up
      for table_name <- table_names do
        assert :ets.info(table_name) == :undefined,
               "Table #{table_name} should be deleted after termination"
      end
    end

    test "clear operation preserves table structure but empties content" do
      {:ok, pid} = GenServer.start_link(LocalClusterRegistry, name: :clear_test)

      # Add some data
      :ok = GenServer.call(pid, {:register_name, :test_name, self(), %{test: true}})
      :ok = GenServer.call(pid, {:join, :test_group, self()})

      # Verify data exists
      {:ok, {found_pid, _}} = GenServer.call(pid, {:whereis_name, :test_name})
      assert found_pid == self()

      # Clear the registry
      :ok = GenServer.call(pid, :clear)

      # Verify data is cleared but tables still exist
      assert GenServer.call(pid, {:whereis_name, :test_name}) == :undefined

      # Tables should still exist and be functional
      state = :sys.get_state(pid)

      for table_name <- [
            state.names_table,
            state.groups_table,
            state.monitors_table,
            state.ttl_table
          ] do
        assert :ets.info(table_name) != :undefined,
               "Table #{table_name} should still exist after clear"
      end

      # Should be able to add new data
      :ok = GenServer.call(pid, {:register_name, :new_name, self(), %{test: true}})
      {:ok, {found_pid, _}} = GenServer.call(pid, {:whereis_name, :new_name})
      assert found_pid == self()

      GenServer.stop(pid)
    end

    test "handles errors gracefully during cleanup" do
      {:ok, pid} = GenServer.start_link(LocalClusterRegistry, name: :error_test)
      state = :sys.get_state(pid)

      # Manually delete one table to simulate error condition
      :ets.delete(state.names_table)

      # Termination should still succeed even with missing table
      assert GenServer.stop(pid) == :ok
    end

    test "handles errors gracefully during clear operation" do
      {:ok, pid} = GenServer.start_link(LocalClusterRegistry, name: :clear_error_test)
      state = :sys.get_state(pid)

      # Manually delete one table to simulate error condition
      :ets.delete(state.names_table)

      # Clear should still succeed even with missing table
      assert GenServer.call(pid, :clear) == :ok

      GenServer.stop(pid)
    end
  end

  describe "concurrent table operations" do
    test "multiple registries can operate independently" do
      # Start multiple registries
      registries =
        for i <- 1..3 do
          {:ok, pid} = GenServer.start_link(LocalClusterRegistry, name: :"concurrent_test_#{i}")
          pid
        end

      # Perform operations on each registry concurrently
      tasks =
        for {pid, i} <- Enum.with_index(registries) do
          Task.async(fn ->
            # Register unique names in each registry
            name = :"test_name_#{i}"
            :ok = GenServer.call(pid, {:register_name, name, self(), %{index: i}})

            # Verify registration
            {:ok, {found_pid, metadata}} = GenServer.call(pid, {:whereis_name, name})
            assert found_pid == self()
            assert metadata.index == i

            {pid, name}
          end)
        end

      # Wait for all operations to complete
      results = Task.await_many(tasks, 5000)

      # Verify all operations succeeded
      assert length(results) == 3

      # Verify registrations are isolated between registries
      for {{pid, name}, i} <- Enum.with_index(results) do
        {:ok, {found_pid, metadata}} = GenServer.call(pid, {:whereis_name, name})
        assert found_pid == self()
        assert metadata.index == i
      end

      # Clean up
      for pid <- registries do
        GenServer.stop(pid)
      end
    end

    test "rapid start/stop cycles don't cause table conflicts" do
      # Rapidly start and stop registries with the same name
      for _i <- 1..10 do
        {:ok, pid} = GenServer.start_link(LocalClusterRegistry, name: :rapid_test)

        # Perform a quick operation
        :ok = GenServer.call(pid, {:register_name, :test_name, self(), %{}})

        # Stop immediately
        GenServer.stop(pid)

        # Small delay to ensure cleanup
        Process.sleep(10)
      end

      # Final registry should start successfully
      {:ok, final_pid} = GenServer.start_link(LocalClusterRegistry, name: :rapid_test)
      :ok = GenServer.call(final_pid, {:register_name, :final_name, self(), %{}})

      GenServer.stop(final_pid)
    end
  end

  describe "table information and introspection" do
    test "can introspect table names and sizes" do
      {:ok, pid} = GenServer.start_link(LocalClusterRegistry, name: :introspect_test)
      state = :sys.get_state(pid)

      # Initially tables should be empty
      assert :ets.info(state.names_table, :size) == 0
      assert :ets.info(state.groups_table, :size) == 0
      assert :ets.info(state.monitors_table, :size) == 0
      assert :ets.info(state.ttl_table, :size) == 0

      # Add some data
      :ok = GenServer.call(pid, {:register_name, :test1, self(), %{}})
      :ok = GenServer.call(pid, {:register_name, :test2, self(), %{}})
      :ok = GenServer.call(pid, {:join, :group1, self()})

      # Check table sizes increased
      assert :ets.info(state.names_table, :size) == 2
      assert :ets.info(state.groups_table, :size) >= 1

      GenServer.stop(pid)
    end
  end
end
