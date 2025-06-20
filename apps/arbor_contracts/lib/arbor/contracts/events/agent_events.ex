defmodule Arbor.Contracts.Events.AgentEvents do
  @moduledoc """
  Event definitions for agent lifecycle and operations.

  These events capture all significant state changes and activities
  related to agents in the Arbor system. They form the foundation
  of our event sourcing approach for agent state management.

  ## Event Categories

  - **Lifecycle Events**: Agent start, stop, crash, restart
  - **State Events**: State changes, capability grants/revocations
  - **Communication Events**: Messages sent/received
  - **Task Events**: Task assignments, completions, failures

  @version "1.0.0"
  """

  use TypedStruct

  alias Arbor.Contracts.Core.{Capability, Message}
  alias Arbor.Types

  # Agent Started Event
  defmodule AgentStarted do
    @moduledoc """
    Emitted when an agent successfully starts.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:agent_id, Types.agent_id())
      field(:agent_type, Types.agent_type())
      field(:parent_id, Types.agent_id(), enforce: false)
      field(:session_id, Types.session_id())
      field(:node, atom())
      field(:capabilities, [String.t()], default: [])
      field(:metadata, map(), default: %{})
      field(:timestamp, DateTime.t())
    end

    @spec new(keyword()) :: {:ok, t()} | {:error, term()}
    def new(attrs) do
      event = %__MODULE__{
        agent_id: Keyword.fetch!(attrs, :agent_id),
        agent_type: Keyword.fetch!(attrs, :agent_type),
        parent_id: attrs[:parent_id],
        session_id: Keyword.fetch!(attrs, :session_id),
        node: attrs[:node] || node(),
        capabilities: attrs[:capabilities] || [],
        metadata: attrs[:metadata] || %{},
        timestamp: attrs[:timestamp] || DateTime.utc_now()
      }

      {:ok, event}
    end
  end

  # Agent Stopped Event
  defmodule AgentStopped do
    @moduledoc """
    Emitted when an agent stops (normally or abnormally).
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:agent_id, Types.agent_id())
      field(:reason, atom() | term())
      field(:exit_status, atom(), default: :normal)
      field(:run_duration, non_neg_integer())
      field(:tasks_completed, non_neg_integer(), default: 0)
      field(:final_state, map(), enforce: false)
      field(:timestamp, DateTime.t())
    end

    @spec new(keyword()) :: {:ok, t()} | {:error, term()}
    def new(attrs) do
      event = %__MODULE__{
        agent_id: Keyword.fetch!(attrs, :agent_id),
        reason: Keyword.fetch!(attrs, :reason),
        exit_status: attrs[:exit_status] || :normal,
        run_duration: Keyword.fetch!(attrs, :run_duration),
        tasks_completed: attrs[:tasks_completed] || 0,
        final_state: attrs[:final_state],
        timestamp: attrs[:timestamp] || DateTime.utc_now()
      }

      {:ok, event}
    end
  end

  # Agent Crashed Event
  defmodule AgentCrashed do
    @moduledoc """
    Emitted when an agent crashes unexpectedly.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:agent_id, Types.agent_id())
      field(:error, term())
      field(:stacktrace, list(), enforce: false)
      field(:last_message, any(), enforce: false)
      field(:restart_count, non_neg_integer(), default: 0)
      field(:timestamp, DateTime.t())
    end
  end

  # Agent Restarted Event
  defmodule AgentRestarted do
    @moduledoc """
    Emitted when an agent is restarted by the supervisor.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:agent_id, Types.agent_id())
      field(:restart_reason, atom() | term())
      field(:restart_count, non_neg_integer())
      field(:previous_run_duration, non_neg_integer())
      field(:state_recovered, boolean(), default: false)
      field(:timestamp, DateTime.t())
    end
  end

  # Message Sent Event
  defmodule MessageSent do
    @moduledoc """
    Emitted when an agent sends a message.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:message_id, String.t())
      field(:from_agent, Types.agent_id())
      field(:to_agent, Types.agent_id())
      field(:message_type, atom())
      field(:payload_size, non_neg_integer())
      field(:timestamp, DateTime.t())
    end

    @spec from_message(Message.t()) :: {:ok, t()}
    def from_message(%Message{} = msg) do
      {:ok, from_id} = Types.agent_uri_to_id(msg.from)
      {:ok, to_id} = Types.agent_uri_to_id(msg.to)

      event = %__MODULE__{
        message_id: msg.id,
        from_agent: from_id,
        to_agent: to_id,
        message_type: infer_message_type(msg.payload),
        payload_size: calculate_payload_size(msg.payload),
        timestamp: msg.timestamp
      }

      {:ok, event}
    end

    defp infer_message_type(payload) when is_map(payload) do
      Map.get(payload, :type, :unknown)
    end

    defp infer_message_type(_), do: :unknown

    defp calculate_payload_size(payload) do
      payload
      |> :erlang.term_to_binary()
      |> byte_size()
    end
  end

  # Message Received Event
  defmodule MessageReceived do
    @moduledoc """
    Emitted when an agent receives a message.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:message_id, String.t())
      field(:agent_id, Types.agent_id())
      field(:from_agent, Types.agent_id())
      field(:processing_time, non_neg_integer(), enforce: false)
      field(:timestamp, DateTime.t())
    end
  end

  # Capability Granted Event
  defmodule CapabilityGranted do
    @moduledoc """
    Emitted when an agent receives a new capability.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:agent_id, Types.agent_id())
      field(:capability_id, Types.capability_id())
      field(:resource_uri, Types.resource_uri())
      field(:granted_by, String.t())
      field(:expires_at, DateTime.t(), enforce: false)
      field(:timestamp, DateTime.t())
    end

    @spec from_capability(Capability.t(), String.t()) :: {:ok, t()}
    def from_capability(%Capability{} = cap, granted_by) do
      event = %__MODULE__{
        agent_id: cap.principal_id,
        capability_id: cap.id,
        resource_uri: cap.resource_uri,
        granted_by: granted_by,
        expires_at: cap.expires_at,
        timestamp: cap.granted_at
      }

      {:ok, event}
    end
  end

  # Capability Revoked Event
  defmodule CapabilityRevoked do
    @moduledoc """
    Emitted when a capability is revoked from an agent.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:agent_id, Types.agent_id())
      field(:capability_id, Types.capability_id())
      field(:revoked_by, String.t())
      field(:reason, atom() | String.t())
      field(:timestamp, DateTime.t())
    end
  end

  # Task Assigned Event
  defmodule TaskAssigned do
    @moduledoc """
    Emitted when a task is assigned to an agent.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:agent_id, Types.agent_id())
      field(:task_id, String.t())
      field(:task_type, atom())
      field(:assigned_by, Types.agent_id())
      field(:priority, atom(), default: :normal)
      field(:timeout, pos_integer())
      field(:timestamp, DateTime.t())
    end
  end

  # Task Completed Event
  defmodule TaskCompleted do
    @moduledoc """
    Emitted when an agent completes a task.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:agent_id, Types.agent_id())
      field(:task_id, String.t())
      field(:execution_time, non_neg_integer())
      field(:result_size, non_neg_integer())
      field(:success, boolean(), default: true)
      field(:timestamp, DateTime.t())
    end
  end

  # Task Failed Event
  defmodule TaskFailed do
    @moduledoc """
    Emitted when an agent fails to complete a task.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:agent_id, Types.agent_id())
      field(:task_id, String.t())
      field(:error, term())
      field(:execution_time, non_neg_integer())
      field(:retry_count, non_neg_integer(), default: 0)
      field(:timestamp, DateTime.t())
    end
  end

  # Agent State Changed Event
  defmodule AgentStateChanged do
    @moduledoc """
    Emitted when an agent's internal state changes significantly.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:agent_id, Types.agent_id())
      field(:state_type, atom())
      field(:old_value, any())
      field(:new_value, any())
      field(:change_reason, String.t())
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
      field(:state_size, non_neg_integer())
      field(:migration_time, non_neg_integer())
      field(:timestamp, DateTime.t())
    end
  end
end
