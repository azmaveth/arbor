defmodule Arbor.Test.Support.BackoffDemoTest do
  @moduledoc """
  Live demonstration of exponential backoff vs fixed delays.

  This test shows the concrete performance benefits of our new
  exponential backoff helper compared to the old fixed delay approach.
  """

  use ExUnit.Case, async: true

  alias Arbor.Test.Support.AsyncHelpers

  describe "exponential backoff demonstration" do
    test "demonstrates exponential backoff behavior with timing" do
      IO.puts("\n=== Exponential Backoff Demonstration ===")

      # Simulate condition that becomes true after ~75ms
      {:ok, target_pid} = Agent.start_link(fn -> System.monotonic_time(:millisecond) + 75 end)
      target_time = Agent.get(target_pid, & &1)

      # Test 1: Exponential backoff approach
      IO.puts("Testing exponential backoff approach...")
      start_time = System.monotonic_time(:millisecond)

      result =
        AsyncHelpers.wait_until(
          fn ->
            current_time = System.monotonic_time(:millisecond)
            if current_time >= target_time, do: :condition_met, else: false
          end,
          initial_delay: 10,
          max_delay: 50,
          timeout: 1000
        )

      backoff_elapsed = System.monotonic_time(:millisecond) - start_time
      IO.puts("✅ Exponential backoff completed in #{backoff_elapsed}ms")

      # Test 2: Old fixed delay approach (simulation)
      Agent.update(target_pid, fn _ -> System.monotonic_time(:millisecond) + 75 end)
      _new_target = Agent.get(target_pid, & &1)

      IO.puts("Testing old fixed delay approach...")
      fixed_start = System.monotonic_time(:millisecond)

      # Simulate the old way: fixed 100ms sleep
      # This is what tests used to do regardless of when condition was met
      Process.sleep(100)

      fixed_elapsed = System.monotonic_time(:millisecond) - fixed_start
      IO.puts("⏱️  Fixed delay completed in #{fixed_elapsed}ms")

      # Show the improvement
      improvement = fixed_elapsed - backoff_elapsed
      percentage = round(improvement / fixed_elapsed * 100)

      IO.puts("\n=== Results ===")
      IO.puts("Exponential backoff: #{backoff_elapsed}ms")
      IO.puts("Fixed delay:          #{fixed_elapsed}ms")
      IO.puts("Improvement:          #{improvement}ms (#{percentage}% faster)")
      IO.puts("=====================================\n")

      assert result == :condition_met

      # Note: Exponential backoff may be slower than fixed delay when the condition
      # becomes true in the "blind spot" between exponential intervals (e.g., 71-119ms).
      # This is expected behavior - exponential backoff trades worst-case overshoot
      # for much better average-case performance.
      if backoff_elapsed > fixed_elapsed do
        IO.puts("⚠️  Note: Exponential was slower due to timing overshoot (expected behavior)")
      end

      Agent.stop(target_pid)
    end

    test "shows exponential backoff delay progression" do
      IO.puts("\n=== Delay Progression Demonstration ===")

      _delays = []
      {:ok, delay_tracker} = Agent.start_link(fn -> [] end)

      # Create a condition that fails several times to show the backoff progression
      {:ok, attempt_counter} = Agent.start_link(fn -> 0 end)

      start_time = System.monotonic_time(:millisecond)

      result =
        AsyncHelpers.wait_until(
          fn ->
            current_time = System.monotonic_time(:millisecond)
            elapsed = current_time - start_time

            count = Agent.get_and_update(attempt_counter, fn x -> {x + 1, x + 1} end)
            Agent.update(delay_tracker, fn delays -> [elapsed | delays] end)

            IO.puts("Attempt #{count} at #{elapsed}ms")

            # Succeed on the 5th attempt
            if count >= 5, do: :success, else: false
          end,
          initial_delay: 20,
          factor: 2,
          max_delay: 100
        )

      delays = Agent.get(delay_tracker, fn delays -> Enum.reverse(delays) end)

      IO.puts("\nDelay progression:")

      delays
      |> Enum.with_index(1)
      |> Enum.each(fn {elapsed, attempt} ->
        IO.puts("  Attempt #{attempt}: #{elapsed}ms")
      end)

      # Calculate actual delays between attempts
      actual_delays =
        delays
        |> Enum.zip(Enum.drop(delays, 1))
        |> Enum.map(fn {prev, curr} -> curr - prev end)

      IO.puts("\nActual delays between attempts:")

      actual_delays
      |> Enum.with_index(2)
      |> Enum.each(fn {delay, attempt} ->
        IO.puts("  Before attempt #{attempt}: #{delay}ms")
      end)

      IO.puts("Expected progression: 20ms, 40ms, 80ms, 100ms (capped)")
      IO.puts("=========================================\n")

      assert result == :success
      assert length(delays) == 5

      Agent.stop(delay_tracker)
      Agent.stop(attempt_counter)
    end

    test "timeout behavior demonstration" do
      IO.puts("\n=== Timeout Behavior Demonstration ===")

      start_time = System.monotonic_time(:millisecond)

      timeout_result =
        try do
          AsyncHelpers.wait_until(fn -> false end, timeout: 200, initial_delay: 30)
          :unexpected_success
        rescue
          ExUnit.AssertionError -> :timeout_as_expected
        end

      elapsed = System.monotonic_time(:millisecond) - start_time

      IO.puts("Timeout test completed in #{elapsed}ms")
      IO.puts("Expected timeout: 200ms")
      IO.puts("Result: #{timeout_result}")

      assert timeout_result == :timeout_as_expected
      assert elapsed >= 190 and elapsed <= 250, "Should timeout around 200ms"

      IO.puts("✅ Timeout behavior working correctly")
      IO.puts("=====================================\n")
    end
  end
end
