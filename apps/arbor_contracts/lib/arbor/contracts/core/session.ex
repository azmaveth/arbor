defmodule Arbor.Contracts.Core.Session do
  @moduledoc """
  Enhanced session structure with complete lifecycle management.

  Sessions are the primary coordination context for multi-agent interactions
  in Arbor. They provide:
  - Shared security context for all agents
  - Distributed state management
  - Resource lifecycle management
  - Audit trail for all activities

  ## Session States

  - `:initializing` - Session being created
  - `:active` - Normal operating state
  - `:suspended` - Temporarily paused
  - `:terminating` - Graceful shutdown in progress
  - `:terminated` - Session ended
  - `:error` - Session in error state

  ## State Transitions

  ```
  initializing -> active
  active -> suspended -> active
  active -> terminating -> terminated
  * -> error
  ```

  ## Usage

      {:ok, session} = Session.new(
        user_id: "user_123",
        purpose: "Analyze and refactor codebase",
        capabilities: [capability1, capability2],
        metadata: %{project_id: "proj_456"}
      )

  @version "1.0.0"
  """

  use TypedStruct

  alias Arbor.Contracts.Core.Capability
  alias Arbor.Identifiers
  alias Arbor.Types

  @derive {Jason.Encoder, except: [:capabilities]}
  typedstruct enforce: true do
    @typedoc "A session coordinating multiple agents"

    # Identity
    field(:id, Types.session_id())
    field(:user_id, String.t())
    field(:purpose, String.t())

    # State management
    field(:status, atom(), default: :initializing)
    field(:context, map(), default: %{})
    field(:capabilities, [Capability.t()], default: [])

    # Agent management
    field(:agents, map(), default: %{})
    field(:max_agents, pos_integer(), default: 10)
    field(:agent_count, non_neg_integer(), default: 0)

    # Lifecycle
    field(:created_at, DateTime.t())
    field(:updated_at, DateTime.t())
    field(:expires_at, DateTime.t(), enforce: false)
    field(:terminated_at, DateTime.t(), enforce: false)

    # Configuration
    field(:timeout, pos_integer(), enforce: false)
    field(:cleanup_policy, atom(), default: :graceful)
    field(:metadata, map(), default: %{})
  end

  @valid_statuses [:initializing, :active, :suspended, :terminating, :terminated, :error]
  @valid_cleanup_policies [:graceful, :immediate, :force]

  @doc """
  Create a new session with validation.

  ## Required Fields

  - `:user_id` - ID of user/client creating the session
  - `:purpose` - Descriptive purpose of the session

  ## Optional Fields

  - `:capabilities` - Initial capabilities for the session
  - `:metadata` - Additional session metadata
  - `:timeout` - Session timeout in milliseconds
  - `:max_agents` - Maximum agents allowed (default: 10)
  - `:expires_at` - When session expires
  - `:cleanup_policy` - How to handle termination (default: :graceful)

  ## Examples

      # Basic session
      {:ok, session} = Session.new(
        user_id: "user_123",
        purpose: "Code analysis"
      )

      # Full configuration
      {:ok, session} = Session.new(
        user_id: "user_456",
        purpose: "Refactor authentication module",
        capabilities: [cap1, cap2],
        max_agents: 20,
        timeout: 3_600_000,  # 1 hour
        metadata: %{project: "auth_service"}
      )
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    session = build_session(attrs)

    case validate_session(session) do
      :ok -> {:ok, session}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_session(attrs) do
    now = DateTime.utc_now()

    required = extract_required_fields(attrs)
    defaults = session_defaults(now, attrs[:timeout])
    optional = extract_optional_fields(attrs)

    attrs_with_defaults = Keyword.merge(Keyword.merge(defaults, required), optional)

    struct!(__MODULE__, attrs_with_defaults)
  end

  defp extract_required_fields(attrs) do
    [
      user_id: Keyword.fetch!(attrs, :user_id),
      purpose: Keyword.fetch!(attrs, :purpose)
    ]
  end

  defp extract_optional_fields(attrs) do
    attrs
    |> Keyword.take([
      :id,
      :status,
      :context,
      :capabilities,
      :agents,
      :max_agents,
      :agent_count,
      :created_at,
      :updated_at,
      :expires_at,
      :terminated_at,
      :timeout,
      :cleanup_policy,
      :metadata
    ])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp session_defaults(now, timeout) do
    [
      id: Identifiers.generate_session_id(),
      status: :initializing,
      context: %{},
      capabilities: [],
      agents: %{},
      max_agents: 10,
      agent_count: 0,
      created_at: now,
      updated_at: now,
      expires_at: calculate_expiration(now, timeout),
      cleanup_policy: :graceful,
      metadata: %{}
    ]
  end

  @doc """
  Transition session to a new status.

  Validates state transitions according to the allowed flow.

  ## Valid Transitions

  - `:initializing` -> `:active`
  - `:active` -> `:suspended` or `:terminating`
  - `:suspended` -> `:active`
  - `:terminating` -> `:terminated`
  - Any state -> `:error`

  ## Examples

      {:ok, active_session} = Session.transition_status(session, :active)
      {:error, :invalid_transition} = Session.transition_status(terminated, :active)
  """
  @spec transition_status(t(), atom()) :: {:ok, t()} | {:error, :invalid_transition}
  def transition_status(%__MODULE__{status: current} = session, new_status) do
    if valid_transition?(current, new_status) do
      updated = %{session | status: new_status, updated_at: DateTime.utc_now()}

      # Set terminated_at if transitioning to terminated
      updated =
        if new_status == :terminated do
          %{updated | terminated_at: DateTime.utc_now()}
        else
          updated
        end

      {:ok, updated}
    else
      {:error, :invalid_transition}
    end
  end

  @doc """
  Add an agent to the session.

  Registers an agent with the session and updates the agent count.

  ## Returns

  - `{:ok, session}` - Agent added successfully
  - `{:error, :max_agents_reached}` - Agent limit exceeded
  - `{:error, :session_not_active}` - Session not in active state
  """
  @spec add_agent(t(), Types.agent_id(), map()) :: {:ok, t()} | {:error, term()}
  def add_agent(%__MODULE__{status: status}, _agent_id, _agent_info) when status != :active do
    {:error, :session_not_active}
  end

  @spec add_agent(t(), Types.agent_id(), map()) :: {:ok, t()} | {:error, term()}
  def add_agent(%__MODULE__{agent_count: count, max_agents: max} = session, agent_id, agent_info) do
    if count >= max do
      {:error, :max_agents_reached}
    else
      updated_agents =
        Map.put(session.agents, agent_id, Map.put(agent_info, :joined_at, DateTime.utc_now()))

      {:ok,
       %{session | agents: updated_agents, agent_count: count + 1, updated_at: DateTime.utc_now()}}
    end
  end

  @doc """
  Remove an agent from the session.

  Unregisters an agent and updates the count.
  """
  @spec remove_agent(t(), Types.agent_id()) :: {:ok, t()} | {:error, :agent_not_found}
  def remove_agent(%__MODULE__{agents: agents} = session, agent_id) do
    if Map.has_key?(agents, agent_id) do
      updated_agents = Map.delete(agents, agent_id)

      {:ok,
       %{
         session
         | agents: updated_agents,
           agent_count: max(0, session.agent_count - 1),
           updated_at: DateTime.utc_now()
       }}
    else
      {:error, :agent_not_found}
    end
  end

  @doc """
  Update shared session context.

  Merges new context data with existing context.
  """
  @spec update_context(t(), map()) :: t()
  def update_context(%__MODULE__{context: current} = session, updates) when is_map(updates) do
    %{session | context: Map.merge(current, updates), updated_at: DateTime.utc_now()}
  end

  @doc """
  Add a capability to the session.

  All agents in the session can use session capabilities.
  """
  @spec add_capability(t(), Capability.t()) :: t()
  def add_capability(%__MODULE__{capabilities: caps} = session, %Capability{} = capability) do
    %{session | capabilities: [capability | caps], updated_at: DateTime.utc_now()}
  end

  @doc """
  Check if session has expired.
  """
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  @doc """
  Check if session is in a terminal state.
  """
  @spec terminal_state?(t()) :: boolean()
  def terminal_state?(%__MODULE__{status: status}) do
    status in [:terminated, :error]
  end

  @doc """
  Get session duration in seconds.
  """
  @spec duration(t()) :: non_neg_integer()
  def duration(%__MODULE__{created_at: created, terminated_at: nil}) do
    DateTime.diff(DateTime.utc_now(), created)
  end

  @spec duration(t()) :: non_neg_integer()
  def duration(%__MODULE__{created_at: created, terminated_at: terminated}) do
    DateTime.diff(terminated, created)
  end

  @doc """
  Convert session to a map suitable for serialization.

  Capabilities are converted to their IDs to avoid circular references.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = session) do
    session
    |> Map.from_struct()
    |> Map.update!(:capabilities, fn caps ->
      Enum.map(caps, & &1.id)
    end)
  end

  # Private functions

  defp calculate_expiration(_now, nil), do: nil

  defp calculate_expiration(now, timeout) when is_integer(timeout) do
    DateTime.add(now, timeout, :millisecond)
  end

  defp validate_session(%__MODULE__{} = session) do
    validators = [
      &validate_user_id/1,
      &validate_purpose/1,
      &validate_status/1,
      &validate_cleanup_policy/1,
      &validate_max_agents/1
    ]

    Enum.reduce_while(validators, :ok, fn validator, :ok ->
      case validator.(session) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_user_id(%{user_id: id}) when is_binary(id) and byte_size(id) > 0, do: :ok
  defp validate_user_id(%{user_id: id}), do: {:error, {:invalid_user_id, id}}

  defp validate_purpose(%{purpose: purpose}) when is_binary(purpose) and byte_size(purpose) > 0,
    do: :ok

  defp validate_purpose(%{purpose: purpose}), do: {:error, {:invalid_purpose, purpose}}

  defp validate_status(%{status: status}) when status in @valid_statuses, do: :ok
  defp validate_status(%{status: status}), do: {:error, {:invalid_status, status}}

  defp validate_cleanup_policy(%{cleanup_policy: policy}) when policy in @valid_cleanup_policies,
    do: :ok

  defp validate_cleanup_policy(%{cleanup_policy: policy}),
    do: {:error, {:invalid_cleanup_policy, policy}}

  defp validate_max_agents(%{max_agents: max}) when is_integer(max) and max > 0, do: :ok
  defp validate_max_agents(%{max_agents: max}), do: {:error, {:invalid_max_agents, max}}

  defp valid_transition?(:initializing, :active), do: true
  defp valid_transition?(:active, :suspended), do: true
  defp valid_transition?(:active, :terminating), do: true
  defp valid_transition?(:suspended, :active), do: true
  defp valid_transition?(:terminating, :terminated), do: true
  defp valid_transition?(_, :error), do: true
  defp valid_transition?(_, _), do: false
end
