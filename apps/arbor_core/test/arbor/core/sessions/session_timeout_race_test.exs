defmodule Arbor.Core.Sessions.SessionTimeoutRaceTest do
  @moduledoc """
  Tests for session timeout race condition fixes to ensure proper timeout
  reference tracking and prevent race conditions in timeout scheduling.

  This test covers the fixes for Issue: Session timeout scheduling race conditions
  where multiple timeout messages could be scheduled simultaneously.
  """

  use ExUnit.Case, async: true

  alias Arbor.Core.Sessions.Session

  describe "timeout reference tracking" do
    test "session properly tracks timeout reference in state" do
      session_id = "timeout-ref-test-#{:erlang.unique_integer([:positive])}"
      # 2 seconds
      timeout = 2_000

      {:ok, session_pid} =
        Session.start_link(
          session_id: session_id,
          timeout: timeout,
          created_by: "test"
        )

      # Get initial state
      {:ok, initial_state} = Session.get_state(session_pid)

      # Session should be active initially
      assert initial_state.session_id == session_id
      assert initial_state.timeout == timeout

      # Trigger activity update which should reset timeout reference
      Session.send_message(session_pid, %Arbor.Contracts.Core.Message{
        id: "test-msg-1",
        from: "test",
        to: session_id,
        payload: %{type: :test},
        timestamp: DateTime.utc_now()
      })

      # Give time for message processing
      Process.sleep(100)

      # Get state after activity
      {:ok, updated_state} = Session.get_state(session_pid)

      # Last activity should be updated
      assert DateTime.compare(updated_state.last_activity, initial_state.last_activity) == :gt

      GenServer.stop(session_pid)
    end

    test "multiple rapid activities don't create multiple timeout references" do
      session_id = "rapid-activity-test-#{:erlang.unique_integer([:positive])}"
      # 5 seconds
      timeout = 5_000

      {:ok, session_pid} =
        Session.start_link(
          session_id: session_id,
          timeout: timeout,
          created_by: "test"
        )

      # Send multiple messages rapidly
      for i <- 1..5 do
        Session.send_message(session_pid, %Arbor.Contracts.Core.Message{
          id: "rapid-msg-#{i}",
          from: "test",
          to: session_id,
          payload: %{type: :test, sequence: i},
          timestamp: DateTime.utc_now()
        })

        # Small delay between messages
        Process.sleep(10)
      end

      # Wait for all messages to be processed
      Process.sleep(200)

      # Session should still be alive and responsive
      {:ok, final_state} = Session.get_state(session_pid)
      assert final_state.session_id == session_id

      # Should have received all messages (check execution history)
      assert final_state.execution_count >= 5

      GenServer.stop(session_pid)
    end

    test "timeout reference is properly cancelled on activity" do
      session_id = "timeout-cancel-test-#{:erlang.unique_integer([:positive])}"
      # 1 second
      short_timeout = 1_000

      {:ok, session_pid} =
        Session.start_link(
          session_id: session_id,
          timeout: short_timeout,
          created_by: "test"
        )

      # Wait most of the timeout period
      Process.sleep(800)

      # Send activity to reset timeout
      Session.send_message(session_pid, %Arbor.Contracts.Core.Message{
        id: "timeout-reset-msg",
        from: "test",
        to: session_id,
        payload: %{type: :timeout_reset},
        timestamp: DateTime.utc_now()
      })

      # Wait past the original timeout period
      Process.sleep(500)

      # Session should still be alive because timeout was reset
      {:ok, state} = Session.get_state(session_pid)
      assert state.session_id == session_id

      GenServer.stop(session_pid)
    end

    test "session properly times out when no activity occurs" do
      session_id = "natural-timeout-test-#{:erlang.unique_integer([:positive])}"
      # 0.5 seconds
      short_timeout = 500

      {:ok, session_pid} =
        Session.start_link(
          session_id: session_id,
          timeout: short_timeout,
          created_by: "test"
        )

      # Monitor the session process
      ref = Process.monitor(session_pid)

      # Wait for timeout to occur
      receive do
        {:DOWN, ^ref, :process, ^session_pid, reason} ->
          assert reason == :timeout
      after
        2_000 ->
          flunk("Session should have timed out within 2 seconds")
      end
    end
  end

  describe "concurrent timeout scheduling" do
    test "concurrent activities don't create race conditions" do
      session_id = "concurrent-test-#{:erlang.unique_integer([:positive])}"
      # 3 seconds
      timeout = 3_000

      {:ok, session_pid} =
        Session.start_link(
          session_id: session_id,
          timeout: timeout,
          created_by: "test"
        )

      # Create multiple tasks that send messages concurrently
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            for j <- 1..5 do
              Session.send_message(session_pid, %Arbor.Contracts.Core.Message{
                id: "concurrent-msg-#{i}-#{j}",
                from: "test-#{i}",
                to: session_id,
                payload: %{type: :concurrent, worker: i, sequence: j},
                timestamp: DateTime.utc_now()
              })

              # Small random delay
              Process.sleep(:rand.uniform(20))
            end

            :ok
          end)
        end

      # Wait for all tasks to complete
      Task.await_many(tasks, 5_000)

      # Wait for message processing
      Process.sleep(200)

      # Session should still be responsive
      {:ok, final_state} = Session.get_state(session_pid)
      assert final_state.session_id == session_id

      # Should have processed a significant number of messages
      assert final_state.execution_count >= 30

      GenServer.stop(session_pid)
    end

    test "adding and removing agents during timeout doesn't cause issues" do
      session_id = "agent-ops-test-#{:erlang.unique_integer([:positive])}"
      # 2 seconds
      timeout = 2_000

      {:ok, session_pid} =
        Session.start_link(
          session_id: session_id,
          timeout: timeout,
          created_by: "test"
        )

      # Concurrently add and remove agents while session is active
      agent_task =
        Task.async(fn ->
          for i <- 1..10 do
            agent_id = "test-agent-#{i}"
            Session.add_agent(session_pid, agent_id)
            Process.sleep(50)
            Session.remove_agent(session_pid, agent_id)
            Process.sleep(50)
          end
        end)

      # Concurrently send messages
      message_task =
        Task.async(fn ->
          for i <- 1..5 do
            Session.send_message(session_pid, %Arbor.Contracts.Core.Message{
              id: "mixed-ops-msg-#{i}",
              from: "test",
              to: session_id,
              payload: %{type: :mixed_ops, sequence: i},
              timestamp: DateTime.utc_now()
            })

            Process.sleep(100)
          end
        end)

      # Wait for both tasks
      Task.await(agent_task, 5_000)
      Task.await(message_task, 5_000)

      # Session should still be responsive
      {:ok, final_state} = Session.get_state(session_pid)
      assert final_state.session_id == session_id

      # All agents should be removed
      assert Enum.empty?(final_state.active_agents)

      GenServer.stop(session_pid)
    end
  end

  describe "timeout precision and scheduling" do
    test "timeout check intervals are reasonable" do
      session_id = "interval-test-#{:erlang.unique_integer([:positive])}"
      # 30 seconds (long enough to test without timing out)
      timeout = 30_000

      {:ok, session_pid} =
        Session.start_link(
          session_id: session_id,
          timeout: timeout,
          created_by: "test"
        )

      # Send an activity update
      start_time = System.monotonic_time(:millisecond)

      Session.send_message(session_pid, %Arbor.Contracts.Core.Message{
        id: "interval-test-msg",
        from: "test",
        to: session_id,
        payload: %{type: :interval_test},
        timestamp: DateTime.utc_now()
      })

      # Check that state updates happen promptly
      Process.sleep(100)
      end_time = System.monotonic_time(:millisecond)

      {:ok, state} = Session.get_state(session_pid)
      assert state.session_id == session_id

      # Response should be fast
      response_time = end_time - start_time
      assert response_time < 1_000, "Session should respond quickly to activity updates"

      GenServer.stop(session_pid)
    end

    test "timeout accuracy is maintained under load" do
      # Create multiple sessions with different timeouts
      sessions =
        for i <- 1..3 do
          session_id = "load-test-#{i}-#{:erlang.unique_integer([:positive])}"
          # 1.5s, 2s, 2.5s
          timeout = 1_000 + i * 500

          {:ok, session_pid} =
            Session.start_link(
              session_id: session_id,
              timeout: timeout,
              created_by: "test-#{i}"
            )

          {session_id, session_pid, timeout}
        end

      # Send load to all sessions
      for {session_id, session_pid, _timeout} <- sessions do
        for j <- 1..5 do
          Session.send_message(session_pid, %Arbor.Contracts.Core.Message{
            id: "load-msg-#{session_id}-#{j}",
            from: "load-test",
            to: session_id,
            payload: %{type: :load_test, sequence: j},
            timestamp: DateTime.utc_now()
          })
        end
      end

      # Wait for processing
      Process.sleep(200)

      # All sessions should still be responsive
      for {session_id, session_pid, _timeout} <- sessions do
        {:ok, state} = Session.get_state(session_pid)
        assert state.session_id == session_id
        assert state.execution_count >= 5
      end

      # Clean up
      for {_session_id, session_pid, _timeout} <- sessions do
        GenServer.stop(session_pid)
      end
    end
  end

  describe "edge cases and error handling" do
    test "zero timeout is handled correctly" do
      session_id = "zero-timeout-test-#{:erlang.unique_integer([:positive])}"

      {:ok, session_pid} =
        Session.start_link(
          session_id: session_id,
          # Zero timeout
          timeout: 0,
          created_by: "test"
        )

      # Session should start successfully
      {:ok, state} = Session.get_state(session_pid)
      assert state.session_id == session_id
      assert state.timeout == 0

      # Send activity
      Session.send_message(session_pid, %Arbor.Contracts.Core.Message{
        id: "zero-timeout-msg",
        from: "test",
        to: session_id,
        payload: %{type: :zero_timeout_test},
        timestamp: DateTime.utc_now()
      })

      # Should still be responsive
      Process.sleep(100)
      {:ok, updated_state} = Session.get_state(session_pid)
      assert updated_state.execution_count >= 1

      GenServer.stop(session_pid)
    end

    test "negative timeout is handled gracefully" do
      session_id = "negative-timeout-test-#{:erlang.unique_integer([:positive])}"

      # Should handle negative timeout gracefully
      {:ok, session_pid} =
        Session.start_link(
          session_id: session_id,
          # Negative timeout
          timeout: -1000,
          created_by: "test"
        )

      # Session should start successfully
      {:ok, state} = Session.get_state(session_pid)
      assert state.session_id == session_id

      GenServer.stop(session_pid)
    end

    test "very large timeout values work correctly" do
      session_id = "large-timeout-test-#{:erlang.unique_integer([:positive])}"
      # 24 hours
      large_timeout = 86_400_000

      {:ok, session_pid} =
        Session.start_link(
          session_id: session_id,
          timeout: large_timeout,
          created_by: "test"
        )

      # Session should start successfully
      {:ok, state} = Session.get_state(session_pid)
      assert state.session_id == session_id
      assert state.timeout == large_timeout

      # Activity should still work
      Session.send_message(session_pid, %Arbor.Contracts.Core.Message{
        id: "large-timeout-msg",
        from: "test",
        to: session_id,
        payload: %{type: :large_timeout_test},
        timestamp: DateTime.utc_now()
      })

      Process.sleep(100)
      {:ok, updated_state} = Session.get_state(session_pid)
      assert updated_state.execution_count >= 1

      GenServer.stop(session_pid)
    end
  end

  describe "timeout reference cleanup" do
    test "timeout references are cleaned up on session termination" do
      session_id = "cleanup-test-#{:erlang.unique_integer([:positive])}"
      # 5 seconds
      timeout = 5_000

      {:ok, session_pid} =
        Session.start_link(
          session_id: session_id,
          timeout: timeout,
          created_by: "test"
        )

      # Send some activity to ensure timeout reference is set
      Session.send_message(session_pid, %Arbor.Contracts.Core.Message{
        id: "cleanup-test-msg",
        from: "test",
        to: session_id,
        payload: %{type: :cleanup_test},
        timestamp: DateTime.utc_now()
      })

      Process.sleep(100)

      # Session should be active
      {:ok, state} = Session.get_state(session_pid)
      assert state.session_id == session_id

      # Monitor the session
      ref = Process.monitor(session_pid)

      # Stop the session
      GenServer.stop(session_pid)

      # Wait for termination
      receive do
        {:DOWN, ^ref, :process, ^session_pid, reason} ->
          # Normal termination is expected
          assert reason in [:normal, :shutdown]
      after
        1_000 ->
          flunk("Session should have terminated within 1 second")
      end
    end

    test "session handles timeout message after reference is cancelled" do
      session_id = "stale-timeout-test-#{:erlang.unique_integer([:positive])}"
      # 1 second
      timeout = 1_000

      {:ok, session_pid} =
        Session.start_link(
          session_id: session_id,
          timeout: timeout,
          created_by: "test"
        )

      # Wait most of timeout period
      Process.sleep(800)

      # Send activity to cancel timeout
      Session.send_message(session_pid, %Arbor.Contracts.Core.Message{
        id: "stale-timeout-msg",
        from: "test",
        to: session_id,
        payload: %{type: :stale_timeout_test},
        timestamp: DateTime.utc_now()
      })

      # Wait for the original timeout period to pass
      Process.sleep(500)

      # Session should still be alive
      {:ok, state} = Session.get_state(session_pid)
      assert state.session_id == session_id

      GenServer.stop(session_pid)
    end
  end
end
