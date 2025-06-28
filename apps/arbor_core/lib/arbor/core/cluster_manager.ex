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

  @behaviour Arbor.Contracts.Cluster.Manager

  use GenServer

  alias Arbor.Core.{ClusterCoordinator, HordeCoordinator, HordeRegistry, HordeSupervisor}

  require Logger

  # :cpu_sup is an optional dependency (part of :os_mon)
  # Dialyzer warning suppressed at function level

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
  def cluster_status do
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
  def reform_cluster do
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
  def get_cluster_health do
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
  def perform_health_check do
    GenServer.call(__MODULE__, :perform_health_check)
  end

  # GenServer callbacks

  @impl true
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

  @impl true
  def handle_call(:cluster_status, _from, state) do
    # Get appropriate implementations based on config
    registry_impl = get_registry_impl()
    supervisor_impl = get_supervisor_impl()

    status = %{
      nodes: [node() | state.connected_nodes],
      connected_nodes: length(state.connected_nodes),
      topology: state.topology,
      components: %{
        registry:
          check_component_health(fn ->
            if registry_impl == HordeRegistry do
              registry_impl.get_registry_status()
            else
              # Mock registry doesn't have get_registry_status
              {:ok, %{status: :healthy, members: [node()], count: 0}}
            end
          end),
        supervisor:
          check_component_health(fn ->
            if supervisor_impl == HordeSupervisor do
              supervisor_impl.get_supervisor_status()
            else
              # Mock supervisor doesn't have get_supervisor_status
              {:ok, %{status: :healthy, members: [node()], active_agents: 0}}
            end
          end),
        coordinator:
          check_component_health(fn ->
            # Check if we're in test mode
            if Application.get_env(:arbor_core, :registry_impl, :auto) == :mock do
              # Return mock health status
              {:ok, %{status: :healthy, active_coordinators: 0}}
            else
              ClusterCoordinator.perform_health_check()
            end
          end)
      },
      uptime: System.system_time(:second) - state.startup_time
    }

    {:reply, status, state}
  end

  @impl true
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

  @impl true
  def handle_call({:disconnect_node, target_node}, _from, state) do
    Node.disconnect(target_node)
    # The nodedown message will handle cleanup
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:register_event_handler, callback}, _from, state) do
    updated_handlers = [callback | state.event_handlers]
    {:reply, :ok, %{state | event_handlers: updated_handlers}}
  end

  @impl true
  def handle_call(:reform_cluster, _from, state) do
    Logger.warning("Reforming cluster - disconnecting all nodes")

    # Disconnect from all nodes
    Enum.each(state.connected_nodes, &Node.disconnect/1)

    # Re-initialize cluster after a delay
    Process.send_after(self(), :initialize_cluster, 2000)

    {:reply, :ok, %{state | connected_nodes: []}}
  end

  @impl true
  def handle_call(:get_cluster_health, _from, state) do
    health_data = collect_cluster_health_data(state)
    {:reply, {:ok, health_data}, state}
  end

  @impl true
  def handle_call({:get_node_health, target_node}, _from, state) do
    case Map.get(state.node_health_data, target_node) do
      nil ->
        {:reply, {:error, :node_not_found}, state}

      health_data ->
        {:reply, {:ok, health_data}, state}
    end
  end

  @impl true
  def handle_call(:perform_health_check, _from, state) do
    new_state = perform_cluster_health_check(state)
    {:reply, :ok, new_state}
  end

  @impl true
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

    new_state = %{state | connected_nodes: connected, health_check_timer: health_timer}

    # Perform initial health check
    updated_state = perform_cluster_health_check(new_state)

    {:noreply, updated_state}
  end

  @impl true
  def handle_info({:nodeup, node, _node_type}, state) do
    Logger.info("Node joined cluster: #{node}")

    # Add to connected nodes if not already present
    if node in state.connected_nodes do
      {:noreply, state}
    else
      # Add node to all Horde clusters
      add_node_to_horde_clusters(node)

      # Notify event handlers
      Enum.each(state.event_handlers, fn handler ->
        spawn(fn -> handler.(:nodeup, node) end)
      end)

      # Update state
      updated_nodes = Enum.uniq([node | state.connected_nodes])
      {:noreply, %{state | connected_nodes: updated_nodes}}
    end
  end

  @impl true
  def handle_info({:nodedown, node, _node_type}, state) do
    Logger.warning("Node left cluster: #{node}")

    # Remove from connected nodes
    if node in state.connected_nodes do
      # Remove node from all Horde clusters
      remove_node_from_horde_clusters(node)

      # NOTE: Horde.DynamicSupervisor automatically handles agent migration
      # with process_redistribution: :active configuration. No manual intervention needed.
      Logger.info("Horde will automatically redistribute agents from failed node #{node}")

      # Notify event handlers about the node failure
      Enum.each(state.event_handlers, fn handler ->
        spawn(fn -> handler.(:nodedown, node) end)
      end)

      # Notify cluster coordinator about the node failure for observability
      try do
        Arbor.Core.ClusterCoordinator.handle_node_failure(node, :network_failure)
      rescue
        # Specific rescue for known coordination failures. We want to log but not crash
        # the cluster manager when the coordinator is unavailable.
        UndefinedFunctionError ->
          Logger.debug("ClusterCoordinator.handle_node_failure/2 not available")

        error in [RuntimeError, ArgumentError] ->
          Logger.warning("Failed to notify ClusterCoordinator of node failure",
            error: inspect(error),
            node: node
          )

        other_error ->
          Logger.error("Unexpected error notifying ClusterCoordinator of node failure",
            error: inspect(other_error),
            stacktrace: __STACKTRACE__,
            node: node
          )
      end

      # Update state
      updated_nodes = List.delete(state.connected_nodes, node)

      # Remove node from health data
      updated_health_data = Map.delete(state.node_health_data, node)

      {:noreply, %{state | connected_nodes: updated_nodes, node_health_data: updated_health_data}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:health_check, state) do
    # Perform health check and schedule the next one
    updated_state = perform_cluster_health_check(state)
    health_timer = schedule_health_check()

    final_state = %{updated_state | health_check_timer: health_timer}
    {:noreply, final_state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("ClusterManager received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private functions

  # Adds a node to all relevant Horde clusters (Registry, Supervisor, Coordinator).
  # This function is idempotent and safe to call multiple times. It also handles
  # cases where Horde implementations are not used (e.g., in test environments).
  @spec add_node_to_horde_clusters(node()) :: any()
  defp add_node_to_horde_clusters(node) do
    Logger.info("Adding #{node} to Horde clusters")

    # Only add to Horde clusters if we're using Horde implementations
    registry_impl = get_registry_impl()
    supervisor_impl = get_supervisor_impl()

    try do
      # Join registry cluster if using Horde
      if registry_impl == HordeRegistry and function_exported?(registry_impl, :join_registry, 1) do
        registry_impl.join_registry(node)
      end

      # Join supervisor cluster if using Horde
      if supervisor_impl == HordeSupervisor and
           function_exported?(supervisor_impl, :join_supervisor, 1) do
        supervisor_impl.join_supervisor(node)
      end

      # Join coordinator cluster
      if function_exported?(HordeCoordinator, :join_coordination, 1) do
        HordeCoordinator.join_coordination(node)
      end

      Logger.info("Successfully added #{node} to all Horde clusters")
    rescue
      # Specific rescue for cluster formation failures. These are expected during
      # network partitions or when Horde processes aren't ready yet.
      error in [UndefinedFunctionError, RuntimeError] ->
        Logger.warning("Failed to add #{node} to Horde clusters",
          error: inspect(error),
          node: node
        )

      other_error ->
        Logger.error("Unexpected error adding #{node} to Horde clusters",
          error: inspect(other_error),
          stacktrace: __STACKTRACE__,
          node: node
        )
    end
  end

  # Removes a node from all relevant Horde clusters.
  # This is typically called when a node leaves the cluster. It gracefully handles
  # cases where the node is already disconnected or Horde components are down.
  @spec remove_node_from_horde_clusters(node()) :: any()
  defp remove_node_from_horde_clusters(node) do
    Logger.info("Removing #{node} from Horde clusters")

    # Only remove from Horde clusters if we're using Horde implementations
    registry_impl = get_registry_impl()
    supervisor_impl = get_supervisor_impl()

    try do
      # Leave registry cluster if using Horde
      if registry_impl == HordeRegistry and function_exported?(registry_impl, :leave_registry, 1) do
        registry_impl.leave_registry(node)
      end

      # Leave supervisor cluster if using Horde
      if supervisor_impl == HordeSupervisor and
           function_exported?(supervisor_impl, :leave_supervisor, 1) do
        supervisor_impl.leave_supervisor(node)
      end

      # Leave coordinator cluster
      if function_exported?(HordeCoordinator, :leave_coordination, 1) do
        HordeCoordinator.leave_coordination(node)
      end

      Logger.info("Successfully removed #{node} from all Horde clusters")
    rescue
      # Specific rescue for cluster cleanup failures. These are expected when
      # the failed node is already disconnected or Horde processes are down.
      error in [UndefinedFunctionError, RuntimeError] ->
        Logger.warning("Failed to remove #{node} from Horde clusters",
          error: inspect(error),
          node: node
        )

      other_error ->
        Logger.error("Unexpected error removing #{node} from Horde clusters",
          error: inspect(other_error),
          stacktrace: __STACKTRACE__,
          node: node
        )
    end
  end

  # Executes a health check function for a component and returns its status.
  # It normalizes various success responses to `:up` and handles exceptions
  # by returning `:down`, preventing crashes in the health check process.
  @spec check_component_health((-> any())) :: :up | :down
  defp check_component_health(health_fn) do
    case health_fn.() do
      {:ok, _} -> :up
      result when is_map(result) -> :up
      _ -> :down
    end
  rescue
    # Specific rescue for health check failures. These are expected when components
    # are starting up, shutting down, or experiencing temporary issues.
    error in [UndefinedFunctionError, RuntimeError, ArgumentError] ->
      Logger.debug("Component health check failed", error: inspect(error))
      :down

    other_error ->
      Logger.warning("Unexpected error during component health check",
        error: inspect(other_error),
        function: inspect(health_fn)
      )

      :down
  end

  # Determines the libcluster topology key based on the application environment.
  # This allows for different cluster discovery strategies in development,
  # testing, and production environments.
  @spec get_topology_key() :: :arbor | :arbor_dev | :arbor_prod | :arbor_test
  defp get_topology_key do
    # Use application environment or default
    case Application.get_env(:arbor_core, :env, :prod) do
      :dev -> :arbor_dev
      :test -> :arbor_test
      :prod -> :arbor_prod
      _ -> :arbor
    end
  end

  # Determines the appropriate registry implementation module based on configuration.
  # It allows swapping between the real `HordeRegistry` and a mock implementation
  # for testing purposes.
  @spec get_registry_impl() :: Arbor.Core.HordeRegistry | Arbor.Test.Mocks.LocalClusterRegistry
  defp get_registry_impl do
    case Application.get_env(:arbor_core, :registry_impl, :auto) do
      :mock ->
        Arbor.Test.Mocks.LocalClusterRegistry

      :horde ->
        HordeRegistry

      :auto ->
        if Application.get_env(:arbor_core, :env, :prod) == :test do
          Arbor.Test.Mocks.LocalClusterRegistry
        else
          HordeRegistry
        end
    end
  end

  # Determines the appropriate supervisor implementation module based on configuration.
  # It allows swapping between the real `HordeSupervisor` and a mock implementation
  # for testing purposes, with a fallback to HordeSupervisor if the mock is not available.
  @spec get_supervisor_impl() :: module()
  defp get_supervisor_impl do
    case Application.get_env(:arbor_core, :supervisor_impl, :auto) do
      :mock ->
        # Conditionally load test mock if available
        case Code.ensure_loaded(Arbor.Test.Mocks.SupervisorMock) do
          {:module, module} ->
            module

          _ ->
            HordeSupervisor
        end

      :horde ->
        HordeSupervisor

      :auto ->
        if Application.get_env(:arbor_core, :env, :prod) == :test do
          # Conditionally load test mock if available
          case Code.ensure_loaded(Arbor.Test.Mocks.SupervisorMock) do
            {:module, module} ->
              module

            _ ->
              HordeSupervisor
          end
        else
          HordeSupervisor
        end
    end
  end

  # Health monitoring functions

  defp schedule_health_check do
    # Schedule health check every 30 seconds
    health_interval = Application.get_env(:arbor_core, :health_check_interval, 30_000)
    Process.send_after(self(), :health_check, health_interval)
  end

  defp perform_cluster_health_check(state) do
    timestamp = System.system_time(:millisecond)
    Logger.debug("Performing cluster health check")

    # Collect health data for all nodes (current + connected)
    all_nodes = Enum.uniq([node() | state.connected_nodes])

    new_health_data =
      all_nodes
      |> Enum.map(fn node_name ->
        {node_name, collect_node_health(node_name)}
      end)
      |> Map.new()

    %{state | node_health_data: new_health_data, last_health_check: timestamp}
  end

  defp collect_cluster_health_data(state) do
    %{
      timestamp: System.system_time(:millisecond),
      last_check: state.last_health_check,
      nodes: state.node_health_data,
      cluster_summary: %{
        total_nodes: 1 + length(state.connected_nodes),
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
      Map.merge(base_health, collect_detailed_health())
    else
      # For remote nodes, try RPC
      collect_remote_node_health(node_name, base_health)
    end
  end

  defp collect_detailed_health do
    # Get appropriate implementations
    registry_impl = get_registry_impl()
    supervisor_impl = get_supervisor_impl()

    %{
      components: %{
        registry: collect_registry_health(registry_impl),
        supervisor: collect_supervisor_health(supervisor_impl),
        coordinator: collect_coordinator_health()
      },
      resources: %{
        memory: :erlang.memory(),
        process_count: :erlang.system_info(:process_count),
        port_count: :erlang.system_info(:port_count),
        load_average: get_load_average(),
        atom_count: :erlang.system_info(:atom_count)
      }
    }
  end

  defp collect_remote_node_health(node_name, base_health) do
    # For remote nodes, try to ping and get basic status
    ping_result =
      case Node.ping(node_name) do
        :pong -> :reachable
        :pang -> :unreachable
      end

    Map.put(base_health, :ping_status, ping_result)
  end

  defp collect_registry_health(registry_impl) do
    check_component_health(fn ->
      if registry_impl == HordeRegistry and
           function_exported?(registry_impl, :get_registry_status, 0) do
        registry_impl.get_registry_status()
      else
        # Mock registry doesn't have get_registry_status
        {:ok, %{status: :healthy, members: [node()], count: 0}}
      end
    end)
  end

  defp collect_supervisor_health(supervisor_impl) do
    check_component_health(fn ->
      if supervisor_impl == HordeSupervisor and
           function_exported?(supervisor_impl, :get_supervisor_status, 0) do
        supervisor_impl.get_supervisor_status()
      else
        # Mock supervisor doesn't have get_supervisor_status
        {:ok, %{status: :healthy, members: [node()], active_agents: 0}}
      end
    end)
  end

  defp collect_coordinator_health do
    check_component_health(fn ->
      # Check if we're in test mode
      if Application.get_env(:arbor_core, :registry_impl, :auto) == :mock do
        # Return mock health status
        {:ok, %{status: :healthy, active_coordinators: 0}}
      else
        ClusterCoordinator.perform_health_check()
      end
    end)
  end

  defp count_healthy_nodes(health_data) do
    Enum.count(health_data, fn {_node, data} ->
      (data.connected and not Map.has_key?(data, :ping_status)) or
        data[:ping_status] == :reachable
    end)
  end

  defp get_load_average do
    # Check if :cpu_sup module is available (part of :os_mon application)
    case Application.ensure_all_started(:os_mon) do
      {:ok, _} ->
        case Code.ensure_loaded(:cpu_sup) do
          {:module, :cpu_sup} ->
            try do
              if function_exported?(:cpu_sup, :avg1, 0) do
                case :cpu_sup.avg1() do
                  # Convert to standard load average format
                  {:ok, load} -> load / 256
                  _ -> :unavailable
                end
              else
                :unavailable
              end
            rescue
              _ -> :unavailable
            end

          {:error, _} ->
            :unavailable
        end

      _ ->
        :unavailable
    end
  rescue
    # Specific rescue for OS monitoring failures. This is expected on some platforms
    # where os_mon is not available or doesn't have required permissions.
    error in [UndefinedFunctionError, RuntimeError] ->
      Logger.debug("OS monitoring not available", error: inspect(error))
      :unavailable

    other_error ->
      Logger.warning("Unexpected error getting load average",
        error: inspect(other_error)
      )

      :unavailable
  end

  # Implement required callbacks from Arbor.Contracts.Cluster.Manager

  @impl true
  def start_service(_config) do
    # ClusterManager is started as a GenServer by the application supervisor
    {:ok, self()}
  end

  @impl true
  def stop_service(_reason) do
    # Graceful shutdown is handled by the GenServer terminate callback
    :ok
  end

  @impl true
  def get_status do
    # Get current cluster status using the public API
    status = cluster_status()
    {:ok, status}
  end
end
