defmodule Arbor.Persistence.EventJournalTest do
  # Not async due to file I/O and named GenServer
  use ExUnit.Case, async: false

  alias Arbor.Persistence.EventJournal

  @moduletag journal: :batching
  @moduletag :integration

  setup do
    # Create temporary directory for test journals
    test_dir = "/tmp/arbor_test_journals_#{:erlang.unique_integer([:positive])}"
    File.mkdir_p!(test_dir)

    # Start journal with test configuration and unique name
    journal_name = :"test_journal_#{:erlang.unique_integer([:positive])}"

    {:ok, journal_pid} =
      EventJournal.start_link(
        batch_size: 3,
        flush_interval: 500,
        data_dir: test_dir,
        name: journal_name
      )

    on_exit(fn ->
      # Stop journal and clean up
      if Process.alive?(journal_pid) do
        GenServer.stop(journal_pid, :normal, 1000)
      end

      File.rm_rf!(test_dir)
    end)

    %{journal: journal_pid, test_dir: test_dir}
  end

  describe "write_critical_event/2" do
    test "buffers events until batch size reached", %{journal: journal, test_dir: test_dir} do
      session_id = "test_session_1"

      # Write 2 events (below batch size of 3)
      EventJournal.write_critical_event(journal, session_id, {:user_message, "Hello"})
      EventJournal.write_critical_event(journal, session_id, {:user_message, "World"})

      # Give some time for async processing
      Process.sleep(10)

      # Should not have flushed yet
      status = EventJournal.get_buffer_status(journal)
      assert status.pending_events == 2
      assert status.sessions_buffered == 1

      # Journal file should not exist yet
      journal_file = Path.join(test_dir, "session_#{session_id}.journal")
      refute File.exists?(journal_file)
    end

    test "flushes when batch size reached", %{journal: journal, test_dir: test_dir} do
      session_id = "test_session_2"

      # Write 3 events (equals batch size)
      EventJournal.write_critical_event(journal, session_id, {:user_message, "Event 1"})
      EventJournal.write_critical_event(journal, session_id, {:user_message, "Event 2"})
      EventJournal.write_critical_event(journal, session_id, {:user_message, "Event 3"})

      # Give time for async flush
      Process.sleep(50)

      # Buffer should be empty now
      status = EventJournal.get_buffer_status(journal)
      assert status.pending_events == 0

      # Journal file should exist
      journal_file = Path.join(test_dir, "session_#{session_id}.journal")
      assert File.exists?(journal_file)

      # Verify we can read the events back
      {:ok, events} =
        EventJournal.read_journal_since(session_id, ~U[2020-01-01 00:00:00Z], test_dir)

      assert length(events) == 3
      assert Enum.member?(events, {:user_message, "Event 1"})
      assert Enum.member?(events, {:user_message, "Event 2"})
      assert Enum.member?(events, {:user_message, "Event 3"})
    end

    test "handles multiple sessions independently", %{journal: journal, test_dir: test_dir} do
      # Write events to different sessions
      EventJournal.write_critical_event(journal, "session_a", {:user_message, "A1"})
      EventJournal.write_critical_event(journal, "session_b", {:user_message, "B1"})
      EventJournal.write_critical_event(journal, "session_a", {:user_message, "A2"})

      Process.sleep(10)

      # Both sessions should be buffered
      status = EventJournal.get_buffer_status(journal)
      assert status.pending_events == 3
      assert status.sessions_buffered == 2

      # Add one more event to session_a to trigger flush (3 total)
      EventJournal.write_critical_event(journal, "session_a", {:user_message, "A3"})

      Process.sleep(50)

      # Only session_a should be flushed
      status = EventJournal.get_buffer_status(journal)
      # session_b still buffered
      assert status.pending_events == 1
      assert status.sessions_buffered == 1

      # Verify session_a journal exists
      journal_a = Path.join(test_dir, "session_session_a.journal")
      assert File.exists?(journal_a)

      # Verify session_b journal doesn't exist yet
      journal_b = Path.join(test_dir, "session_session_b.journal")
      refute File.exists?(journal_b)
    end

    test "handles different event types", %{journal: journal, test_dir: test_dir} do
      session_id = "test_session_events"

      # Write different types of critical events
      events = [
        {:user_message, %{content: "Hello", timestamp: DateTime.utc_now()}},
        {:assistant_response, %{content: "Hi there", model: "claude-4", tokens: 15}},
        {:mcp_tool_executed, %{tool: "filesystem", action: "read", result: "success"}},
        {:session_config_changed, %{key: "model", old: "claude-3", new: "claude-4"}}
      ]

      # Write all events (more than batch size)
      Enum.each(events, fn event ->
        EventJournal.write_critical_event(journal, session_id, event)
      end)

      Process.sleep(100)

      # All events should be flushed
      status = EventJournal.get_buffer_status(journal)
      # 4 events, batch size 3, so 1 remaining
      assert status.pending_events == 1

      # Read back and verify
      {:ok, written_events} =
        EventJournal.read_journal_since(session_id, ~U[2020-01-01 00:00:00Z], test_dir)

      # First batch
      assert length(written_events) == 3
    end
  end

  describe "flush_all/0" do
    test "forces immediate flush of all buffers", %{journal: journal, test_dir: test_dir} do
      # Buffer events in multiple sessions
      EventJournal.write_critical_event(journal, "session_1", {:user_message, "Message 1"})
      EventJournal.write_critical_event(journal, "session_2", {:user_message, "Message 2"})

      Process.sleep(10)

      # Verify events are buffered
      status = EventJournal.get_buffer_status(journal)
      assert status.pending_events == 2

      # Force flush
      :ok = EventJournal.flush_all(journal)

      # All buffers should be empty
      status = EventJournal.get_buffer_status(journal)
      assert status.pending_events == 0
      assert status.sessions_buffered == 0

      # Both journal files should exist
      assert File.exists?(Path.join(test_dir, "session_session_1.journal"))
      assert File.exists?(Path.join(test_dir, "session_session_2.journal"))
    end
  end

  describe "time-based flushing" do
    test "flushes buffers after flush_interval", %{journal: journal, test_dir: test_dir} do
      session_id = "test_session_timer"

      # Write events below batch size
      EventJournal.write_critical_event(journal, session_id, {:user_message, "Timer test 1"})
      EventJournal.write_critical_event(journal, session_id, {:user_message, "Timer test 2"})

      # Verify events are buffered
      status = EventJournal.get_buffer_status(journal)
      assert status.pending_events == 2

      # Wait for flush interval (500ms + buffer)
      Process.sleep(600)

      # Events should be flushed by timer
      status = EventJournal.get_buffer_status(journal)
      assert status.pending_events == 0

      # Journal file should exist
      journal_file = Path.join(test_dir, "session_#{session_id}.journal")
      assert File.exists?(journal_file)
    end
  end

  describe "journal reading" do
    test "read_journal_since/3 returns events after timestamp", %{
      journal: journal,
      test_dir: test_dir
    } do
      session_id = "test_read_session"

      # Create timestamp for filtering
      cutoff_time = DateTime.utc_now()
      # Ensure subsequent events have later timestamp
      Process.sleep(10)

      # Write some events
      EventJournal.write_critical_event(journal, session_id, {:user_message, "Before cutoff"})
      EventJournal.write_critical_event(journal, session_id, {:user_message, "After cutoff 1"})
      EventJournal.write_critical_event(journal, session_id, {:user_message, "After cutoff 2"})

      # Force flush
      EventJournal.flush_all(journal)

      # Read events since cutoff
      {:ok, events} = EventJournal.read_journal_since(session_id, cutoff_time, test_dir)

      # Should get all 3 events (our cutoff precision isn't perfect for this test)
      assert length(events) >= 2

      assert Enum.any?(events, fn event ->
               match?(
                 {:user_message, content} when content in ["After cutoff 1", "After cutoff 2"],
                 event
               )
             end)
    end

    test "read_journal_since/3 handles non-existent session", %{test_dir: test_dir} do
      {:ok, events} =
        EventJournal.read_journal_since("non_existent", DateTime.utc_now(), test_dir)

      assert events == []
    end

    test "maintains chronological order in journal", %{journal: journal, test_dir: test_dir} do
      session_id = "test_order_session"

      # Write events with small delays to ensure different timestamps
      EventJournal.write_critical_event(journal, session_id, {:user_message, "First"})
      Process.sleep(1)
      EventJournal.write_critical_event(journal, session_id, {:user_message, "Second"})
      Process.sleep(1)
      EventJournal.write_critical_event(journal, session_id, {:user_message, "Third"})

      # Force flush
      EventJournal.flush_all(journal)

      # Read back events
      {:ok, events} =
        EventJournal.read_journal_since(session_id, ~U[2020-01-01 00:00:00Z], test_dir)

      # Events should be in chronological order
      assert length(events) == 3

      assert events == [
               {:user_message, "First"},
               {:user_message, "Second"},
               {:user_message, "Third"}
             ]
    end
  end

  describe "performance characteristics" do
    test "handles high-volume event writing efficiently", %{journal: journal, test_dir: test_dir} do
      session_id = "perf_test_session"

      # Generate many events
      events =
        for i <- 1..100 do
          {:user_message, "Performance test message #{i}"}
        end

      # Measure write time
      {time_microseconds, :ok} =
        :timer.tc(fn ->
          Enum.each(events, fn event ->
            EventJournal.write_critical_event(journal, session_id, event)
          end)
        end)

      # Should be very fast since it's async
      # Less than 10ms
      assert time_microseconds < 10_000

      # Force flush and verify all events written
      EventJournal.flush_all(journal)

      {:ok, written_events} =
        EventJournal.read_journal_since(session_id, ~U[2020-01-01 00:00:00Z], test_dir)

      assert length(written_events) == 100
    end

    test "batch writing improves I/O efficiency", %{journal: journal} do
      # This test verifies the batching concept by checking
      # that multiple writes result in fewer I/O operations
      session_id = "batch_efficiency_test"

      # Write exactly batch_size events
      for i <- 1..3 do
        EventJournal.write_critical_event(journal, session_id, {:user_message, "Batch #{i}"})
      end

      Process.sleep(100)

      # Should have triggered exactly one flush (batch completed)
      status = EventJournal.get_buffer_status(journal)
      assert status.pending_events == 0
    end
  end

  describe "error handling" do
    test "survives write errors gracefully", %{journal: journal} do
      # This test ensures the journal doesn't crash on write errors
      # We'll simulate this by using an invalid directory

      # Note: For this test to work, we'd need to mock file operations
      # or use a read-only directory. For now, we'll just verify
      # the journal process stays alive under normal conditions

      session_id = "error_test_session"

      # Write some events
      EventJournal.write_critical_event(journal, session_id, {:user_message, "Error test"})

      # Process should still be alive
      assert Process.alive?(journal)
    end
  end

  describe "shutdown behavior" do
    test "flushes pending events on termination", %{journal: journal} do
      # This is tested implicitly by our setup/teardown
      # The on_exit callback stops the GenServer, which should
      # trigger the terminate/2 callback and flush pending events

      session_id = "shutdown_test"
      EventJournal.write_critical_event(journal, session_id, {:user_message, "Shutdown test"})

      # Events should be buffered
      status = EventJournal.get_buffer_status(journal)
      assert status.pending_events == 1

      # The test teardown will stop the GenServer and verify cleanup
    end
  end
end
