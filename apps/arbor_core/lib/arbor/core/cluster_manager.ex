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

  alias Arbor.Core.{HordeRegistry, HordeSupervisor, HordeCoordinator}

  @type topology :: atom()
  @type node_event :: :nodeup | :nodedown

  defstruct [
    :topology,
    :connected_nodes,
    :node_monitors,
    :startup_time,
    :event_handlers
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
      event_handlers: []
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
        coordinator: check_component_health(fn -> {:ok, :up} end)
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

    {:noreply, %{state | connected_nodes: connected}}
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
      {:noreply, %{state | connected_nodes: updated_nodes}}
    else
      {:noreply, state}
    end
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
end
