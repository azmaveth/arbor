defmodule Arbor.Contracts.Events.HordeEvents do
  @moduledoc """
  Event definitions for Horde infrastructure activities.

  These events provide observability into the underlying distributed
  process management layer provided by Horde. They are essential for
  debugging cluster-wide process registration and supervision issues.

  ## Event Categories

  - **Registry Events**: Process registration, unregistration, and lookups.
  - **Supervisor Events**: Child process start/stop and distribution changes.
  - **Cluster Events**: Horde-level cluster membership changes.

  @version "1.0.0"
  """

  use TypedStruct

  # Horde Registry Operation Event
  defmodule HordeRegistryOperation do
    @moduledoc """
    Emitted for operations on a Horde.Registry.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:operation, atom())
      field(:registry_name, atom())
      field(:node, atom())
      field(:key, any())
      field(:value, any(), enforce: false)
      field(:result, atom())
      field(:duration_ms, non_neg_integer())
      field(:timestamp, DateTime.t())
    end
  end

  # Horde Supervisor Event
  defmodule HordeSupervisorEvent do
    @moduledoc """
    Emitted for events from a Horde.DynamicSupervisor.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:supervisor_name, atom())
      field(:node, atom())
      field(:event_type, atom())
      field(:child_id, any(), enforce: false)
      field(:pid, pid(), enforce: false)
      field(:distribution, map(), enforce: false)
      field(:timestamp, DateTime.t())
    end
  end

  # Horde Cluster Event
  defmodule HordeClusterEvent do
    @moduledoc """
    Emitted for Horde-level cluster membership changes.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:event_type, atom())
      field(:node, atom())
      field(:subject_node, atom())
      field(:members, list(atom()))
      field(:details, String.t(), enforce: false)
      field(:timestamp, DateTime.t())
    end
  end
end
