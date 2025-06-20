defmodule Arbor.Contracts.Session.Manager do
  @moduledoc """
  Contract for session management operations.

  Sessions are the primary coordination context for multi-agent interactions.
  They manage agent lifecycles, capability distribution, shared context,
  and ensure proper cleanup of resources.

  ## Session Lifecycle

  1. **Creation**: Session initialized with user/client context
  2. **Agent Spawning**: Agents created within session context
  3. **Coordination**: Agents collaborate using shared session state
  4. **Monitoring**: Health checks and performance tracking
  5. **Cleanup**: Graceful termination and resource cleanup

  ## Session Guarantees

  - All agents in a session share a common security context
  - Session state is eventually consistent across agents
  - Resource cleanup is guaranteed on session termination
  - Audit trail maintained for all session activities

  ## Behavioral Examples

  ### Creating a Session
  Given: Valid session parameters with user ID and capabilities
  When: create_session/1 is called
  Then: Returns {:ok, Session.t()} with assigned ID and active status

  ### Invalid Parameters
  Given: Session parameters missing required fields
  When: create_session/1 is called
  Then: Returns {:error, :invalid_params}

  ### Session Termination
  Given: Active session with running agents
  When: terminate_session/2 is called
  Then: All agents are gracefully stopped and resources cleaned up

  @version "1.0.0"
  """

  alias Arbor.Contracts.Core.Session
  alias Arbor.Types

  @type state :: any()
  @type session_params :: map()
  @type termination_reason :: :normal | :timeout | :error | {:shutdown, term()}

  @type session_error ::
          :invalid_params
          | :session_not_found
          | :session_already_exists
          | :max_sessions_reached
          | :unauthorized
          | :agent_spawn_failed
          | :invalid_state_transition
          | {:custom_error, term()}

  @doc """
  Create a new session with the given parameters.

  Sessions are the primary context for agent coordination. Each session
  maintains its own state, security context, and agent registry.

  ## Parameters

  Required in session_params:
  - `:user_id` - ID of user/client creating the session
  - `:purpose` - Descriptive purpose of the session

  Optional in session_params:
  - `:capabilities` - Initial capabilities for the session
  - `:metadata` - Additional session metadata
  - `:timeout` - Session timeout in milliseconds
  - `:max_agents` - Maximum agents allowed in session

  ## Returns

  - `{:ok, session}` - Session created successfully
  - `{:error, reason}` - Creation failed

  ## Example

      params = %{
        user_id: "user_123",
        purpose: "Code analysis and refactoring",
        capabilities: ["arbor://fs/read/project", "arbor://tool/execute/analyzer"],
        metadata: %{project_id: "proj_456"},
        timeout: 3_600_000  # 1 hour
      }
      
      {:ok, session} = SessionManager.create_session(params, state)
  """
  @callback create_session(
              session_params(),
              state()
            ) :: {:ok, Session.t()} | {:error, session_error()}

  @doc """
  Retrieve a session by ID.

  Returns the current state of the session including active agents,
  capabilities, and metadata.

  ## Returns

  - `{:ok, session}` - Session found
  - `{:error, :session_not_found}` - Session doesn't exist
  """
  @callback get_session(
              session_id :: Types.session_id(),
              state()
            ) :: {:ok, Session.t()} | {:error, session_error()}

  @doc """
  Update session state or metadata.

  Allows updating mutable session properties like metadata, capabilities,
  or timeout. Some properties (like session_id) cannot be changed.

  ## Parameters

  - `session_id` - Session to update
  - `updates` - Map of updates to apply
  - `state` - Manager state

  ## Allowed Updates

  - `:metadata` - Merge with existing metadata
  - `:timeout` - Update session timeout
  - `:max_agents` - Change agent limit
  - `:status` - Transition session status

  ## Returns

  - `{:ok, updated_session}` - Update successful
  - `{:error, :invalid_state_transition}` - Invalid status change
  - `{:error, reason}` - Update failed
  """
  @callback update_session(
              session_id :: Types.session_id(),
              updates :: map(),
              state()
            ) :: {:ok, Session.t()} | {:error, session_error()}

  @doc """
  Spawn an agent within a session context.

  Creates a new agent that inherits the session's security context
  and can access shared session state.

  ## Parameters

  - `session_id` - Session to spawn agent in
  - `agent_type` - Type of agent to spawn
  - `agent_config` - Agent-specific configuration
  - `state` - Manager state

  ## Agent Config

  - `:capabilities` - Additional capabilities for this agent
  - `:metadata` - Agent metadata
  - `:supervisor` - Supervision strategy

  ## Returns

  - `{:ok, agent_id}` - Agent spawned successfully
  - `{:error, :max_agents_reached}` - Session agent limit hit
  - `{:error, :agent_spawn_failed}` - Spawn failed
  """
  @callback spawn_agent(
              session_id :: Types.session_id(),
              agent_type :: Types.agent_type(),
              agent_config :: map(),
              state()
            ) :: {:ok, Types.agent_id()} | {:error, session_error()}

  @doc """
  List all agents in a session.

  Returns information about all agents currently active in the session.

  ## Returns

  List of agent info maps containing:
  - `:agent_id` - Agent identifier
  - `:agent_type` - Type of agent
  - `:status` - Current agent status
  - `:spawned_at` - When agent was created
  - `:capabilities` - Agent's capabilities
  """
  @callback list_agents(
              session_id :: Types.session_id(),
              state()
            ) :: {:ok, [map()]} | {:error, session_error()}

  @doc """
  Grant a capability to all agents in a session.

  Broadcasts a capability grant to all active agents in the session.
  This is useful for dynamically expanding what a session can do.

  ## Parameters

  - `session_id` - Target session
  - `capability` - Capability to grant
  - `state` - Manager state

  ## Returns

  - `:ok` - Capability granted to all agents
  - `{:error, reason}` - Grant failed
  """
  @callback grant_session_capability(
              session_id :: Types.session_id(),
              capability :: Arbor.Contracts.Core.Capability.t(),
              state()
            ) :: :ok | {:error, session_error()}

  @doc """
  Share data across all agents in a session.

  Updates the shared session context that all agents can access.
  Changes are eventually consistent across agents.

  ## Parameters

  - `session_id` - Target session
  - `key` - Context key to update
  - `value` - New value
  - `state` - Manager state

  ## Returns

  - `:ok` - Context updated
  - `{:error, reason}` - Update failed
  """
  @callback update_session_context(
              session_id :: Types.session_id(),
              key :: atom() | String.t(),
              value :: any(),
              state()
            ) :: :ok | {:error, session_error()}

  @doc """
  Get the shared context for a session.

  Returns the current shared context that all agents can access.

  ## Returns

  - `{:ok, context}` - Current session context
  - `{:error, reason}` - Retrieval failed
  """
  @callback get_session_context(
              session_id :: Types.session_id(),
              state()
            ) :: {:ok, map()} | {:error, session_error()}

  @doc """
  Terminate a session and cleanup resources.

  Gracefully shuts down all agents, revokes capabilities, and ensures
  all resources are properly cleaned up.

  ## Parameters

  - `session_id` - Session to terminate
  - `reason` - Reason for termination
  - `state` - Manager state

  ## Termination Process

  1. Mark session as terminating
  2. Notify all agents of pending termination
  3. Wait for agents to gracefully shutdown
  4. Force terminate any remaining agents
  5. Revoke all session capabilities
  6. Clean up session state
  7. Emit audit events

  ## Returns

  - `:ok` - Session terminated successfully
  - `{:error, reason}` - Termination failed
  """
  @callback terminate_session(
              session_id :: Types.session_id(),
              reason :: termination_reason(),
              state()
            ) :: :ok | {:error, session_error()}

  @doc """
  List all active sessions matching filters.

  Used for monitoring and management operations.

  ## Filters

  - `:user_id` - Sessions for specific user
  - `:status` - Filter by session status
  - `:created_after` - Sessions created after timestamp
  - `:created_before` - Sessions created before timestamp

  ## Returns

  - `{:ok, sessions}` - List of matching sessions
  - `{:error, reason}` - Query failed
  """
  @callback list_sessions(
              filters :: keyword(),
              state()
            ) :: {:ok, [Session.t()]} | {:error, session_error()}

  @doc """
  Health check for a session.

  Verifies the session and all its agents are healthy and responsive.

  ## Returns

  Health report map containing:
  - `:session_status` - Overall session health
  - `:agent_health` - Health of each agent
  - `:resource_usage` - Memory, CPU usage
  - `:warnings` - Any health warnings
  """
  @callback health_check(
              session_id :: Types.session_id(),
              state()
            ) :: {:ok, map()} | {:error, session_error()}

  @doc """
  Initialize the session manager.

  Sets up any necessary state, connections, or background processes
  for session management.

  ## Options

  - `:max_sessions` - Maximum concurrent sessions
  - `:session_timeout` - Default session timeout
  - `:cleanup_interval` - How often to clean up expired sessions

  ## Returns

  - `{:ok, state}` - Manager initialized
  - `{:error, reason}` - Initialization failed
  """
  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc """
  Handle session expiration.

  Called periodically to clean up expired sessions. Should terminate
  expired sessions and free resources.

  ## Returns

  - `{:ok, cleaned_count}` - Number of sessions cleaned
  - `{:error, reason}` - Cleanup failed
  """
  @callback handle_expired_sessions(state()) :: {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Clean up resources when shutting down.

  Called when the manager is terminating. Should gracefully shutdown
  all sessions and clean up resources.
  """
  @callback terminate(reason :: term(), state()) :: :ok
end
