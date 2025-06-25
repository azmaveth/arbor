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
  {:ok, redistribution_plan()} | {:error, atom()}

  # Agent management

  # Cluster state synchronization

  # Load balancing and health monitoring

  # Event processing
end
