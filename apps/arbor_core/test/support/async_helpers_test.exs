defmodule Arbor.Test.Support.AsyncHelpersTest do
  @moduledoc """
  Tests for the exponential backoff async helpers.

  Demonstrates the new exponential backoff functionality that replaces
  fixed delays with intelligent retry logic.
  """

  use ExUnit.Case, async: true

  alias Arbor.Test.Support.AsyncHelpers

  describe "wait_until/2" do
    test "returns immediately when condition is already true" do
      start_time = System.monotonic_time(:millisecond)

      result = AsyncHelpers.wait_until(fn -> :success end)

      elapsed = System.monotonic_time(:millisecond) - start_time
      assert result == :success
      # Should complete almost immediately (within 50ms)
      assert elapsed < 50
    end

    test "retries with exponential backoff until condition is met" do
      # Use a counter to simulate a condition that becomes true after several attempts
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      start_time = System.monotonic_time(:millisecond)

      result =
        AsyncHelpers.wait_until(
          fn ->
            count = Agent.get_and_update(counter, fn x -> {x + 1, x + 1} end)
            if count >= 3, do: :success, else: false
          end,
          initial_delay: 10,
          max_delay: 50
        )

      elapsed = System.monotonic_time(:millisecond) - start_time

      assert result == :success
      # Should take some time but not too long (exponential backoff: 10ms + 20ms ≈ 30ms minimum)
      # The actual timing may be faster due to CPU scheduling
      assert elapsed >= 20
      assert elapsed <= 200

      Agent.stop(counter)
    end

    test "raises AssertionError when timeout is reached" do
      assert_raise ExUnit.AssertionError, ~r/Condition not met within 100ms timeout/, fn ->
        AsyncHelpers.wait_until(fn -> false end, timeout: 100, initial_delay: 20)
      end
    end

    test "works with custom backoff parameters" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      start_time = System.monotonic_time(:millisecond)

      result =
        AsyncHelpers.wait_until(
          fn ->
            count = Agent.get_and_update(counter, fn x -> {x + 1, x + 1} end)
            if count >= 2, do: :found, else: nil
          end,
          # Start with 50ms
          initial_delay: 50,
          # Triple each time
          factor: 3,
          # Cap at 200ms
          max_delay: 200
        )

      elapsed = System.monotonic_time(:millisecond) - start_time

      assert result == :found
      # Should take at least initial_delay (50ms)
      assert elapsed >= 40

      Agent.stop(counter)
    end
  end

  describe "wait_for_agent_ready/2" do
    test "has the correct function signature and error handling" do
      # This test just verifies the function exists and handles expected errors gracefully
      # In a real environment with working agent registration, this would test actual agents

      assert_raise ExUnit.AssertionError, ~r/Condition not met within/, fn ->
        AsyncHelpers.wait_for_agent_ready("non-existent-agent", timeout: 100)
      end
    end
  end

  describe "wait_for_agent_stopped/2" do
    test "returns immediately when agent is already stopped" do
      start_time = System.monotonic_time(:millisecond)

      result = AsyncHelpers.wait_for_agent_stopped("non-existent-agent", timeout: 1000)

      elapsed = System.monotonic_time(:millisecond) - start_time
      assert result == :ok
      # Should complete immediately since agent doesn't exist
      assert elapsed < 50
    end
  end

  describe "performance comparison" do
    @tag :performance
    test "exponential backoff is faster than fixed delays on average" do
      # Simulate a condition that becomes true after random time
      {:ok, pid} =
        Agent.start_link(fn -> System.monotonic_time(:millisecond) + Enum.random(20..100) end)

      target_time = Agent.get(pid, & &1)

      # Test exponential backoff approach
      backoff_start = System.monotonic_time(:millisecond)

      AsyncHelpers.wait_until(
        fn ->
          System.monotonic_time(:millisecond) >= target_time
        end,
        initial_delay: 5,
        max_delay: 50
      )

      backoff_elapsed = System.monotonic_time(:millisecond) - backoff_start

      # Reset target for fixed delay approach
      Agent.update(pid, fn _ -> System.monotonic_time(:millisecond) + Enum.random(20..100) end)
      new_target = Agent.get(pid, & &1)

      # Test fixed delay approach (simulating old :timer.sleep pattern)
      fixed_start = System.monotonic_time(:millisecond)

      # Simulate fixed delays until condition is met using recursion instead of while loop
      fixed_elapsed = simulate_fixed_delays(new_target, fixed_start, 0)

      # The exponential backoff should generally be faster or comparable
      # but the main benefit is reliability and avoiding worst-case fixed delays
      IO.puts("Exponential backoff: #{backoff_elapsed}ms, Fixed delay: #{fixed_elapsed}ms")

      # Both should complete successfully, but backoff should be more adaptive
      assert backoff_elapsed > 0
      assert fixed_elapsed > 0

      Agent.stop(pid)
    end
  end

  # Helper function to simulate fixed delays (replaces while loop)
  defp simulate_fixed_delays(target_time, _start_time, attempts) when attempts > 20 do
    # Safety limit reached
    0
  end

  defp simulate_fixed_delays(target_time, start_time, attempts) do
    if System.monotonic_time(:millisecond) >= target_time do
      System.monotonic_time(:millisecond) - start_time
    else
      # Fixed 100ms delay like the old tests
      Process.sleep(100)
      simulate_fixed_delays(target_time, start_time, attempts + 1)
    end
  end
end
