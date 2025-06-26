defmodule Arbor.Core.MultiNodeTestHelper do
  @moduledoc """
  Helper functions for multi-node cluster testing.

  Provides utilities to spawn multiple Erlang nodes in separate OS processes
  for testing distributed behavior, node failures, and cluster resilience.
  """

  alias Arbor.Test.Support.AsyncHelpers
  alias HordeSupervisor

  require Logger

  @type node_config :: %{
          name: atom(),
          apps: [atom()],
          config: keyword()
        }

  @doc """
  Start a multi-node cluster for testing.

  ## Example

      nodes = MultiNodeTestHelper.start_cluster([
        %{name: :node1@localhost, apps: [:arbor_core]},
        %{name: :node2@localhost, apps: [:arbor_core]},
        %{name: :node3@localhost, apps: [:arbor_core]}
      ])

      # Run tests...

      MultiNodeTestHelper.stop_cluster(nodes)
  """
  @spec start_cluster([node_config()]) :: [node()]
  def start_cluster(node_configs) do
    Logger.info("Starting multi-node cluster with #{length(node_configs)} nodes")

    # Start distributed Erlang on this node if not already started
    ensure_distributed()

    # Start each node in the cluster
    nodes = Enum.map(node_configs, &start_node/1)

    # Wait for nodes to connect to each other
    AsyncHelpers.wait_until(
      fn ->
        # Check if all nodes can see each other
        Enum.all?(nodes, fn node ->
          case :rpc.call(node, Node, :list, []) do
            {:badrpc, _} ->
              false

            connected_nodes when is_list(connected_nodes) ->
              expected_peers = nodes -- [node]
              Enum.all?(expected_peers, &(&1 in connected_nodes))
          end
        end)
      end,
      timeout: 5000,
      initial_delay: 200
    )

    # Verify all nodes can see each other
    Enum.each(nodes, fn node ->
      case :rpc.call(node, Node, :list, []) do
        {:badrpc, _} ->
          # Fallback for when Node.list() is not available on remote node
          Logger.warning("Could not check connected nodes on #{node}")

        connected_nodes when is_list(connected_nodes) ->
          expected_peers = nodes -- [node]

          unless Enum.all?(expected_peers, &(&1 in connected_nodes)) do
            Logger.warning("Node #{node} cannot see all peers: #{inspect(connected_nodes)}")
          end
      end
    end)

    Logger.info("Multi-node cluster started: #{inspect(nodes)}")
    nodes
  end

  @doc """
  Stop all nodes in a cluster.
  """
  @spec stop_cluster([node()]) :: :ok
  def stop_cluster(nodes) do
    Enum.each(nodes, &stop_node/1)
    Logger.info("Stopped multi-node cluster")
    :ok
  end

  @doc """
  Forcefully kill a node to simulate a crash.
  """
  @spec kill_node(node()) :: :ok
  def kill_node(node) do
    Logger.info("Killing node #{node}")
    :rpc.call(node, :erlang, :halt, [])

    # Wait for node to actually die
    AsyncHelpers.wait_until(
      fn ->
        node not in Node.list() and :rpc.call(node, :erlang, :node, []) == {:badrpc, :nodedown}
      end,
      timeout: 3000,
      initial_delay: 100
    )

    :ok
  end

  @doc """
  Create a network partition by disconnecting a node from the cluster.
  """
  @spec partition_node(node()) :: :ok
  def partition_node(node) do
    Logger.info("Partitioning node #{node}")
    other_nodes = Node.list() -- [node]

    # Disconnect the node from all others
    Enum.each(other_nodes, fn other_node ->
      :rpc.call(node, Node, :disconnect, [other_node])
      :rpc.call(other_node, Node, :disconnect, [node])
    end)

    # Wait for partition to take effect
    AsyncHelpers.wait_until(
      fn ->
        # Verify node is disconnected from others
        case :rpc.call(node, Node, :list, []) do
          {:badrpc, _} -> true
          connected_nodes -> not Enum.any?(other_nodes, &(&1 in connected_nodes))
        end
      end,
      timeout: 2000,
      initial_delay: 50
    )

    :ok
  end

  @doc """
  Heal a network partition by reconnecting a node.
  """
  @spec heal_partition(node()) :: :ok
  def heal_partition(node) do
    Logger.info("Healing partition for node #{node}")
    other_nodes = Node.list()

    # Reconnect the node to all others
    Enum.each(other_nodes, fn other_node ->
      :rpc.call(node, Node, :connect, [other_node])
    end)

    # Wait for partition to heal - verify node can see others again
    AsyncHelpers.wait_until(
      fn ->
        case :rpc.call(node, Node, :list, []) do
          {:badrpc, _} -> false
          connected_nodes -> Enum.all?(other_nodes, &(&1 in connected_nodes))
        end
      end,
      timeout: 5000,
      initial_delay: 200
    )

    :ok
  end

  @doc """
  Wait for agents to be distributed across the cluster.
  """
  @spec wait_for_agent_distribution([node()], [String.t()], timeout()) :: :ok
  def wait_for_agent_distribution(nodes, agent_ids, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    wait_for_agent_distribution_loop(nodes, agent_ids, deadline)
  end

  @doc """
  Get which node an agent is currently running on.
  """
  @spec get_agent_node(String.t()) :: node() | nil
  def get_agent_node(agent_id) do
    case HordeSupervisor.get_agent_info(agent_id) do
      {:ok, agent_info} -> agent_info.node
      {:error, _} -> nil
    end
  end

  @doc """
  Get all agents running on a specific node.
  """
  @spec get_agents_on_node(node()) :: [String.t()]
  def get_agents_on_node(target_node) do
    case HordeSupervisor.list_agents() do
      {:ok, agents} ->
        agents
        |> Enum.filter(&(&1.node == target_node))
        |> Enum.map(& &1.id)

      {:error, _} ->
        []
    end
  end

  @doc """
  Verify cluster health by checking Horde components.
  """
  @spec verify_cluster_health([node()]) :: :ok | {:error, term()}
  def verify_cluster_health(nodes) do
    Enum.each(nodes, fn node ->
      # Check if Horde registry is running
      registry_alive =
        :rpc.call(node, GenServer, :whereis, [Arbor.Core.HordeAgentRegistry]) != nil

      supervisor_alive =
        :rpc.call(node, GenServer, :whereis, [Arbor.Core.HordeAgentSupervisor]) != nil

      unless registry_alive and supervisor_alive do
        raise "Horde components not running on #{node}"
      end
    end)

    :ok
  end

  # Private helpers

  defp start_node(%{name: node_name, apps: apps} = config) do
    # Start the node using :slave.start/2
    host = node_name |> to_string() |> String.split("@") |> List.last()
    node_short_name = node_name |> to_string() |> String.split("@") |> List.first()

    Logger.info("Starting node #{node_name}")

    # Use :peer module if available (OTP 25+), fallback to :slave
    case start_node_process(node_short_name, host) do
      {:ok, node} ->
        # First, ensure the code paths are set up on the remote node
        code_paths = :code.get_path()
        :rpc.call(node, :code, :add_paths, [code_paths])

        # Load applications on the remote node
        Enum.each(apps, fn app ->
          case :rpc.call(node, Application, :ensure_all_started, [app]) do
            {:ok, _} ->
              Logger.info("Started #{app} on #{node}")

            {:error, reason} ->
              Logger.warning("Failed to start #{app} on #{node}: #{inspect(reason)}")
          end
        end)

        # Apply any specific configuration
        apply_node_config(node, Map.get(config, :config, []))

        node

      {:error, reason} ->
        raise "Failed to start node #{node_name}: #{inspect(reason)}"
    end
  end

  defp start_node_process(node_name, host) do
    # Use modern :peer (OTP 25+)
    case Code.ensure_loaded(:peer) do
      {:module, :peer} ->
        # :peer.start returns {:ok, pid, node} in OTP 25+
        case :peer.start(%{name: String.to_atom(node_name), host: String.to_charlist(host)}) do
          {:ok, _pid, node} -> {:ok, node}
          error -> error
        end

      {:error, :nofile} ->
        {:error, :peer_not_available}
    end
  end

  defp stop_node(node) do
    Logger.info("Stopping node #{node}")

    case Code.ensure_loaded(:peer) do
      {:module, :peer} ->
        # :peer.stop requires the peer connection, not just the node
        # For now, we'll use a simple approach
        :rpc.call(node, :init, :stop, [])

        # Wait for node to stop
        AsyncHelpers.wait_until(
          fn ->
            node not in Node.list() and
              :rpc.call(node, :erlang, :node, []) == {:badrpc, :nodedown}
          end,
          timeout: 3000,
          initial_delay: 100
        )

        :ok

      {:error, :nofile} ->
        {:error, :peer_not_available}
    end
  end

  defp apply_node_config(node, config) do
    Enum.each(config, fn {app, app_config} ->
      Enum.each(app_config, fn {key, value} ->
        :rpc.call(node, Application, :put_env, [app, key, value])
      end)
    end)
  end

  defp ensure_distributed do
    case Node.alive?() do
      true ->
        :ok

      false ->
        test_node_name = :test_controller@localhost

        case :net_kernel.start([test_node_name, :shortnames]) do
          {:ok, _} ->
            :ok

          {:error, {:already_started, _}} ->
            :ok

          {:error, reason} ->
            Logger.warning("Could not start distributed Erlang: #{inspect(reason)}")
            :ok
        end
    end
  end

  defp wait_for_agent_distribution_loop(_nodes, agent_ids, deadline) do
    timeout = deadline - System.monotonic_time(:millisecond)

    # Use AsyncHelpers for exponential backoff
    try do
      AsyncHelpers.wait_until(
        fn ->
          # Check if all agents are running somewhere in the cluster
          Enum.all?(agent_ids, fn agent_id ->
            get_agent_node(agent_id) != nil
          end)
        end,
        timeout: max(timeout, 100),
        initial_delay: 100
      )

      :ok
    rescue
      e in ExUnit.AssertionError -> reraise e, __STACKTRACE__
    end
  end
end
