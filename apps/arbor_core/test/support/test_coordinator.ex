defmodule Arbor.Test.Support.TestCoordinator do
  @moduledoc """
  Provides coordination utilities for parallel test execution.

  This module helps prevent conflicts when multiple test processes
  are running concurrently by:

  - Providing unique namespacing for test resources
  - Coordinating access to shared resources
  - Implementing test-specific locks when needed
  """

  @doc """
  Generates a unique test ID with optional prefix.

  ## Examples

      iex> unique_test_id("agent")
      "agent-test-1234567890-98765"
      
      iex> unique_test_id()
      "test-1234567890-98765"
  """
  def unique_test_id(prefix \\ "test") do
    timestamp = System.system_time(:microsecond)
    unique_ref = System.unique_integer([:positive])
    "#{prefix}-#{timestamp}-#{unique_ref}"
  end

  @doc """
  Executes a function with exclusive access to a named resource.

  This is useful when tests need to perform operations that could
  conflict if run concurrently.

  ## Examples

      with_exclusive_access(:cluster_membership, fn ->
        # Modify cluster membership safely
        Horde.Cluster.set_members(...)
      end)
  """
  def with_exclusive_access(resource_name, timeout \\ 5_000, fun) do
    lock_name = {:test_lock, resource_name}

    case :global.set_lock(lock_name, [node()], 1) do
      true ->
        try do
          fun.()
        after
          :global.del_lock(lock_name, [node()])
        end

      false ->
        # Wait and retry
        Process.sleep(50)
        with_exclusive_access(resource_name, timeout - 50, fun)
    end
  end

  @doc """
  Waits for a condition with better error reporting.

  Similar to AsyncHelpers.wait_until but provides more context on failure.
  """
  def wait_for(description, opts \\ [], condition_fn) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    interval = Keyword.get(opts, :interval, 100)

    deadline = System.monotonic_time(:millisecond) + timeout

    wait_for_loop(description, deadline, interval, condition_fn)
  end

  defp wait_for_loop(description, deadline, interval, condition_fn) do
    case condition_fn.() do
      true ->
        :ok

      false ->
        now = System.monotonic_time(:millisecond)

        if now >= deadline do
          raise "Timeout waiting for: #{description}"
        else
          Process.sleep(interval)
          wait_for_loop(description, deadline, interval, condition_fn)
        end

      {:ok, result} ->
        {:ok, result}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Ensures test agents are namespaced to prevent conflicts.

  ## Examples

      agent_spec = namespace_agent_spec(%{
        id: "my-agent",
        module: MyAgent,
        args: []
      }, "test-123")
      
      # Returns spec with id: "my-agent-test-123"
  """
  def namespace_agent_spec(spec, namespace) do
    Map.update!(spec, :id, fn id -> "#{id}-#{namespace}" end)
  end

  @doc """
  Cleans up all agents matching a namespace pattern.
  """
  def cleanup_namespaced_agents(namespace) do
    registry_name = Arbor.Core.HordeAgentRegistry
    supervisor_name = Arbor.Core.HordeAgentSupervisor

    # Find and stop agents with matching namespace
    try do
      children = Horde.DynamicSupervisor.which_children(supervisor_name)

      for {agent_id, _pid, _type, _modules} <- children do
        if is_binary(agent_id) and String.contains?(agent_id, namespace) do
          Arbor.Core.HordeSupervisor.stop_agent(agent_id)
        end
      end
    rescue
      _ -> :ok
    end

    # Clean up registry entries
    try do
      pattern = {{:agent_spec, :"$1"}, :"$2", :"$3"}
      specs = Horde.Registry.select(registry_name, [{pattern, [], [:"$1"]}])

      for agent_id <- specs do
        if is_binary(agent_id) and String.contains?(agent_id, namespace) do
          Horde.Registry.unregister(registry_name, {:agent_spec, agent_id})
          Horde.Registry.unregister(registry_name, {:agent_checkpoint, agent_id})
        end
      end
    rescue
      _ -> :ok
    end
  end

  @doc """
  Provides a test-specific logger metadata context.
  """
  def with_test_logging(test_name, fun) do
    previous_metadata = Logger.metadata()

    Logger.metadata(
      test: test_name,
      test_pid: self(),
      test_timestamp: System.system_time(:microsecond)
    )

    try do
      fun.()
    after
      Logger.reset_metadata(previous_metadata)
    end
  end

  @doc """
  Retries an operation with exponential backoff.

  Useful for operations that might fail due to timing issues
  in distributed systems.
  """
  def retry_with_backoff(description, opts \\ [], fun) do
    max_attempts = Keyword.get(opts, :max_attempts, 3)
    base_delay = Keyword.get(opts, :base_delay, 100)

    retry_with_backoff_loop(description, fun, 1, max_attempts, base_delay)
  end

  defp retry_with_backoff_loop(_description, fun, attempt, max_attempts, _base_delay)
       when attempt > max_attempts do
    # Last attempt, let it fail with original error
    fun.()
  end

  defp retry_with_backoff_loop(description, fun, attempt, max_attempts, base_delay) do
    case fun.() do
      {:ok, _result} = success ->
        success

      :ok ->
        :ok

      {:error, reason} = error ->
        if attempt < max_attempts do
          delay = (base_delay * :math.pow(2, attempt - 1)) |> round()
          Process.sleep(delay)
          retry_with_backoff_loop(description, fun, attempt + 1, max_attempts, base_delay)
        else
          error
        end

      other ->
        other
    end
  rescue
    error ->
      if attempt < max_attempts do
        delay = (base_delay * :math.pow(2, attempt - 1)) |> round()
        Process.sleep(delay)
        retry_with_backoff_loop(description, fun, attempt + 1, max_attempts, base_delay)
      else
        reraise error, __STACKTRACE__
      end
  end
end
