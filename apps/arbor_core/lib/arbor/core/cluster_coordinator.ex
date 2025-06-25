defmodule Arbor.Core.ClusterCoordinator do
  @moduledoc """
  Cluster coordination for distributed agent orchestration.

  This module manages cluster-wide coordination including node lifecycle,
  agent distribution, load balancing, and state synchronization. It provides
  a unified interface for distributed coordination that can use either mock
  implementations for testing or Horde-based production implementations.

  ## Responsibilities

  - **Node Lifecycle Management**: Handle node join/leave/failure events
  - **Agent Distribution**: Optimize agent placement across cluster nodes
  - **Load Balancing**: Monitor and rebalance cluster load automatically
  - **State Synchronization**: Maintain consistent cluster state across nodes
  - **Health Monitoring**: Track cluster and node health metrics
  - **Failure Recovery**: Coordinate recovery from node and network failures

  ## Usage

      # Monitor cluster events
      ClusterCoordinator.set_event_handler(:node_join, &handle_node_join/1)
      ClusterCoordinator.set_event_handler(:node_failure, &handle_node_failure/1)

      # Get cluster status
      {:ok, cluster_info} = ClusterCoordinator.get_cluster_info()

      # Request agent redistribution
      {:ok, plan} = ClusterCoordinator.suggest_redistribution()

      # Monitor cluster health
      {:ok, health} = ClusterCoordinator.get_cluster_health()

  ## Implementation Strategy

  - For testing: Uses local coordination mock for single-node testing
  - For production: Uses Horde-based distributed coordination

  The implementation is selected at compile time based on environment.
  """

  @behaviour Arbor.Contracts.Cluster.Coordinator

  alias Arbor.Types

  @type node_info :: %{
          required(:node) => node(),
          required(:capacity) => non_neg_integer(),
          required(:capabilities) => [atom()],
          optional(:resources) => map(),
          optional(:role) => :coordinator | :worker
        }

  @type cluster_info :: %{
          nodes: [map()],
          total_capacity: non_neg_integer(),
          active_nodes: non_neg_integer(),
          total_agents: non_neg_integer()
        }

  @type redistribution_plan :: %{
          agents_to_migrate: [Types.agent_id()],
          target_nodes: [node()],
          reason: atom(),
          created_at: integer()
        }

  @type health_status :: %{
          nodes: [map()],
          overall_status: :healthy | :warning | :degraded | :critical,
          critical_alerts: non_neg_integer()
        }

  # Node lifecycle management

  @doc """
  Handle a node joining the cluster.

  Registers the node in the cluster and triggers any necessary
  agent redistribution based on the new node's capabilities.

  ## Parameters

  - `node_info` - Information about the joining node including capacity and capabilities

  ## Returns

  - `:ok` - Node join handled successfully
  - `{:error, reason}` - Failed to handle node join
  """
  @spec handle_node_join(node_info()) :: :ok | {:error, term()}
  @impl true
  def handle_node_join(node_info) do
    coordinator_impl = get_coordinator_impl()
    state = get_coordinator_state()

    coordinator_impl.handle_node_join(node_info, state)
  end

  @doc """
  Handle a node leaving the cluster gracefully.

  Removes the node from the cluster and redistributes any agents
  that were running on the departing node.

  ## Parameters

  - `node` - The node that is leaving
  - `reason` - Reason for leaving (:shutdown, :maintenance, etc.)

  ## Returns

  - `:ok` - Node leave handled successfully
  - `{:error, reason}` - Failed to handle node leave
  """
  @spec handle_node_leave(node(), atom()) :: :ok | {:error, term()}
  @impl true
  def handle_node_leave(node, reason) do
    coordinator_impl = get_coordinator_impl()
    state = get_coordinator_state()

    coordinator_impl.handle_node_leave(node, reason, state)
  end

  @doc """
  Handle a node failure event.

  Marks the node as failed and creates redistribution plans for
  any agents that were running on the failed node.

  ## Parameters

  - `node` - The node that failed
  - `reason` - Reason for failure (:network_timeout, :crash, etc.)

  ## Returns

  - `:ok` - Node failure handled successfully
  - `{:error, reason}` - Failed to handle node failure
  """
  @spec handle_node_failure(node(), atom()) :: :ok | {:error, term()}
  @impl true
  def handle_node_failure(node, reason) do
    coordinator_impl = get_coordinator_impl()
    state = get_coordinator_state()

    coordinator_impl.handle_node_failure(node, reason, state)
  end

  @doc """
  Get comprehensive cluster information.

  Returns current state of all nodes in the cluster including
  capacity, load, and agent distribution.

  ## Returns

  - `{:ok, cluster_info}` - Current cluster state
  - `{:error, reason}` - Failed to retrieve cluster info
  """
  @spec get_cluster_info() :: {:ok, cluster_info()} | {:error, term()}
  def get_cluster_info do
    coordinator_impl = get_coordinator_impl()
    state = get_coordinator_state()

    coordinator_impl.get_cluster_info(state)
  end

  # Agent distribution and load balancing

  @doc """
  Register an agent on a specific node.

  Updates cluster state to track agent placement and resource usage.

  ## Parameters

  - `agent_info` - Agent information including ID, type, and resource requirements

  ## Returns

  - `:ok` - Agent registered successfully
  - `{:error, reason}` - Registration failed
  """
  @spec register_agent_on_node(map()) :: :ok | {:error, term()}
  def register_agent_on_node(agent_info) do
    coordinator_impl = get_coordinator_impl()
    state = get_coordinator_state()

    coordinator_impl.register_agent_on_node(agent_info, state)
  end

  @doc """
  Calculate optimal distribution for a list of agents.

  Determines the best placement for agents across cluster nodes
  based on node capabilities, capacity, and current load.

  ## Parameters

  - `agents` - List of agents to distribute

  ## Returns

  - `{:ok, distribution_plan}` - Optimal agent placement plan
  - `{:error, reason}` - Failed to calculate distribution
  """
  @spec calculate_distribution([map()]) :: {:ok, map()} | {:error, term()}
  def calculate_distribution(agents) do
    coordinator_impl = get_coordinator_impl()
    state = get_coordinator_state()

    coordinator_impl.calculate_distribution(agents, state)
  end

  @doc """
  Suggest redistribution of agents for load balancing.

  Analyzes current cluster load and suggests agent migrations
  to achieve better load distribution.

  ## Returns

  - `{:ok, redistribution_plan}` - Suggested agent migrations
  - `{:error, reason}` - Failed to generate redistribution plan
  """
  @spec suggest_redistribution() :: {:ok, redistribution_plan()} | {:error, term()}
  def suggest_redistribution do
    coordinator_impl = get_coordinator_impl()
    state = get_coordinator_state()

    coordinator_impl.suggest_redistribution(state)
  end

  @doc """
  Update the capacity of a specific node.

  Updates node capacity and triggers redistribution if necessary.

  ## Parameters

  - `node` - Node to update
  - `new_capacity` - New capacity value
  - `reason` - Reason for capacity change

  ## Returns

  - `:ok` - Capacity updated successfully
  - `{:error, reason}` - Failed to update capacity
  """
  @spec update_node_capacity(node(), non_neg_integer(), atom()) :: :ok | {:error, term()}
  def update_node_capacity(node, new_capacity, reason) do
    coordinator_impl = get_coordinator_impl()
    state = get_coordinator_state()

    capacity_update = %{
      node: node,
      new_capacity: new_capacity,
      reason: reason
    }

    coordinator_impl.update_node_capacity(capacity_update, state)
  end

  # Cluster state synchronization

  @doc """
  Synchronize cluster state with updates from other coordinators.

  Processes state updates from other coordinator nodes to maintain
  consistency across the cluster.

  ## Parameters

  - `state_update` - State update containing changes to synchronize

  ## Returns

  - `:ok` - State synchronized successfully
  - `{:error, reason}` - Failed to synchronize state
  """
  @spec synchronize_cluster_state(map()) :: :ok | {:error, term()}
  def synchronize_cluster_state(state_update) do
    coordinator_impl = get_coordinator_impl()
    state = get_coordinator_state()

    coordinator_impl.synchronize_cluster_state(state_update, state)
  end

  @doc """
  Get cluster synchronization status.

  Returns information about cluster state synchronization including
  last sync timestamp and any sync conflicts.

  ## Returns

  - `{:ok, sync_status}` - Current synchronization status
  - `{:error, reason}` - Failed to get sync status
  """
  @spec get_sync_status() :: {:ok, map()} | {:error, term()}
  def get_sync_status do
    coordinator_impl = get_coordinator_impl()
    state = get_coordinator_state()

    coordinator_impl.get_sync_status(state)
  end

  @doc """
  Handle split-brain scenarios.

  Processes network partition events and determines which partition
  should remain active based on quorum rules.

  ## Parameters

  - `split_brain_event` - Information about the network partition

  ## Returns

  - `:ok` - Split-brain handled successfully
  - `{:error, reason}` - Failed to handle split-brain
  """
  @spec handle_split_brain(map()) :: :ok | {:error, term()}
  @impl true
  def handle_split_brain(split_brain_event) do
    coordinator_impl = get_coordinator_impl()
    state = get_coordinator_state()

    coordinator_impl.handle_split_brain(split_brain_event, state)
  end

  # Health monitoring and optimization

  @doc """
  Update health metrics for a specific node.

  Records health metrics like memory usage, CPU usage, and other
  performance indicators for cluster monitoring.

  ## Parameters

  - `node` - Node to update health for
  - `metric` - Type of health metric (:memory_usage, :cpu_usage, etc.)
  - `value` - Metric value

  ## Returns

  - `:ok` - Health metric updated successfully
  - `{:error, reason}` - Failed to update health metric
  """
  @spec update_node_health(node(), atom(), any()) :: :ok | {:error, term()}
  def update_node_health(node, metric, value) do
    coordinator_impl = get_coordinator_impl()
    state = get_coordinator_state()

    health_update = %{
      node: node,
      metric: metric,
      value: value,
      timestamp: System.system_time(:millisecond)
    }

    coordinator_impl.update_node_health(health_update, state)
  end

  @doc """
  Get comprehensive cluster health status.

  Returns health information for all nodes including alerts,
  resource usage, and overall cluster health.

  ## Returns

  - `{:ok, health_status}` - Current cluster health
  - `{:error, reason}` - Failed to get health status
  """
  @spec get_cluster_health() :: {:ok, health_status()} | {:error, term()}
  def get_cluster_health do
    coordinator_impl = get_coordinator_impl()
    state = get_coordinator_state()

    coordinator_impl.get_cluster_health(state)
  end

  @doc """
  Analyze cluster load and suggest optimizations.

  Examines current load distribution and provides recommendations
  for improving cluster performance and resource utilization.

  ## Returns

  - `{:ok, optimization_plan}` - Load analysis and optimization suggestions
  - `{:error, reason}` - Failed to analyze cluster load
  """
  @spec analyze_cluster_load() :: {:ok, map()} | {:error, term()}
  def analyze_cluster_load do
    coordinator_impl = get_coordinator_impl()
    state = get_coordinator_state()

    coordinator_impl.analyze_cluster_load(state)
  end

  @doc """
  Update the current load for a specific node.

  Records current resource utilization for load balancing decisions.

  ## Parameters

  - `node` - Node to update load for
  - `load` - Current load percentage (0-100)

  ## Returns

  - `:ok` - Load updated successfully
  - `{:error, reason}` - Failed to update load
  """
  @spec update_node_load(node(), non_neg_integer()) :: :ok | {:error, term()}
  def update_node_load(node, load) do
    coordinator_impl = get_coordinator_impl()
    state = get_coordinator_state()

    coordinator_impl.update_node_load(node, load, state)
  end

  # Event processing and coordination

  @doc """
  Process a coordination event.

  Handles coordination events like node joins, agent assignments,
  capacity changes, and other cluster coordination events.

  ## Parameters

  - `event` - Coordination event to process

  ## Returns

  - `:ok` - Event processed successfully
  - `{:error, reason}` - Failed to process event
  """
  @spec process_coordination_event(tuple()) :: :ok | {:error, term()}
  def process_coordination_event(event) do
    coordinator_impl = get_coordinator_impl()
    state = get_coordinator_state()

    coordinator_impl.process_coordination_event(event, state)
  end

  @doc """
  Get coordination event log.

  Returns log of processed coordination events for debugging
  and monitoring cluster coordination activities.

  ## Returns

  - `{:ok, event_log}` - List of processed coordination events
  - `{:error, reason}` - Failed to get event log
  """
  @spec get_coordination_log() :: {:ok, map()} | {:error, term()}
  def get_coordination_log do
    coordinator_impl = get_coordinator_impl()
    state = get_coordinator_state()

    coordinator_impl.get_coordination_log(state)
  end

  # Convenience functions for common coordination patterns

  @doc """
  Handle complete node failure recovery.

  Combines node failure handling with agent redistribution and
  health monitoring updates for complete failure recovery.

  ## Parameters

  - `failed_node` - Node that failed
  - `reason` - Failure reason

  ## Returns

  - `{:ok, recovery_plan}` - Complete recovery plan
  - `{:error, reason}` - Failed to create recovery plan
  """
  @spec handle_node_failure_recovery(node(), atom()) :: {:ok, map()} | {:error, term()}
  @impl true
  def handle_node_failure_recovery(failed_node, reason) do
    with :ok <- handle_node_failure(failed_node, reason),
         {:ok, redistribution_plan} <- get_redistribution_plan_for_node(failed_node) do
      recovery_plan = %{
        failed_node: failed_node,
        failure_reason: reason,
        redistribution_plan: redistribution_plan,
        recovery_timestamp: System.system_time(:millisecond)
      }

      {:ok, recovery_plan}
    end
  end

  @doc """
  Get redistribution plan for a specific node.

  Retrieves the redistribution plan created for agents on a specific node,
  typically used after node failures or for planned maintenance.

  ## Parameters

  - `node` - Node to get redistribution plan for

  ## Returns

  - `{:ok, redistribution_plan}` - Plan for redistributing agents from the node
  - `{:error, reason}` - Failed to get redistribution plan
  """
  @spec get_redistribution_plan_for_node(node()) ::
          {:ok, redistribution_plan()} | {:error, term()}
  def get_redistribution_plan_for_node(node) do
    coordinator_impl = get_coordinator_impl()
    state = get_coordinator_state()

    coordinator_impl.get_redistribution_plan(node, state)
  end

  @doc """
  Perform cluster health check.

  Comprehensive health check that examines all aspects of cluster
  health including node status, resource usage, and alert conditions.

  ## Returns

  - `{:ok, health_report}` - Detailed cluster health report
  - `{:error, reason}` - Failed to perform health check
  """
  @spec perform_health_check() :: {:ok, map()} | {:error, term()}
  def perform_health_check do
    with {:ok, cluster_info} <- get_cluster_info(),
         {:ok, health_status} <- get_cluster_health(),
         {:ok, sync_status} <- get_sync_status() do
      health_report = %{
        cluster_info: cluster_info,
        health_status: health_status,
        sync_status: sync_status,
        check_timestamp: System.system_time(:millisecond)
      }

      {:ok, health_report}
    end
  end

  # Implementation selection

  defp get_coordinator_impl do
    # Use configuration to select implementation
    # MOCK: For testing, use local coordinator
    # For production, use Horde-based coordinator
    case Application.get_env(:arbor_core, :coordinator_impl, :auto) do
      :mock ->
        Arbor.Test.Mocks.LocalCoordinator

      :horde ->
        Arbor.Core.HordeCoordinator

      module when is_atom(module) ->
        # Direct module injection for Mox testing
        module

      :auto ->
        if Application.get_env(:arbor_core, :env) == :test do
          Arbor.Test.Mocks.LocalCoordinator
        else
          Arbor.Core.HordeCoordinator
        end
    end
  end

  defp get_coordinator_state do
    # For mock implementation, create a fresh state
    # For Horde, this would be the actual coordinator state
    impl = get_coordinator_impl()

    case impl do
      Arbor.Test.Mocks.LocalCoordinator ->
        # Create a mock state for each call (stateless for unit tests)
        {:ok, state} = impl.init([])
        state

      _ ->
        # For real implementation, this would reference the GenServer
        nil
    end
  end
end
