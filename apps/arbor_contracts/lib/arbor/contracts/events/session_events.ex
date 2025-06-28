defmodule Arbor.Contracts.Events.SessionEvents do
  @moduledoc """
  Event definitions for session lifecycle and management.

  These events track all significant activities related to sessions,
  which are the primary coordination contexts for multi-agent interactions.

  ## Event Categories

  - **Lifecycle Events**: Session creation, termination
  - **Agent Events**: Agents joining/leaving sessions
  - **State Events**: Context updates, capability changes
  - **Activity Events**: Command execution, coordination activities

  @version "1.0.0"
  """

  use TypedStruct

  alias Arbor.Types

  # Session Created Event
  defmodule SessionCreated do
    @moduledoc """
    Emitted when a new session is created.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:session_id, Types.session_id())
      field(:user_id, String.t())
      field(:purpose, String.t())
      field(:max_agents, pos_integer())
      field(:timeout, pos_integer(), enforce: false)
      field(:initial_capabilities, [String.t()], default: [])
      field(:metadata, map(), default: %{})
      field(:timestamp, DateTime.t())
    end

    @spec new(keyword()) :: {:ok, t()}
    def new(attrs) do
      event = %__MODULE__{
        session_id: Keyword.fetch!(attrs, :session_id),
        user_id: Keyword.fetch!(attrs, :user_id),
        purpose: Keyword.fetch!(attrs, :purpose),
        max_agents: attrs[:max_agents] || 10,
        timeout: attrs[:timeout],
        initial_capabilities: attrs[:initial_capabilities] || [],
        metadata: attrs[:metadata] || %{},
        timestamp: attrs[:timestamp] || DateTime.utc_now()
      }

      {:ok, event}
    end
  end

  # Session Terminated Event
  defmodule SessionTerminated do
    @moduledoc """
    Emitted when a session is terminated.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:session_id, Types.session_id())
      field(:reason, atom() | String.t())
      field(:duration, non_neg_integer())
      field(:agents_count, non_neg_integer())
      field(:tasks_completed, non_neg_integer())
      field(:cleanup_status, atom(), default: :success)
      field(:timestamp, DateTime.t())
    end
  end

  # Agent Joined Session Event
  defmodule AgentJoinedSession do
    @moduledoc """
    Emitted when an agent joins a session.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:session_id, Types.session_id())
      field(:agent_id, Types.agent_id())
      field(:agent_type, Types.agent_type())
      field(:capabilities, [String.t()], default: [])
      field(:agent_count, non_neg_integer())
      field(:timestamp, DateTime.t())
    end
  end

  # Agent Left Session Event
  defmodule AgentLeftSession do
    @moduledoc """
    Emitted when an agent leaves a session.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:session_id, Types.session_id())
      field(:agent_id, Types.agent_id())
      field(:reason, atom() | String.t())
      field(:duration_in_session, non_neg_integer())
      field(:tasks_completed, non_neg_integer(), default: 0)
      field(:remaining_agents, non_neg_integer())
      field(:timestamp, DateTime.t())
    end
  end

  # Session Status Changed Event
  defmodule SessionStatusChanged do
    @moduledoc """
    Emitted when session status changes.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:session_id, Types.session_id())
      field(:old_status, atom())
      field(:new_status, atom())
      field(:change_reason, String.t())
      field(:timestamp, DateTime.t())
    end
  end

  # Session Context Updated Event
  defmodule SessionContextUpdated do
    @moduledoc """
    Emitted when shared session context is updated.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:session_id, Types.session_id())
      field(:key, atom() | String.t())
      field(:old_value, any())
      field(:new_value, any())
      field(:updated_by, Types.agent_id() | String.t())
      field(:timestamp, DateTime.t())
    end
  end

  # Session Capability Added Event
  defmodule SessionCapabilityAdded do
    @moduledoc """
    Emitted when a capability is added to a session.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:session_id, Types.session_id())
      field(:capability_id, Types.capability_id())
      field(:resource_uri, Types.resource_uri())
      field(:granted_to_all_agents, boolean(), default: true)
      field(:timestamp, DateTime.t())
    end
  end

  # Command Executed Event
  defmodule CommandExecuted do
    @moduledoc """
    Emitted when a command is executed in a session.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:session_id, Types.session_id())
      field(:command_id, String.t())
      field(:command_type, atom())
      field(:initiated_by, String.t())
      field(:assigned_agents, [Types.agent_id()], default: [])
      field(:execution_time, non_neg_integer(), enforce: false)
      field(:status, atom())
      field(:timestamp, DateTime.t())
    end
  end

  # Session Expired Event
  defmodule SessionExpired do
    @moduledoc """
    Emitted when a session expires due to timeout.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:session_id, Types.session_id())
      field(:expiration_reason, atom(), default: :timeout)
      field(:active_agents, non_neg_integer())
      field(:pending_tasks, non_neg_integer())
      field(:auto_cleanup, boolean(), default: true)
      field(:timestamp, DateTime.t())
    end
  end

  # Session Suspended Event
  defmodule SessionSuspended do
    @moduledoc """
    Emitted when a session is temporarily suspended.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:session_id, Types.session_id())
      field(:suspension_reason, String.t())
      field(:suspended_by, String.t())
      field(:expected_resume_at, DateTime.t(), enforce: false)
      field(:state_preserved, boolean(), default: true)
      field(:timestamp, DateTime.t())
    end
  end

  # Session Resumed Event
  defmodule SessionResumed do
    @moduledoc """
    Emitted when a suspended session is resumed.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:session_id, Types.session_id())
      field(:resumed_by, String.t())
      field(:suspension_duration, non_neg_integer())
      field(:agents_restored, non_neg_integer())
      field(:state_recovery_status, atom(), default: :success)
      field(:timestamp, DateTime.t())
    end
  end

  # Session Error Event
  defmodule SessionError do
    @moduledoc """
    Emitted when an error occurs in session management.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:session_id, Types.session_id())
      field(:error_type, atom())
      field(:error_message, String.t())
      field(:affected_agents, [Types.agent_id()], default: [])
      field(:recovery_action, atom(), enforce: false)
      field(:timestamp, DateTime.t())
    end
  end

  # Session Health Check Event
  defmodule SessionHealthChecked do
    @moduledoc """
    Emitted when a session health check is performed.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:session_id, Types.session_id())
      field(:health_status, atom())
      field(:active_agents, non_neg_integer())
      field(:healthy_agents, non_neg_integer())
      field(:memory_usage, non_neg_integer())
      field(:warnings, [String.t()], default: [])
      field(:timestamp, DateTime.t())
    end
  end
end
