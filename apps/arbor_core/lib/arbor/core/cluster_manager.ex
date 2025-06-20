defmodule Arbor.Core.ClusterManager do
  @moduledoc """
  Manages cluster formation and node lifecycle events using libcluster.

  This module integrates libcluster for automatic node discovery and manages
  the lifecycle of Horde-based distributed components across the cluster.

  ## Features

  - Automatic node discovery via multiple strategies (Gossip, Kubernetes, etc.)
  - Graceful handling of node join/leave events
  - Automatic Horde cluster membership management
  - Coordination of distributed component lifecycle
  - Health monitoring and alerting

  ## Configuration

  Configure libcluster topologies in your config:

      config :libcluster,
        topologies: [
          arbor: [
            strategy: Cluster.Strategy.Gossip,
            config: [
              port: 45892,
              if_addr: "0.0.0.0",
              multicast_addr: "255.255.255.255",
              multicast_ttl: 1,
              secret: "arbor_cluster_secret"
            ]
          ]
        ]

  For production Kubernetes deployments:

      config :libcluster,
        topologies: [
          arbor: [
            strategy: Elixir.Cluster.Strategy.Kubernetes,
            config: [
              mode: :hostname,
              kubernetes_node_basename: "arbor",
              kubernetes_selector: "app=arbor",
              kubernetes_namespace: "default",
              polling_interval: 10_000
            ]
          ]
        ]
  """

  use GenServer
  require Logger

  alias Arbor.Core.{HordeRegistry, HordeSupervisor, HordeCoordinator, ClusterCoordinator}

  @type topology :: atom()
  @type node_event :: :nodeup | :nodedown

  defstruct [
    :topology,
    :connected_nodes,
    :node_monitors,
    :startup_time,
    :event_handlers,
    :node_health_data,
    :health_check_timer,
    :last_health_check
  ]

  # Client API

  @doc """
  Start the cluster manager.

  Options:
  - `:topology` - The libcluster topology name (default: `:arbor`)
  - `:connect_timeout` - Timeout for initial cluster connection (default: 30_000)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get current cluster status.

  Returns information about connected nodes, cluster health, and component status.
  """
  @spec cluster_status() :: %{
          nodes: [node()],
          connected_nodes: non_neg_integer(),
          topology: atom(),
          components: %{
            registry: :up | :down,
            supervisor: :up | :down,
            coordinator: :up | :down
          },
          uptime: non_neg_integer()
        }
  def cluster_status() do
    GenServer.call(__MODULE__, :cluster_status)
  end

  @doc """
  Manually connect to a specific node.

  Useful for debugging or manual cluster formation.
  """
  @spec connect_node(node()) :: :ok | {:error, term()}
  def connect_node(node) do
    GenServer.call(__MODULE__, {:connect_node, node})
  end

  @doc """
  Disconnect from a specific node.

  The node will be removed from the Horde cluster memberships.
  """
  @spec disconnect_node(node()) :: :ok
  def disconnect_node(node) do
    GenServer.call(__MODULE__, {:disconnect_node, node})
  end

  @doc """
  Register a callback for node lifecycle events.

  The callback will be invoked with `{:nodeup, node}` or `{:nodedown, node}`.
  """
  @spec register_event_handler((node_event(), node() -> any())) :: :ok
  def register_event_handler(callback) when is_function(callback, 2) do
    GenServer.call(__MODULE__, {:register_event_handler, callback})
  end

  @doc """
  Force cluster reformation.

  This will disconnect all nodes and reform the cluster based on
  the configured topology. Use with caution in production.
  """
  @spec reform_cluster() :: :ok
  def reform_cluster() do
    GenServer.call(__MODULE__, :reform_cluster)
  end

  @doc """
  Get detailed health information for all cluster nodes.

  Returns comprehensive health data including:
  - Node connectivity status
  - Horde component health per node
  - Resource utilization metrics
  - Last health check timestamps
  """
  @spec get_cluster_health() :: {:ok, map()} | {:error, term()}
  def get_cluster_health() do
    GenServer.call(__MODULE__, :get_cluster_health)
  end

  @doc """
  Get health information for a specific node.
  """
  @spec get_node_health(node()) :: {:ok, map()} | {:error, term()}
  def get_node_health(node) do
    GenServer.call(__MODULE__, {:get_node_health, node})
  end

  @doc """
  Force a health check across all cluster nodes.
  """
  @spec perform_health_check() :: :ok
  def perform_health_check() do
    GenServer.call(__MODULE__, :perform_health_check)
  end

  # GenServer callbacks

  @impl GenServer
  def init(opts) do
    # Trap exits to handle node failures gracefully
    Process.flag(:trap_exit, true)

    # Start monitoring for node events
    :net_kernel.monitor_nodes(true, node_type: :visible)

    # Determine topology key based on environment
    topology = Keyword.get(opts, :topology, get_topology_key())

    state = %__MODULE__{
      topology: topology,
      connected_nodes: [],
      node_monitors: %{},
      startup_time: System.system_time(:second),
      event_handlers: [],
      node_health_data: %{},
      health_check_timer: nil,
      last_health_check: nil
    }

    # Give libcluster time to discover nodes
    Process.send_after(self(), :initialize_cluster, 1000)

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:cluster_status, _from, state) do
    status = %{
      nodes: [node() | state.connected_nodes],
      connected_nodes: length(state.connected_nodes),
      topology: state.topology,
      components: %{
        registry: check_component_health(&HordeRegistry.get_registry_status/0),
        supervisor: check_component_health(&HordeSupervisor.get_supervisor_status/0),
        coordinator: check_component_health(&ClusterCoordinator.perform_health_check/0)
      },
      uptime: System.system_time(:second) - state.startup_time
    }

    {:reply, status, state}
  end

  @impl GenServer
  def handle_call({:connect_node, target_node}, _from, state) do
    case Node.connect(target_node) do
      true ->
        # Node connected, it will be handled by the nodeup message
        {:reply, :ok, state}

      false ->
        {:reply, {:error, :connection_failed}, state}

      :ignored ->
        {:reply, {:error, :local_node_not_started}, state}
    end
  end

  @impl GenServer
  def handle_call({:disconnect_node, target_node}, _from, state) do
    Node.disconnect(target_node)
    # The nodedown message will handle cleanup
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:register_event_handler, callback}, _from, state) do
    updated_handlers = [callback | state.event_handlers]
    {:reply, :ok, %{state | event_handlers: updated_handlers}}
  end

  @impl GenServer
  def handle_call(:reform_cluster, _from, state) do
    Logger.warning("Reforming cluster - disconnecting all nodes")

    # Disconnect from all nodes
    Enum.each(state.connected_nodes, &Node.disconnect/1)

    # Re-initialize cluster after a delay
    Process.send_after(self(), :initialize_cluster, 2000)

    {:reply, :ok, %{state | connected_nodes: []}}
  end

  @impl GenServer
  def handle_call(:get_cluster_health, _from, state) do
    health_data = collect_cluster_health_data(state)
    {:reply, {:ok, health_data}, state}
  end

  @impl GenServer
  def handle_call({:get_node_health, target_node}, _from, state) do
    case Map.get(state.node_health_data, target_node) do
      nil ->
        {:reply, {:error, :node_not_found}, state}
      health_data ->
        {:reply, {:ok, health_data}, state}
    end
  end

  @impl GenServer
  def handle_call(:perform_health_check, _from, state) do
    new_state = perform_cluster_health_check(state)
    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_info(:initialize_cluster, state) do
    Logger.info("Initializing Arbor cluster formation")

    # The actual node discovery is handled by libcluster
    # We just need to set up our Horde components for any existing connections
    connected = Node.list()

    if connected != [] do
      Logger.info("Found #{length(connected)} connected nodes: #{inspect(connected)}")

      # Join Horde clusters for each connected node
      Enum.each(connected, &add_node_to_horde_clusters/1)
    else
      Logger.info("No other nodes found, starting as single-node cluster")
    end

    # Start periodic health checks
    health_timer = schedule_health_check()
    
    new_state = %{state | 
      connected_nodes: connected, 
      health_check_timer: health_timer
    }
    
    # Perform initial health check
    updated_state = perform_cluster_health_check(new_state)
    
    {:noreply, updated_state}
  end

  @impl GenServer
  def handle_info({:nodeup, node, _node_type}, state) do
    Logger.info("Node joined cluster: #{node}")

    # Add to connected nodes if not already present
    if node not in state.connected_nodes do
      # Add node to all Horde clusters
      add_node_to_horde_clusters(node)

      # Notify event handlers
      Enum.each(state.event_handlers, fn handler ->
        spawn(fn -> handler.(:nodeup, node) end)
      end)

      # Update state
      updated_nodes = [node | state.connected_nodes] |> Enum.uniq()
      {:noreply, %{state | connected_nodes: updated_nodes}}
    else
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:nodedown, node, _node_type}, state) do
    Logger.warning("Node left cluster: #{node}")

    # Remove from connected nodes
    if node in state.connected_nodes do
      # Remove node from all Horde clusters
      remove_node_from_horde_clusters(node)

      # Notify event handlers
      Enum.each(state.event_handlers, fn handler ->
        spawn(fn -> handler.(:nodedown, node) end)
      end)

      # Update state
      updated_nodes = List.delete(state.connected_nodes, node)
      
      # Remove node from health data
      updated_health_data = Map.delete(state.node_health_data, node)
      
      {:noreply, %{state | connected_nodes: updated_nodes, node_health_data: updated_health_data}}
    else
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(:health_check, state) do
    # Perform health check and schedule the next one
    updated_state = perform_cluster_health_check(state)
    health_timer = schedule_health_check()
    
    final_state = %{updated_state | health_check_timer: health_timer}
    {:noreply, final_state}
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.debug("ClusterManager received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private functions

  defp add_node_to_horde_clusters(node) do
    Logger.info("Adding #{node} to Horde clusters")

    try do
      # Join registry cluster
      HordeRegistry.join_registry(node)

      # Join supervisor cluster
      HordeSupervisor.join_supervisor(node)

      # Join coordinator cluster
      HordeCoordinator.join_coordination(node)

      Logger.info("Successfully added #{node} to all Horde clusters")
    rescue
      error ->
        Logger.error("Failed to add #{node} to Horde clusters: #{inspect(error)}")
    end
  end

  defp remove_node_from_horde_clusters(node) do
    Logger.info("Removing #{node} from Horde clusters")

    try do
      # Leave registry cluster
      HordeRegistry.leave_registry(node)

      # Leave supervisor cluster
      HordeSupervisor.leave_supervisor(node)

      # Leave coordinator cluster
      HordeCoordinator.leave_coordination(node)

      Logger.info("Successfully removed #{node} from all Horde clusters")
    rescue
      error ->
        Logger.error("Failed to remove #{node} from Horde clusters: #{inspect(error)}")
    end
  end

  defp check_component_health(health_fn) do
    try do
      case health_fn.() do
        {:ok, _} -> :up
        _ -> :down
      end
    rescue
      _ -> :down
    end
  end

  defp get_topology_key() do
    # Use application environment or default
    case Application.get_env(:arbor_core, :env, :prod) do
      :dev -> :arbor_dev
      :test -> :arbor_test
      :prod -> :arbor_prod
      _ -> :arbor
    end
  end

  # Health monitoring functions

  defp schedule_health_check() do
    # Schedule health check every 30 seconds
    health_interval = Application.get_env(:arbor_core, :health_check_interval, 30_000)
    Process.send_after(self(), :health_check, health_interval)
  end

  defp perform_cluster_health_check(state) do
    timestamp = System.system_time(:millisecond)
    Logger.debug("Performing cluster health check")

    # Collect health data for all nodes (current + connected)
    all_nodes = [node() | state.connected_nodes] |> Enum.uniq()
    
    new_health_data = 
      all_nodes
      |> Enum.map(fn node_name -> 
        {node_name, collect_node_health(node_name)}
      end)
      |> Map.new()

    %{state | 
      node_health_data: new_health_data, 
      last_health_check: timestamp
    }
  end

  defp collect_cluster_health_data(state) do
    %{
      timestamp: System.system_time(:millisecond),
      last_check: state.last_health_check,
      nodes: state.node_health_data,
      cluster_summary: %{
        total_nodes: length([node() | state.connected_nodes]),
        healthy_nodes: count_healthy_nodes(state.node_health_data),
        topology: state.topology,
        uptime: System.system_time(:second) - state.startup_time
      }
    }
  end

  defp collect_node_health(node_name) do
    timestamp = System.system_time(:millisecond)
    
    base_health = %{
      node: node_name,
      timestamp: timestamp,
      connected: node_name == node() or node_name in Node.list(),
      last_seen: timestamp
    }

    # If it's the current node, collect detailed health
    if node_name == node() do
      detailed_health = %{
        components: %{
          registry: check_component_health(&HordeRegistry.get_registry_status/0),
          supervisor: check_component_health(&HordeSupervisor.get_supervisor_status/0),
          coordinator: check_component_health(&ClusterCoordinator.perform_health_check/0)
        },
        resources: %{
          memory: :erlang.memory(),
          process_count: :erlang.system_info(:process_count),
          port_count: :erlang.system_info(:port_count),
          load_average: get_load_average(),
          atom_count: :erlang.system_info(:atom_count)
        }
      }
      
      Map.merge(base_health, detailed_health)
    else
      # For remote nodes, try to ping and get basic status
      ping_result = case Node.ping(node_name) do
        :pong -> :reachable
        :pang -> :unreachable
      end
      
      Map.put(base_health, :ping_status, ping_result)
    end
  end

  defp count_healthy_nodes(health_data) do
    health_data
    |> Enum.count(fn {_node, data} -> 
      data.connected and not Map.has_key?(data, :ping_status) or data[:ping_status] == :reachable
    end)
  end

  defp get_load_average() do
    try do
      # Check if :cpu_sup module is available (part of :os_mon application)
      case Application.ensure_all_started(:os_mon) do
        {:ok, _} ->
          case :cpu_sup.avg1() do
            {:ok, load} -> load / 256  # Convert to standard load average format
            _ -> :unavailable
          end
        _ -> 
          :unavailable
      end
    rescue
      _ -> :unavailable
    end
  end
end
