defmodule Arbor.Contracts.Cluster.Coordinator do
  @moduledoc """
  Behaviour for distributed cluster coordination.

  The Coordinator is responsible for:
  - Managing cluster membership and topology
  - Coordinating distributed events and state changes
  - Load balancing and work distribution
  - Handling split-brain scenarios

  ## Implementation Notes

  Implementations should handle both single-node (for testing) and
  multi-node scenarios. The coordinator works closely with the
  Registry and Supervisor to maintain cluster-wide consistency.
  """

  @type state :: term()
  @type node_info :: %{
          node: node(),
          status: :up | :down | :unknown,
          last_seen: integer(),
          metadata: map()
        }
  @type cluster_info :: %{
          nodes: [node_info()],
          leader: node() | nil,
          topology: map()
        }
  @type distribution_strategy :: :round_robin | :least_loaded | :random | :sticky
  @type event_type :: :node_up | :node_down | :topology_change | :rebalance | atom()
  @type event_handler :: (event_type(), term() -> any())

  @doc """
  Initialize the coordinator state.

  Called when the coordinator process starts. Should set up any
  necessary state for tracking cluster membership and events.

  ## Returns

  - `{:ok, state}` - Initialization successful
  - `{:error, reason}` - Initialization failed
  """
  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc """
  Handle a node joining the cluster.

  Called when a new node connects to the cluster. The coordinator
  should update its topology information and trigger any necessary
  rebalancing.

  ## Parameters

  - `node` - The node that joined
  - `state` - Current coordinator state

  ## Returns

  - `{:ok, new_state}` - Node join handled
  - `{:error, reason}` - Failed to handle node join
  """
  @callback handle_node_join(node(), state()) :: {:ok, state()} | {:error, term()}

  @doc """
  Handle a node leaving the cluster.

  Called when a node disconnects from the cluster. The coordinator
  should update topology and handle any necessary failover.

  ## Parameters

  - `node` - The node that left
  - `state` - Current coordinator state

  ## Returns

  - `{:ok, new_state}` - Node leave handled
  - `{:error, reason}` - Failed to handle node leave
  """
  @callback handle_node_leave(node(), state()) :: {:ok, state()} | {:error, term()}

  @doc """
  Get current cluster information.

  Returns comprehensive information about the cluster's current state,
  including all nodes, their status, and topology information.

  ## Parameters

  - `state` - Current coordinator state

  ## Returns

  - `{:ok, cluster_info}` - Current cluster information
  """
  @callback get_cluster_info(state()) :: {:ok, cluster_info()}

  @doc """
  Calculate distribution of work across nodes.

  Given a workload description and distribution strategy, calculate
  how work should be distributed across available nodes.

  ## Parameters

  - `workload` - Description of work to distribute
  - `strategy` - Distribution strategy to use
  - `state` - Current coordinator state

  ## Returns

  - `{:ok, distribution}` - Map of node => work assignments
  - `{:error, reason}` - Failed to calculate distribution
  """
  @callback calculate_distribution(
              workload :: term(),
              strategy :: distribution_strategy(),
              state()
            ) ::
              {:ok, %{node() => term()}} | {:error, term()}

  @doc """
  Trigger a cluster rebalance.

  Forces the coordinator to recalculate work distribution and
  migrate processes as needed to balance the cluster.

  ## Parameters

  - `state` - Current coordinator state

  ## Returns

  - `{:ok, new_state}` - Rebalance initiated
  - `{:error, reason}` - Failed to initiate rebalance
  """
  @callback trigger_rebalance(state()) :: {:ok, state()} | {:error, term()}

  @doc """
  Set an event handler for cluster events.

  Registers a callback function to be invoked when specific
  cluster events occur.

  ## Parameters

  - `event_type` - Type of event to handle
  - `handler` - Callback function
  - `state` - Current coordinator state

  ## Returns

  - `{:ok, new_state}` - Handler registered
  """
  @callback set_event_handler(event_type(), handler :: event_handler(), state()) :: {:ok, state()}

  @doc """
  Handle a split-brain scenario.

  Called when the cluster detects it may be partitioned. The coordinator
  should implement logic to handle this gracefully.

  ## Parameters

  - `partition_info` - Information about the detected partition
  - `state` - Current coordinator state

  ## Returns

  - `{:ok, new_state}` - Split-brain handled
  - `{:error, reason}` - Failed to handle split-brain
  """
  @callback handle_split_brain(partition_info :: map(), state()) ::
              {:ok, state()} | {:error, term()}

  @doc """
  Broadcast an event to all nodes.

  Sends an event to all connected nodes in the cluster.

  ## Parameters

  - `event` - Event to broadcast
  - `state` - Current coordinator state

  ## Returns

  - `:ok` - Event broadcast successfully
  - `{:error, reason}` - Broadcast failed
  """
  @callback broadcast_event(event :: term(), state()) :: :ok | {:error, term()}

  @doc """
  Get load information for a specific node.

  Returns current load metrics for the specified node.

  ## Parameters

  - `node` - Node to query
  - `state` - Current coordinator state

  ## Returns

  - `{:ok, load_info}` - Load information retrieved
  - `{:error, reason}` - Failed to get load info
  """
  @callback get_node_load(node(), state()) :: {:ok, map()} | {:error, term()}

  @doc """
  Perform health check on the coordinator.

  Returns health metrics and status information.

  ## Parameters

  - `state` - Current coordinator state

  ## Returns

  - `{:ok, health_info}` - Health check results
  """
  @callback health_check(state()) :: {:ok, map()}

  @doc """
  Terminate the coordinator.

  Clean up any resources before the coordinator shuts down.

  ## Parameters

  - `reason` - Shutdown reason
  - `state` - Current coordinator state

  ## Returns

  - `:ok`
  """
  @callback terminate(reason :: term(), state()) :: :ok
end
