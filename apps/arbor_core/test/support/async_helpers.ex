defmodule Arbor.Test.Support.AsyncHelpers do
  @moduledoc """
  Common async test helper functions extracted from various test files.

  This module provides reusable async assertions and utilities for testing
  distributed and concurrent behavior.

  ## Exponential Backoff Helpers

  The `wait_until/*` family of functions provide exponential backoff retry
  logic to replace fixed delays in tests. This makes tests both faster
  (completing as soon as conditions are met) and more reliable (handling
  timing variations better).

  ## Legacy Fixed-Delay Helpers

  The original `assert_eventually/*` functions are maintained for backward
  compatibility but should be migrated to use `wait_until/*` for better
  performance and reliability.
  """

  import ExUnit.Assertions
  alias Arbor.Core.HordeSupervisor

  # ================================
  # Exponential Backoff Helpers
  # ================================

  @doc """
  Wait for a condition to be met with exponential backoff.

  Polls the given function repeatedly until it returns a truthy value or
  the timeout is reached. Uses exponential backoff to balance responsiveness
  with resource usage.

  ## Options

  - `:timeout` - Maximum time to wait in milliseconds (default: 2000)
  - `:initial_delay` - Initial delay between polls in milliseconds (default: 10)
  - `:max_delay` - Maximum delay between polls in milliseconds (default: 160)
  - `:factor` - Multiplier for exponential backoff (default: 2)

  ## Examples

      # Wait for an agent to be ready
      wait_until(fn -> 
        case HordeSupervisor.get_agent_info(agent_id) do
          {:ok, _info} -> true
          {:error, :not_found} -> false
        end
      end)
      
      # Wait with custom timeout
      wait_until(fn -> some_condition() end, timeout: 5000)
      
      # Wait and capture the result
      info = wait_until(fn -> 
        case HordeSupervisor.get_agent_info(agent_id) do
          {:ok, info} -> info
          {:error, :not_found} -> false
        end
      end)
      
  ## Returns

  Returns the last truthy value returned by the function, or raises
  `ExUnit.AssertionError` if the timeout is reached.
  """
  @spec wait_until((-> any()), keyword()) :: any()
  def wait_until(fun, opts \\ []) when is_function(fun, 0) do
    timeout = Keyword.get(opts, :timeout, 2000)
    initial_delay = Keyword.get(opts, :initial_delay, 10)
    max_delay = Keyword.get(opts, :max_delay, 160)
    factor = Keyword.get(opts, :factor, 2)

    start_time = System.monotonic_time(:millisecond)

    do_wait_until(fun, initial_delay, max_delay, factor, timeout, start_time)
  end

  @doc """
  Wait for an agent to be ready after start_agent call.

  This is a convenience function that specifically waits for an agent
  to complete its asynchronous registration process after start_agent
  returns successfully.

  ## Examples

      {:ok, pid} = HordeSupervisor.start_agent(agent_spec)
      info = wait_for_agent_ready(agent_id)
      assert info.pid == pid
      
  ## Returns

  Returns the agent info map from `HordeSupervisor.get_agent_info/1`.
  """
  @spec wait_for_agent_ready(String.t(), keyword()) :: map()
  def wait_for_agent_ready(agent_id, opts \\ []) do
    wait_until(
      fn ->
        case HordeSupervisor.get_agent_info(agent_id) do
          {:ok, info} -> info
          {:error, :not_found} -> false
        end
      end,
      opts
    )
  end

  @doc """
  Wait for an agent to be stopped and no longer registered.

  This is useful when testing agent cleanup or stopping behavior.

  ## Examples

      HordeSupervisor.stop_agent(agent_id)
      wait_for_agent_stopped(agent_id)
      
  ## Returns

  Returns `:ok` when the agent is confirmed stopped.
  """
  @spec wait_for_agent_stopped(String.t(), keyword()) :: :ok
  def wait_for_agent_stopped(agent_id, opts \\ []) do
    wait_until(
      fn ->
        case HordeSupervisor.get_agent_info(agent_id) do
          {:error, :not_found} -> :ok
          {:ok, _info} -> false
        end
      end,
      opts
    )
  end

  @doc """
  Assert that a condition becomes true within the timeout period.

  This combines `wait_until/2` with ExUnit assertions for more readable tests.

  ## Examples

      assert_eventually_with_backoff(fn -> 
        {:ok, _info} = HordeSupervisor.get_agent_info(agent_id)
      end)
      
  ## Returns

  Returns the last value returned by the function if successful.
  Raises `ExUnit.AssertionError` if the timeout is reached.
  """
  @spec assert_eventually_with_backoff((-> any()), keyword()) :: any()
  def assert_eventually_with_backoff(fun, opts \\ []) when is_function(fun, 0) do
    wait_until(fun, opts)
  rescue
    ExUnit.AssertionError ->
      # Try one more time to get a better error message
      fun.()
  end

  # Private implementation for wait_until

  defp do_wait_until(fun, delay, max_delay, factor, timeout, start_time) do
    case fun.() do
      false ->
        check_timeout_and_continue(fun, delay, max_delay, factor, timeout, start_time)

      nil ->
        check_timeout_and_continue(fun, delay, max_delay, factor, timeout, start_time)

      result ->
        result
    end
  end

  defp check_timeout_and_continue(fun, delay, max_delay, factor, timeout, start_time) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    if elapsed > timeout do
      raise ExUnit.AssertionError,
            "Condition not met within #{timeout}ms timeout. " <>
              "Last attempt failed after #{elapsed}ms."
    else
      Process.sleep(delay)
      next_delay = min(delay * factor, max_delay)
      do_wait_until(fun, next_delay, max_delay, factor, timeout, start_time)
    end
  end

  # ================================
  # Legacy Fixed-Delay Helpers
  # ================================

  @doc """
  Asserts that a function eventually returns a truthy value.

  The function should return `:retry` to indicate it should be called again,
  or any other value to indicate success.

  ## Options
    - `max_attempts` - Maximum number of attempts before failing (default: 10)
    - `delay` - Delay in milliseconds between attempts (default: 100)
  """
  @spec assert_eventually(fun :: (-> any()), message :: String.t(), opts :: keyword()) :: any()
  def assert_eventually(fun, message, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 10)
    delay = Keyword.get(opts, :delay, 100)
    assert_eventually_helper(fun, message, max_attempts, delay, 1)
  end

  defp assert_eventually_helper(fun, message, max_attempts, delay, attempt)
       when attempt <= max_attempts do
    case fun.() do
      :retry when attempt < max_attempts ->
        :timer.sleep(delay)
        assert_eventually_helper(fun, message, max_attempts, delay, attempt + 1)

      :retry ->
        flunk("#{message} - max attempts (#{max_attempts}) exceeded")

      result ->
        result
    end
  end

  @doc """
  Waits for a process to be registered under a given name.

  Returns the PID when found, or `:timeout` after max attempts.
  """
  @spec wait_for_process(name :: atom() | {:via, module(), term()}, opts :: keyword()) ::
          {:ok, pid()} | :timeout
  def wait_for_process(name, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 20)
    delay = Keyword.get(opts, :delay, 50)

    do_wait_for_process(name, max_attempts, delay, 1)
  end

  defp do_wait_for_process(_name, max_attempts, _delay, attempt) when attempt > max_attempts do
    :timeout
  end

  defp do_wait_for_process(name, max_attempts, delay, attempt) do
    case GenServer.whereis(name) do
      nil ->
        :timer.sleep(delay)
        do_wait_for_process(name, max_attempts, delay, attempt + 1)

      pid when is_pid(pid) ->
        {:ok, pid}
    end
  end

  @doc """
  Asserts that a condition becomes true within a timeout period.

  Similar to assert_eventually but with a simpler boolean interface.
  """
  @spec assert_within_timeout(condition :: (-> boolean()), timeout :: pos_integer()) :: :ok
  def assert_within_timeout(condition, timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    assert_within_timeout_loop(condition, deadline)
  end

  defp assert_within_timeout_loop(condition, deadline) do
    if condition.() do
      :ok
    else
      now = System.monotonic_time(:millisecond)

      if now < deadline do
        :timer.sleep(50)
        assert_within_timeout_loop(condition, deadline)
      else
        flunk("Condition did not become true within timeout")
      end
    end
  end

  @doc """
  Repeatedly calls a function until it returns {:ok, result} or times out.

  Returns {:ok, result} on success or {:error, :timeout} on timeout.
  """
  @spec retry_until_ok(fun :: (-> {:ok, any()} | any()), opts :: keyword()) ::
          {:ok, any()} | {:error, :timeout}
  def retry_until_ok(fun, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 10)
    delay = Keyword.get(opts, :delay, 100)

    do_retry_until_ok(fun, max_attempts, delay, 1)
  end

  defp do_retry_until_ok(_fun, max_attempts, _delay, attempt) when attempt > max_attempts do
    {:error, :timeout}
  end

  defp do_retry_until_ok(fun, max_attempts, delay, attempt) do
    case fun.() do
      {:ok, result} ->
        {:ok, result}

      _ ->
        :timer.sleep(delay)
        do_retry_until_ok(fun, max_attempts, delay, attempt + 1)
    end
  end
end
