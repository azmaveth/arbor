defmodule Arbor.Contracts.Telemetry.ReconciliationEvent do
  @moduledoc """
  Defines contracts for agent reconciler telemetry events.

  These events provide insight into the self-healing and reconciliation
  processes that maintain the health of the distributed agent system.
  """

  @behaviour Arbor.Contracts.Telemetry.Event

  alias Arbor.Contracts.Telemetry.Event

  @typedoc "A reconciliation lifecycle event."
  @type t ::
          %__MODULE__.Start{}
          | %__MODULE__.Complete{}
          | %__MODULE__.LookupPerformance{}
          | %__MODULE__.AgentDiscovery{}
          | %__MODULE__.AgentRestartSuccess{}
          | %__MODULE__.AgentRestartFailed{}
          | %__MODULE__.AgentRestartError{}
          | %__MODULE__.AgentCleanupSuccess{}
          | %__MODULE__.AgentCleanupFailed{}
          | %__MODULE__.AgentCleanupError{}

  # --- Event Structs ---

  defmodule Start do
    @moduledoc "Emitted when a reconciliation cycle begins."
    @type t :: %__MODULE__{
            event_name: list(atom()),
            measurements: %{:start_time => integer()},
            metadata: %{:node => atom(), :reconciler => module()},
            timestamp: integer()
          }

    defstruct event_name: [:arbor, :reconciliation, :start],
              measurements: %{},
              metadata: %{},
              timestamp: nil
  end

  defmodule Complete do
    @moduledoc "Emitted when a reconciliation cycle completes."
    @type t :: %__MODULE__{
            event_name: list(atom()),
            measurements: %{
              :missing_agents_restarted => non_neg_integer(),
              :orphaned_agents_cleaned => non_neg_integer(),
              :duration_ms => non_neg_integer(),
              :total_specs => non_neg_integer(),
              :total_running => non_neg_integer(),
              :missing_count => non_neg_integer(),
              :orphaned_count => non_neg_integer(),
              :spec_lookup_duration_ms => non_neg_integer(),
              :supervisor_lookup_duration_ms => non_neg_integer(),
              :restart_errors_count => non_neg_integer(),
              :cleanup_errors_count => non_neg_integer(),
              :reconciliation_efficiency => float(),
              :system_health_score => float()
            },
            metadata: %{
              :node => atom(),
              :reconciler => module(),
              :restart_errors => list(map()),
              :cleanup_errors => list(map())
            },
            timestamp: integer()
          }

    defstruct event_name: [:arbor, :reconciliation, :complete],
              measurements: %{},
              metadata: %{},
              timestamp: nil
  end

  defmodule LookupPerformance do
    @moduledoc "Emitted to report performance of registry and supervisor lookups."
    @type t :: %__MODULE__{
            event_name: list(atom()),
            measurements: %{
              :spec_lookup_duration_ms => non_neg_integer(),
              :supervisor_lookup_duration_ms => non_neg_integer(),
              :specs_found => non_neg_integer(),
              :running_processes => non_neg_integer()
            },
            metadata: %{:node => atom()},
            timestamp: integer()
          }

    defstruct event_name: [:arbor, :reconciliation, :lookup_performance],
              measurements: %{},
              metadata: %{},
              timestamp: nil
  end

  defmodule AgentDiscovery do
    @moduledoc "Emitted to report the discovery of missing and orphaned agents."
    @type t :: %__MODULE__{
            event_name: list(atom()),
            measurements: %{
              :total_specs => non_neg_integer(),
              :total_running => non_neg_integer(),
              :missing_count => non_neg_integer(),
              :orphaned_count => non_neg_integer()
            },
            metadata: %{
              :node => atom(),
              :missing_agents => list(binary()),
              :orphaned_agents => list(binary())
            },
            timestamp: integer()
          }

    defstruct event_name: [:arbor, :reconciliation, :agent_discovery],
              measurements: %{},
              metadata: %{},
              timestamp: nil
  end

  defmodule AgentRestartSuccess do
    @moduledoc "Emitted when a missing agent is successfully restarted."
    @type t :: %__MODULE__{
            event_name: list(atom()),
            measurements: %{:duration_ms => non_neg_integer()},
            metadata: %{
              :agent_id => binary(),
              :restart_strategy => :permanent | :transient | :temporary,
              :node => atom()
            },
            timestamp: integer()
          }

    defstruct event_name: [:arbor, :reconciliation, :agent_restart_success],
              measurements: %{},
              metadata: %{},
              timestamp: nil
  end

  defmodule AgentRestartFailed do
    @moduledoc "Emitted when a missing agent fails to restart."
    @type t :: %__MODULE__{
            event_name: list(atom()),
            measurements: %{:duration_ms => non_neg_integer()},
            metadata: %{
              :agent_id => binary(),
              :restart_strategy => :permanent | :transient | :temporary,
              :node => atom()
            },
            timestamp: integer()
          }

    defstruct event_name: [:arbor, :reconciliation, :agent_restart_failed],
              measurements: %{},
              metadata: %{},
              timestamp: nil
  end

  defmodule AgentRestartError do
    @moduledoc "Emitted on an error condition during agent restart (e.g., spec not found)."
    @type t :: %__MODULE__{
            event_name: list(atom()),
            measurements: %{},
            metadata: %{
              :agent_id => binary(),
              :error => atom(),
              :node => atom()
            },
            timestamp: integer()
          }

    defstruct event_name: [:arbor, :reconciliation, :agent_restart_error],
              measurements: %{},
              metadata: %{},
              timestamp: nil
  end

  defmodule AgentCleanupSuccess do
    @moduledoc "Emitted when an orphaned agent is successfully cleaned up."
    @type t :: %__MODULE__{
            event_name: list(atom()),
            measurements: %{:duration_ms => non_neg_integer()},
            metadata: %{
              :agent_id => binary() | :undefined,
              :pid => String.t(),
              :node => atom()
            },
            timestamp: integer()
          }

    defstruct event_name: [:arbor, :reconciliation, :agent_cleanup_success],
              measurements: %{},
              metadata: %{},
              timestamp: nil
  end

  defmodule AgentCleanupFailed do
    @moduledoc "Emitted when an orphaned agent fails to be cleaned up."
    @type t :: %__MODULE__{
            event_name: list(atom()),
            measurements: %{:duration_ms => non_neg_integer()},
            metadata: %{
              :agent_id => binary() | :undefined,
              :pid => String.t(),
              :node => atom()
            },
            timestamp: integer()
          }

    defstruct event_name: [:arbor, :reconciliation, :agent_cleanup_failed],
              measurements: %{},
              metadata: %{},
              timestamp: nil
  end

  defmodule AgentCleanupError do
    @moduledoc "Emitted on an error condition during agent cleanup (e.g., process not found)."
    @type t :: %__MODULE__{
            event_name: list(atom()),
            measurements: %{},
            metadata: %{
              :agent_id => binary(),
              :error => atom(),
              :node => atom()
            },
            timestamp: integer()
          }

    defstruct event_name: [:arbor, :reconciliation, :agent_cleanup_error],
              measurements: %{},
              metadata: %{},
              timestamp: nil
  end

  @doc """
  Validates a given reconciliation event against its contract.
  """
  @impl Event
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(event) do
    # A real implementation could have a clause for each event struct with detailed checks.
    with :ok <- Event.validate(event),
         true <- is_list(event.event_name) and length(event.event_name) == 3,
         [:arbor, :reconciliation, _] = event.event_name,
         true <- Map.has_key?(event.metadata, :node) do
      :ok
    else
      _ -> {:error, :invalid_reconciliation_event}
    end
  end
end
