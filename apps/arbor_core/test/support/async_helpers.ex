defmodule Arbor.Test.Support.AsyncHelpers do
  @moduledoc """
  Common async test helper functions extracted from various test files.

  This module provides reusable async assertions and utilities for testing
  distributed and concurrent behavior.
  """

  import ExUnit.Assertions

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
