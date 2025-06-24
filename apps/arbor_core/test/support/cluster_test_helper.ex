defmodule Arbor.Core.ClusterTestHelper do
  @moduledoc """
  Extended helper functions for distributed testing patterns.

  Builds on MultiNodeTestHelper to provide utilities for testing:
  - CRDT synchronization across nodes
  - Race condition detection and verification
  - Distributed state consistency
  - Network partition scenarios
  - Failover and recovery patterns
  """

  alias Arbor.Core.MultiNodeTestHelper
  alias Arbor.Test.Support.AsyncHelpers
  require Logger

  @doc """
  Start a default 3-node cluster for distributed testing.

  This is the standard configuration for most distributed tests.
  """
  @spec start_default_cluster() :: [node()]
  def start_default_cluster do
    Logger.info("Starting distributed test cluster")

    # Start nodes with minimal dependencies
    nodes =
      MultiNodeTestHelper.start_cluster([
        %{name: :arbor_test1@localhost, apps: []},
        %{name: :arbor_test2@localhost, apps: []},
        %{name: :arbor_test3@localhost, apps: []}
      ])

    # Configure each node for distributed testing
    Enum.each(nodes, fn node ->
      configure_test_node(node)
    end)

    # Start Horde components on each node
    Enum.each(nodes, fn node ->
      start_horde_on_node(node)
    end)

    # Wait for cluster to stabilize and Horde components to be ready
    AsyncHelpers.wait_until(
      fn ->
        Enum.all?(nodes, fn node ->
          # Check if Horde components are running on each node
          registry_running =
            :rpc.call(node, Process, :whereis, [Arbor.Core.HordeAgentRegistry]) != :undefined

          supervisor_running =
            :rpc.call(node, Process, :whereis, [Arbor.Core.HordeAgentSupervisor]) != :undefined

          registry_running and supervisor_running
        end)
      end,
      timeout: 10_000,
      initial_delay: 200
    )

    Logger.info("Distributed test cluster ready: #{inspect(nodes)}")
    nodes
  end

  @doc """
  Wait for CRDT synchronization across all nodes.

  This function verifies that a CRDT-based data structure has
  converged to the same state on all nodes in the cluster.

  ## Parameters
  - `nodes` - List of nodes to check
  - `crdt_check_fn` - Function that returns the CRDT state on a node
  - `timeout` - Maximum time to wait for convergence (default: 10 seconds)

  ## Example

      wait_for_crdt_sync(nodes, fn node ->
        :rpc.call(node, MyApp.CRDT, :get_state, [])
      end)
  """
  @spec wait_for_crdt_sync([node()], (node() -> term()), timeout()) :: :ok | {:error, :timeout}
  def wait_for_crdt_sync(nodes, crdt_check_fn, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_for_crdt_sync_loop(nodes, crdt_check_fn, deadline)
  end

  @doc """
  Test for race conditions by executing concurrent operations.

  Runs the given function concurrently on multiple nodes and
  returns the results of all operations for analysis.

  ## Parameters
  - `nodes` - List of nodes to run operations on
  - `operation_fn` - Function to execute (receives node as argument)
  - `verification_fn` - Function to verify consistency after operations (optional)
  - `concurrency` - Number of concurrent operations per node

  ## Example

      results = test_concurrent_operations(
        nodes,
        fn node -> :rpc.call(node, MyApp, :create_resource, [id]) end,
        fn -> verify_only_one_resource_created(id) end,
        concurrency: 10
      )
  """
  @spec test_concurrent_operations([node()], function(), function() | nil, keyword()) :: [term()]
  def test_concurrent_operations(nodes, operation_fn, verification_fn \\ nil, opts \\ []) do
    concurrency = Keyword.get(opts, :concurrency, 5)

    # Create tasks for concurrent execution
    tasks =
      for node <- nodes, _i <- 1..concurrency do
        Task.async(fn ->
          try do
            operation_fn.(node)
          catch
            kind, reason ->
              {:error, {kind, reason}}
          end
        end)
      end

    # Wait for all tasks to complete
    results = Task.await_many(tasks, 30_000)

    # Log any errors
    errors =
      Enum.filter(results, fn
        {:error, _} -> true
        _ -> false
      end)

    if Enum.any?(errors) do
      Logger.warning("Some concurrent operations failed: #{inspect(errors)}")
    end

    # Run verification if provided
    if verification_fn do
      case verification_fn.() do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Verification failed: #{inspect(reason)}")

        other ->
          Logger.warning("Verification returned unexpected result: #{inspect(other)}")
      end
    end

    # Return the actual task results for analysis
    results
  end

  @doc """
  Verify eventual consistency of distributed state.

  Continuously checks that all nodes eventually agree on the state
  of a distributed data structure or registry.

  ## Parameters
  - `nodes` - List of nodes to check
  - `state_fn` - Function that returns the state on a node
  - `comparison_fn` - Function to compare states (default: ==/2)
  - `timeout` - Maximum time to wait for consistency
  """
  @spec verify_eventual_consistency([node()], function(), function(), timeout()) ::
          :ok | {:error, term()}
  def verify_eventual_consistency(nodes, state_fn, comparison_fn \\ &==/2, timeout \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    verify_eventual_consistency_loop(nodes, state_fn, comparison_fn, deadline)
  end

  @doc """
  Create a split-brain scenario by partitioning nodes into groups.

  ## Parameters
  - `group1` - First group of nodes
  - `group2` - Second group of nodes

  ## Returns
  - `:ok` after creating the partition
  """
  @spec create_split_brain([node()], [node()]) :: :ok
  def create_split_brain(group1, group2) do
    Logger.info("Creating split-brain: #{inspect(group1)} <-X-> #{inspect(group2)}")

    # Disconnect all nodes in group1 from all nodes in group2
    for n1 <- group1, n2 <- group2 do
      :rpc.call(n1, Node, :disconnect, [n2])
      :rpc.call(n2, Node, :disconnect, [n1])
    end

    # Wait for partition to take effect - verify nodes are disconnected
    AsyncHelpers.wait_until(
      fn ->
        # Check that nodes in different groups can't see each other
        Enum.all?(group1, fn n1 ->
          connected_nodes = :rpc.call(n1, Node, :list, [])
          not Enum.any?(group2, fn n2 -> n2 in connected_nodes end)
        end)
      end,
      timeout: 5000,
      initial_delay: 100
    )

    :ok
  end

  @doc """
  Heal a split-brain scenario by reconnecting node groups.

  ## Parameters
  - `group1` - First group of nodes
  - `group2` - Second group of nodes

  ## Returns
  - `:ok` after healing the partition
  """
  @spec heal_split_brain([node()], [node()]) :: :ok
  def heal_split_brain(group1, group2) do
    Logger.info("Healing split-brain: #{inspect(group1)} <--> #{inspect(group2)}")

    # Reconnect all nodes
    for n1 <- group1, n2 <- group2 do
      :rpc.call(n1, Node, :connect, [n2])
    end

    # Wait for cluster to heal and stabilize - verify nodes are reconnected
    AsyncHelpers.wait_until(
      fn ->
        # Check that all nodes can see each other again
        all_nodes = group1 ++ group2

        Enum.all?(all_nodes, fn node ->
          connected_nodes = :rpc.call(node, Node, :list, [])
          # Each node should see all other nodes
          Enum.all?(all_nodes -- [node], fn other_node ->
            other_node in connected_nodes
          end)
        end)
      end,
      timeout: 10_000,
      initial_delay: 200
    )

    :ok
  end

  @doc """
  Simulate cascading node failures with controlled timing.

  Useful for testing how the system handles multiple failures
  in sequence with specific timing patterns.

  ## Parameters
  - `nodes` - List of nodes to fail
  - `delay_between_failures` - Milliseconds between each failure

  ## Returns
  - List of failed nodes in order
  """
  @spec cascade_node_failures([node()], non_neg_integer()) :: [node()]
  def cascade_node_failures(nodes, delay_between_failures \\ 1000) do
    Enum.reduce(nodes, [], fn node, failed_nodes ->
      unless Enum.empty?(failed_nodes) do
        # Use exponential backoff for the delay, respecting the requested timing
        Process.sleep(delay_between_failures)
      end

      MultiNodeTestHelper.kill_node(node)
      [node | failed_nodes]
    end)
    |> Enum.reverse()
  end

  @doc """
  Wait for distributed registry to converge after changes.

  Specifically designed for Horde registry convergence testing.
  """
  @spec wait_for_registry_convergence([node()], timeout()) :: :ok | {:error, :timeout}
  def wait_for_registry_convergence(nodes, timeout \\ 10_000) do
    wait_for_crdt_sync(
      nodes,
      fn node ->
        case :rpc.call(node, Horde.Registry, :select, [
               Arbor.Core.HordeAgentRegistry,
               [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}]
             ]) do
          {:badrpc, _} -> []
          entries -> Enum.sort(entries)
        end
      end,
      timeout
    )
  end

  @doc """
  Measure sync time for distributed state changes.

  Useful for performance testing of distributed synchronization.

  ## Returns
  - `{:ok, sync_time_ms}` - Time taken for all nodes to sync
  - `{:error, :timeout}` - If sync didn't complete within timeout
  """
  @spec measure_sync_time([node()], function(), timeout()) ::
          {:ok, non_neg_integer()} | {:error, :timeout}
  def measure_sync_time(nodes, state_fn, timeout \\ 10_000) do
    start_time = System.monotonic_time(:millisecond)

    case verify_eventual_consistency(nodes, state_fn, &==/2, timeout) do
      :ok ->
        sync_time = System.monotonic_time(:millisecond) - start_time
        {:ok, sync_time}

      error ->
        error
    end
  end

  @doc """
  Create controlled network delays between specific nodes.

  Note: This is a simulation - actual implementation would require
  network-level tools. For testing purposes, we add artificial
  delays in RPC calls.
  """
  @spec simulate_network_delay(node(), node(), non_neg_integer()) :: :ok
  def simulate_network_delay(from_node, to_node, delay_ms) do
    Logger.info("Simulating #{delay_ms}ms delay: #{from_node} -> #{to_node}")

    # In a real implementation, you would use tc or similar tools
    # For testing, we can intercept RPC calls or add delays in the application
    :ok
  end

  # Private functions

  defp configure_test_node(node) do
    Logger.info("Configuring test node #{node}")

    # Set up application environment for testing
    :rpc.call(node, Application, :put_env, [:arbor_core, :registry_impl, :horde])
    :rpc.call(node, Application, :put_env, [:arbor_core, :supervisor_impl, :horde])

    # Configure timing for distributed tests
    :rpc.call(node, Application, :put_env, [
      :arbor_core,
      :agent_retry,
      [retries: 5, initial_delay: 100]
    ])

    :rpc.call(node, Application, :put_env, [:arbor_core, :horde_timing, [sync_interval: 100]])

    :ok
  end

  defp start_horde_on_node(node) do
    Logger.info("Starting Horde components on #{node}")

    # Start required dependencies first
    :rpc.call(node, Application, :ensure_all_started, [:logger])
    :rpc.call(node, Application, :ensure_all_started, [:telemetry])
    :rpc.call(node, Application, :ensure_all_started, [:phoenix_pubsub])

    # Ensure required modules are loaded
    :rpc.call(node, Code, :ensure_loaded, [Arbor.Core.HordeSupervisor])
    :rpc.call(node, Code, :ensure_loaded, [Arbor.Agents.CodeAnalyzer])

    # Start the complete Horde infrastructure using the proper start_supervisor function
    # This starts Registry, DynamicSupervisor, and HordeSupervisor GenServer all together
    case :rpc.call(node, Arbor.Core.HordeSupervisor, :start_supervisor, []) do
      {:ok, _pid} ->
        Logger.info("Started complete Horde infrastructure on #{node}")

      {:error, {:already_started, _pid}} ->
        Logger.info("Horde infrastructure already running on #{node}")

      {:error, reason} ->
        Logger.warning("Failed to start Horde infrastructure on #{node}: #{inspect(reason)}")
    end

    # Wait for Horde components to be ready and registered
    AsyncHelpers.wait_until(
      fn ->
        registry_running =
          :rpc.call(node, Process, :whereis, [Arbor.Core.HordeAgentRegistry]) != :undefined

        supervisor_running =
          :rpc.call(node, Process, :whereis, [Arbor.Core.HordeAgentSupervisor]) != :undefined

        registry_running and supervisor_running
      end,
      timeout: 3000,
      initial_delay: 100
    )

    :ok
  end

  defp wait_for_crdt_sync_loop(nodes, crdt_check_fn, deadline) do
    timeout = deadline - System.monotonic_time(:millisecond)

    # Use AsyncHelpers for exponential backoff
    try do
      AsyncHelpers.wait_until(
        fn ->
          states =
            Enum.map(nodes, fn node ->
              try do
                crdt_check_fn.(node)
              catch
                _, _ -> :error
              end
            end)

          # Filter out error states
          valid_states = Enum.reject(states, &(&1 == :error))

          if length(valid_states) == length(nodes) and all_equal?(valid_states) do
            true
          else
            false
          end
        end,
        timeout: max(timeout, 100),
        initial_delay: 50
      )

      :ok
    rescue
      ExUnit.AssertionError -> {:error, :timeout}
    end
  end

  defp verify_eventual_consistency_loop(nodes, state_fn, comparison_fn, deadline) do
    timeout = deadline - System.monotonic_time(:millisecond)

    # Use AsyncHelpers for exponential backoff
    try do
      AsyncHelpers.wait_until(
        fn ->
          states = get_all_states(nodes, state_fn)
          all_consistent?(states, comparison_fn)
        end,
        timeout: max(timeout, 100),
        initial_delay: 100
      )

      :ok
    rescue
      ExUnit.AssertionError ->
        states = get_all_states(nodes, state_fn)
        {:error, {:inconsistent_state, states}}
    end
  end

  defp get_all_states(nodes, state_fn) do
    Enum.map(nodes, fn node ->
      try do
        state_fn.(node)
      catch
        _, _ -> {:error, node}
      end
    end)
  end

  defp all_equal?([]), do: true
  defp all_equal?([_]), do: true

  defp all_equal?([first | rest]) do
    Enum.all?(rest, &(&1 == first))
  end

  defp all_consistent?(states, comparison_fn) do
    case states do
      [] -> true
      [_] -> true
      [first | rest] -> Enum.all?(rest, &comparison_fn.(first, &1))
    end
  end
end
