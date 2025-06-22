defmodule Arbor.Contracts.Events.ReconciliationEvents do
  @moduledoc """
  Event definitions for the AgentReconciler process.

  These events provide detailed observability into the self-healing
  and reconciliation cycles of the agent system. They are critical for
  understanding system stability and recovery behavior.

  ## Event Categories

  - **Cycle Events**: Start, completion, and failure of a reconciliation run.
  - **Operational Metrics**: Performance of lookups and agent discovery.
  - **Action Results**: Outcomes of agent restarts and cleanups.

  @version "1.0.0"
  """

  use TypedStruct

  alias Arbor.Types

  # Reconciliation Started Event
  defmodule ReconciliationStarted do
    @moduledoc """
    Emitted at the beginning of an agent reconciliation cycle.
    """
    use TypedStruct
    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:reconciler, module())
      field(:node, atom())
      field(:timestamp, DateTime.t())
    end
  end

  # Reconciliation Completed Event
  defmodule ReconciliationCompleted do
    @moduledoc """
    Emitted on successful completion of a reconciliation cycle.
    """
    use TypedStruct
    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:reconciler, module())
      field(:node, atom())
      field(:duration_ms, non_neg_integer())
      field(:total_specs, non_neg_integer())
      field(:total_running, non_neg_integer())
      field(:missing_agents_restarted, non_neg_integer())
      field(:orphaned_agents_cleaned, non_neg_integer())
      field(:restart_errors_count, non_neg_integer())
      field(:cleanup_errors_count, non_neg_integer())
      field(:reconciliation_efficiency, float())
      field(:system_health_score, float())
      field(:timestamp, DateTime.t())
    end
  end

  # Reconciliation Failed Event
  defmodule ReconciliationFailed do
    @moduledoc """
    Emitted when a reconciliation cycle fails or encounters errors.
    """
    use TypedStruct
    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:reconciler, module())
      field(:node, atom())
      field(:duration_ms, non_neg_integer())
      field(:restart_errors, list(map()))
      field(:cleanup_errors, list(map()))
      field(:reconciliation_efficiency, float())
      field(:system_health_score, float())
      field(:timestamp, DateTime.t())
    end
  end

  # Lookup Performance Event
  defmodule LookupPerformance do
    @moduledoc """
    Emitted to report performance of registry and supervisor lookups.
    """
    use TypedStruct
    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:reconciler, module())
      field(:node, atom())
      field(:spec_lookup_duration_ms, non_neg_integer())
      field(:supervisor_lookup_duration_ms, non_neg_integer())
      field(:specs_found, non_neg_integer())
      field(:running_processes, non_neg_integer())
      field(:timestamp, DateTime.t())
    end
  end

  # Agent Discovery Event
  defmodule AgentDiscovery do
    @moduledoc """
    Emitted with details about missing and orphaned agents found.
    """
    use TypedStruct
    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:reconciler, module())
      field(:node, atom())
      field(:total_specs, non_neg_integer())
      field(:total_running, non_neg_integer())
      field(:missing_agents, list(Types.agent_id()))
      field(:orphaned_agents, list(Types.agent_id()))
      field(:timestamp, DateTime.t())
    end
  end

  # Agent Restart Result Event
  defmodule AgentRestartResult do
    @moduledoc """
    Emitted for each attempt to restart a missing agent.
    """
    use TypedStruct
    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:reconciler, module())
      field(:agent_id, Types.agent_id())
      field(:node, atom())
      field(:outcome, atom())
      field(:duration_ms, non_neg_integer())
      field(:restart_strategy, atom())
      field(:error_reason, String.t(), enforce: false)
      field(:timestamp, DateTime.t())
    end
  end

  # Agent Cleanup Result Event
  defmodule AgentCleanupResult do
    @moduledoc """
    Emitted for each attempt to clean up an orphaned agent.
    """
    use TypedStruct
    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:reconciler, module())
      field(:agent_id, Types.agent_id() | :undefined)
      field(:pid, String.t())
      field(:node, atom())
      field(:outcome, atom())
      field(:duration_ms, non_neg_integer())
      field(:error_reason, String.t(), enforce: false)
      field(:timestamp, DateTime.t())
    end
  end
end
