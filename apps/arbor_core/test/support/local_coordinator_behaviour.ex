defmodule Arbor.Test.Support.LocalCoordinatorBehaviour do
  @moduledoc """
  Behavior for LocalCoordinator interface to enable Mox-based testing.

  This behavior defines the interface used by LocalCoordinator so we can
  create Mox mocks that replace the LocalCoordinator implementation
  in tests.
  """

  @type state :: any()
  @type node_info :: map()
  @type agent_info :: map()
  @type cluster_info :: map()
  @type distribution_plan :: map()
  @type redistribution_plan :: map()
  @type sync_status :: map()
  @type health_status :: map()
  @type optimization_plan :: map()
  @type event_log :: map()
  @type coordination_event :: tuple()
  @type health_update :: map()
  @type capacity_update :: map()
  @type state_update :: map()
  @type split_brain_event :: map()
  @type conflict_scenario :: map()

  # Initialization
  @callback init(any()) :: {:ok, state()}

  # Node lifecycle management
  @callback handle_node_join(node_info(), state()) :: :ok
  @callback handle_node_leave(node(), any(), state()) :: :ok
  @callback handle_node_failure(node(), any(), state()) :: :ok
  @callback get_cluster_info(state()) :: {:ok, cluster_info()}
  @callback get_redistribution_plan(node(), state()) ::
              {:ok, redistribution_plan()} | {:error, atom()}

  # Agent management
  @callback register_agent_on_node(agent_info(), state()) :: :ok
  @callback calculate_distribution([map()], state()) :: {:ok, distribution_plan()}
  @callback update_node_capacity(capacity_update(), state()) :: :ok
  @callback suggest_redistribution(state()) :: {:ok, redistribution_plan()}

  # Cluster state synchronization
  @callback synchronize_cluster_state(state_update(), state()) :: :ok
  @callback get_sync_status(state()) :: {:ok, sync_status()}
  @callback handle_split_brain(split_brain_event(), state()) :: :ok
  @callback get_partition_status(state()) :: {:ok, map() | nil}
  @callback resolve_state_conflicts(conflict_scenario(), state()) :: {:ok, map()}

  # Load balancing and health monitoring
  @callback update_node_load(node(), number(), state()) :: :ok
  @callback analyze_cluster_load(state()) :: {:ok, optimization_plan()}
  @callback update_node_health(health_update(), state()) :: :ok
  @callback get_cluster_health(state()) :: {:ok, health_status()}

  # Event processing
  @callback process_coordination_event(coordination_event(), state()) :: :ok | {:error, any()}
  @callback get_coordination_log(state()) :: {:ok, event_log()}
end
