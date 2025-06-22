defmodule Arbor.Contracts.Events.AgentEvents do
  @moduledoc """
  Event definitions for agent lifecycle and operations for observability.

  These events capture all significant state changes and activities
  related to an agent's lifecycle in the Arbor system. They are designed
  to be broadcast for monitoring, alerting, and debugging purposes.

  ## Event Categories

  - **Lifecycle Events**: Agent start, stop, failure, and restart.
  - **Topology Events**: Agent migration between nodes.

  @version "1.1.0"
  """

  use TypedStruct

  alias Arbor.Types

  # Agent Started Event
  defmodule AgentStarted do
    @moduledoc """
    Emitted when an agent successfully starts. This is a key lifecycle event.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:agent_id, Types.agent_id())
      field(:agent_type, Types.agent_type())
      field(:parent_id, Types.agent_id(), enforce: false)
      field(:session_id, Types.session_id())
      field(:node, atom())
      field(:module, module())
      field(:capabilities, [String.t()], default: [])
      field(:metadata, map(), default: %{})
      field(:timestamp, DateTime.t())
    end
  end

  # Agent Stopped Event
  defmodule AgentStopped do
    @moduledoc """
    Emitted when an agent stops gracefully.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:agent_id, Types.agent_id())
      field(:node, atom())
      field(:reason, atom() | term())
      field(:exit_status, atom(), default: :normal)
      field(:run_duration_ms, non_neg_integer())
      field(:tasks_completed, non_neg_integer(), default: 0)
      field(:timestamp, DateTime.t())
    end
  end

  # Agent Failed Event
  defmodule AgentFailed do
    @moduledoc """
    Emitted when an agent process crashes or fails to start.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:agent_id, Types.agent_id())
      field(:node, atom())
      field(:module, module())
      field(:reason, String.t())
      field(:error_category, atom())
      field(:restart_strategy, atom())
      field(:timestamp, DateTime.t())
    end
  end

  # Agent Restarted Event
  defmodule AgentRestarted do
    @moduledoc """
    Emitted when an agent is restarted by the reconciler or a supervisor.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:agent_id, Types.agent_id())
      field(:node, atom())
      field(:pid, pid())
      field(:module, module())
      field(:restart_strategy, atom())
      field(:restart_duration_ms, non_neg_integer())
      field(:memory_usage_bytes, non_neg_integer())
      field(:state_recovered, boolean(), default: false)
      field(:timestamp, DateTime.t())
    end
  end

  # Agent Migrated Event
  defmodule AgentMigrated do
    @moduledoc """
    Emitted when an agent migrates from one node to another.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:agent_id, Types.agent_id())
      field(:from_node, atom())
      field(:to_node, atom())
      field(:migration_reason, atom())
      field(:state_size_bytes, non_neg_integer())
      field(:migration_time_ms, non_neg_integer())
      field(:timestamp, DateTime.t())
    end
  end
end
