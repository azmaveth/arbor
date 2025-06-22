defmodule Arbor.Core.MultiNodeTestHelper do
  @moduledoc """
  Helper functions for multi-node cluster testing.
  
  Provides utilities to spawn multiple Erlang nodes in separate OS processes
  for testing distributed behavior, node failures, and cluster resilience.
  """
  
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
    
    # Wait for nodes to connect
    :timer.sleep(1000)
    
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
    :timer.sleep(500)
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
    
    :timer.sleep(100)
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
    
    :timer.sleep(1000)
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
    case Arbor.Core.HordeSupervisor.get_agent_info(agent_id) do
      {:ok, agent_info} -> agent_info.node
      {:error, _} -> nil
    end
  end
  
  @doc """
  Get all agents running on a specific node.
  """
  @spec get_agents_on_node(node()) :: [String.t()]
  def get_agents_on_node(target_node) do
    case Arbor.Core.HordeSupervisor.list_agents() do
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
      registry_alive = :rpc.call(node, GenServer, :whereis, [Arbor.Core.HordeAgentRegistry]) != nil
      supervisor_alive = :rpc.call(node, GenServer, :whereis, [Arbor.Core.HordeAgentSupervisor]) != nil
      
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
    # Try modern :peer first (OTP 25+)
    case Code.ensure_loaded(:peer) do
      {:module, :peer} ->
        # :peer.start returns {:ok, pid, node} in OTP 25+
        case :peer.start(%{name: String.to_atom(node_name), host: String.to_charlist(host)}) do
          {:ok, _pid, node} -> {:ok, node}
          error -> error
        end
        
      {:error, :nofile} ->
        # Fallback to :slave for older OTP versions
        :slave.start(String.to_charlist(host), String.to_atom(node_name))
    end
  end
  
  defp stop_node(node) do
    Logger.info("Stopping node #{node}")
    
    case Code.ensure_loaded(:peer) do
      {:module, :peer} ->
        # :peer.stop requires the peer connection, not just the node
        # For now, we'll use a simple approach
        :rpc.call(node, :init, :stop, [])
        :timer.sleep(500)
        :ok
        
      {:error, :nofile} ->
        :slave.stop(node)
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
        test_node_name = :"test_controller@localhost"
        case :net_kernel.start([test_node_name, :shortnames]) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, reason} -> 
            Logger.warning("Could not start distributed Erlang: #{inspect(reason)}")
            :ok
        end
    end
  end
  
  defp wait_for_agent_distribution_loop(nodes, agent_ids, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      raise "Timeout waiting for agent distribution"
    end
    
    # Check if all agents are running somewhere in the cluster
    all_distributed = Enum.all?(agent_ids, fn agent_id ->
      get_agent_node(agent_id) != nil
    end)
    
    if all_distributed do
      :ok
    else
      :timer.sleep(200)
      wait_for_agent_distribution_loop(nodes, agent_ids, deadline)
    end
  end
end