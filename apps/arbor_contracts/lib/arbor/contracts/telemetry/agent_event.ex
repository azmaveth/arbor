defmodule Arbor.Contracts.Telemetry.AgentEvent do
  @moduledoc """
  Defines contracts for agent-related telemetry events.

  These events track the lifecycle of agents within the system, including
  creation, restarts, and cleanup operations. Adhering to these contracts
  ensures that agent observability data is consistent and reliable.
  """

  @behaviour Arbor.Contracts.Telemetry.Event

  alias Arbor.Contracts.Telemetry.Event

  @typedoc "An agent lifecycle event."
  @type t ::
          %__MODULE__.Start{}
          | %__MODULE__.Stop{}
          | %__MODULE__.Restart{}
          | %__MODULE__.RestartAttempt{}
          | %__MODULE__.Restarted{}
          | %__MODULE__.RestartFailed{}
          | %__MODULE__.CleanupAttempt{}
          | %__MODULE__.CleanedUp{}
          | %__MODULE__.CleanupFailed{}

  # Common metadata for many agent events
  @typedoc "Common metadata for agent events."
  @type agent_metadata :: %{
          :agent_id => binary(),
          :node => atom(),
          optional(:module) => module(),
          optional(:restart_strategy) => :permanent | :transient | :temporary,
          optional(:pid) => pid() | String.t(),
          optional(:reason) => any(),
          optional(:created_at) => integer()
        }

  # --- Event Structs ---

  defmodule Start do
    @moduledoc "Emitted when an agent process is started."
    @type t :: %__MODULE__{
            event_name: list(atom()),
            measurements: %{optional(:memory_usage) => non_neg_integer()},
            metadata: Arbor.Contracts.Telemetry.AgentEvent.agent_metadata(),
            timestamp: integer()
          }

    defstruct event_name: [:arbor, :agent, :start],
              measurements: %{},
              metadata: %{},
              timestamp: nil
  end

  defmodule Stop do
    @moduledoc "Emitted when an agent process is stopped."
    @type t :: %__MODULE__{
            event_name: list(atom()),
            measurements: %{},
            metadata: Arbor.Contracts.Telemetry.AgentEvent.agent_metadata(),
            timestamp: integer()
          }

    defstruct event_name: [:arbor, :agent, :stop],
              measurements: %{},
              metadata: %{},
              timestamp: nil
  end

  defmodule Restart do
    @moduledoc "Generic event for an agent being restarted."
    @type t :: %__MODULE__{
            event_name: list(atom()),
            measurements: %{optional(:duration_ms) => non_neg_integer()},
            metadata: Arbor.Contracts.Telemetry.AgentEvent.agent_metadata(),
            timestamp: integer()
          }

    defstruct event_name: [:arbor, :agent, :restart],
              measurements: %{},
              metadata: %{},
              timestamp: nil
  end

  defmodule RestartAttempt do
    @moduledoc "Emitted when a restart is attempted for a missing agent."
    @type t :: %__MODULE__{
            event_name: list(atom()),
            measurements: %{:start_time => integer()},
            metadata: Arbor.Contracts.Telemetry.AgentEvent.agent_metadata(),
            timestamp: integer()
          }

    defstruct event_name: [:arbor, :agent, :restart_attempt],
              measurements: %{},
              metadata: %{},
              timestamp: nil
  end

  defmodule Restarted do
    @moduledoc "Emitted when an agent is successfully restarted."
    @type t :: %__MODULE__{
            event_name: list(atom()),
            measurements: %{
              :restart_duration_ms => non_neg_integer(),
              :memory_usage => non_neg_integer()
            },
            metadata: Arbor.Contracts.Telemetry.AgentEvent.agent_metadata(),
            timestamp: integer()
          }

    defstruct event_name: [:arbor, :agent, :restarted],
              measurements: %{},
              metadata: %{},
              timestamp: nil
  end

  defmodule RestartFailed do
    @moduledoc "Emitted when an agent restart fails."
    @type t :: %__MODULE__{
            event_name: list(atom()),
            measurements: %{
              :restart_duration_ms => non_neg_integer(),
              :error_category => atom()
            },
            metadata: Arbor.Contracts.Telemetry.AgentEvent.agent_metadata(),
            timestamp: integer()
          }

    defstruct event_name: [:arbor, :agent, :restart_failed],
              measurements: %{},
              metadata: %{},
              timestamp: nil
  end

  defmodule CleanupAttempt do
    @moduledoc "Emitted when cleanup of an orphaned agent is attempted."
    @type t :: %__MODULE__{
            event_name: list(atom()),
            measurements: %{},
            metadata: %{
              :agent_id => binary() | :undefined,
              :node => atom(),
              :pid => String.t()
            },
            timestamp: integer()
          }

    defstruct event_name: [:arbor, :agent, :cleanup_attempt],
              measurements: %{},
              metadata: %{},
              timestamp: nil
  end

  defmodule CleanedUp do
    @moduledoc "Emitted when an orphaned agent is successfully cleaned up."
    @type t :: %__MODULE__{
            event_name: list(atom()),
            measurements: %{},
            metadata: %{
              :agent_id => binary() | :undefined,
              :node => atom(),
              :pid => String.t()
            },
            timestamp: integer()
          }

    defstruct event_name: [:arbor, :agent, :cleaned_up],
              measurements: %{},
              metadata: %{},
              timestamp: nil
  end

  defmodule CleanupFailed do
    @moduledoc "Emitted when orphaned agent cleanup fails."
    @type t :: %__MODULE__{
            event_name: list(atom()),
            measurements: %{},
            metadata: %{
              :agent_id => binary() | :undefined,
              :node => atom(),
              :pid => String.t(),
              :reason => any()
            },
            timestamp: integer()
          }

    defstruct event_name: [:arbor, :agent, :cleanup_failed],
              measurements: %{},
              metadata: %{},
              timestamp: nil
  end

  @doc """
  Validates a given agent event against its contract.
  """
  @impl Event
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__.Start{} = event) do
    with :ok <- validate_base_fields(event),
         true <- Map.has_key?(event.metadata, :agent_id),
         true <- Map.has_key?(event.metadata, :node) do
      :ok
    else
      _ -> {:error, :invalid_start_event}
    end
  end

  def validate(%__MODULE__.Stop{} = event) do
    with :ok <- validate_base_fields(event),
         true <- Map.has_key?(event.metadata, :agent_id),
         true <- Map.has_key?(event.metadata, :node) do
      :ok
    else
      _ -> {:error, :invalid_stop_event}
    end
  end

  def validate(%__MODULE__.Restart{} = event) do
    with :ok <- validate_base_fields(event),
         true <- Map.has_key?(event.metadata, :agent_id),
         true <- Map.has_key?(event.metadata, :node) do
      :ok
    else
      _ -> {:error, :invalid_restart_event}
    end
  end

  def validate(%__MODULE__.RestartAttempt{} = event) do
    with :ok <- validate_base_fields(event),
         true <- Map.has_key?(event.measurements, :start_time),
         true <- Map.has_key?(event.metadata, :agent_id),
         true <- Map.has_key?(event.metadata, :node) do
      :ok
    else
      _ -> {:error, :invalid_restart_attempt_event}
    end
  end

  def validate(%__MODULE__.Restarted{} = event) do
    with :ok <- validate_base_fields(event),
         true <- Map.has_key?(event.measurements, :restart_duration_ms),
         true <- Map.has_key?(event.metadata, :agent_id),
         true <- Map.has_key?(event.metadata, :node) do
      :ok
    else
      _ -> {:error, :invalid_restarted_event}
    end
  end

  def validate(%__MODULE__.RestartFailed{} = event) do
    with :ok <- validate_base_fields(event),
         true <- Map.has_key?(event.measurements, :restart_duration_ms),
         true <- Map.has_key?(event.metadata, :agent_id),
         true <- Map.has_key?(event.metadata, :reason),
         true <- Map.has_key?(event.metadata, :node) do
      :ok
    else
      _ -> {:error, :invalid_restart_failed_event}
    end
  end

  def validate(%__MODULE__.CleanupAttempt{} = event) do
    with :ok <- validate_base_fields(event),
         true <- Map.has_key?(event.metadata, :agent_id),
         true <- Map.has_key?(event.metadata, :pid),
         true <- Map.has_key?(event.metadata, :node) do
      :ok
    else
      _ -> {:error, :invalid_cleanup_attempt_event}
    end
  end

  def validate(%__MODULE__.CleanedUp{} = event) do
    with :ok <- validate_base_fields(event),
         true <- Map.has_key?(event.metadata, :agent_id),
         true <- Map.has_key?(event.metadata, :pid),
         true <- Map.has_key?(event.metadata, :node) do
      :ok
    else
      _ -> {:error, :invalid_cleaned_up_event}
    end
  end

  def validate(%__MODULE__.CleanupFailed{} = event) do
    with :ok <- validate_base_fields(event),
         true <- Map.has_key?(event.metadata, :agent_id),
         true <- Map.has_key?(event.metadata, :pid),
         true <- Map.has_key?(event.metadata, :reason),
         true <- Map.has_key?(event.metadata, :node) do
      :ok
    else
      _ -> {:error, :invalid_cleanup_failed_event}
    end
  end

  def validate(_other) do
    {:error, :unknown_agent_event_type}
  end

  defp validate_base_fields(%{
         event_name: name,
         measurements: m,
         metadata: meta,
         timestamp: ts
       })
       when is_list(name) and is_map(m) and is_map(meta) and is_integer(ts) do
    :ok
  end

  defp validate_base_fields(_other) do
    {:error, :invalid_base_event_structure}
  end
end
