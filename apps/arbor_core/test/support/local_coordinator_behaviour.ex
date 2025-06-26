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

  # Node lifecycle management
  @callback handle_node_join(node_info(), state()) :: :ok | {:error, atom()}
  @callback handle_node_leave(atom(), atom(), state()) :: :ok | {:error, atom()}
  @callback handle_node_failure(atom(), atom(), state()) :: :ok | {:error, atom()}

  # Agent management
  @callback register_agent(agent_info(), state()) :: :ok | {:error, atom()}
  @callback register_agent_on_node(agent_info(), atom()) :: :ok | {:error, atom()}
  @callback calculate_distribution([agent_info()], state()) ::
              {:ok, distribution_plan()} | {:error, atom()}
  @callback suggest_redistribution(state()) :: {:ok, redistribution_plan()} | {:error, atom()}
  @callback get_redistribution_plan(atom(), state()) ::
              {:ok, redistribution_plan()} | {:error, atom()}

  # Cluster state synchronization
  @callback get_cluster_info(state()) :: {:ok, cluster_info()} | {:error, atom()}
  @callback get_sync_status(state()) :: {:ok, sync_status()} | {:error, atom()}
  @callback synchronize_cluster_state(state_update(), state()) :: :ok | {:error, atom()}
  @callback handle_split_brain(split_brain_event(), state()) :: :ok | {:error, atom()}

  # Load balancing and health monitoring
  @callback get_cluster_health(state()) :: {:ok, health_status()} | {:error, atom()}
  @callback update_node_health(health_update(), state()) :: :ok | {:error, atom()}
  @callback update_node_load(atom(), number(), state()) :: :ok | {:error, atom()}
  @callback update_node_capacity(capacity_update(), state()) :: :ok | {:error, atom()}
  @callback analyze_cluster_load(state()) :: {:ok, optimization_plan()} | {:error, atom()}

  # Event processing
  @callback process_coordination_event(coordination_event(), state()) :: :ok | {:error, atom()}
  @callback get_coordination_log(state()) :: {:ok, event_log()} | {:error, atom()}
end
