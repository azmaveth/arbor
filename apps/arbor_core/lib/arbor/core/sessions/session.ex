defmodule Arbor.Core.Sessions.Session do
  @moduledoc """
  Individual session process managing a single client interaction context.

  Each session represents an isolated context for client interactions with
  the Arbor system. Sessions maintain:

  - Security context and permissions
  - Execution history and state
  - Active agent associations
  - Event subscriptions and routing
  - Client-specific metadata

  ## Event-Driven Architecture

  Sessions participate in the event-driven architecture by:
  - Subscribing to relevant system events
  - Broadcasting session-specific events
  - Routing execution events to clients
  - Managing event correlation and context

  ## Security Context

  Each session maintains its own security context including:
  - Granted capabilities
  - Active permissions
  - Security audit trail
  - Access control decisions

  ## Usage

  Sessions are typically managed by the Session Manager and interacted
  with through the Gateway. Direct session interaction is primarily
  for internal system use.

      # Send a message to the session
      Session.send_message(session_pid, message)

      # Get session state
      {:ok, state} = Session.get_state(session_pid)

      # Subscribe to session events
      Session.subscribe_events(session_pid)
  """

  @behaviour Arbor.Contracts.Session.Session

  use GenServer

  require Logger

  alias Arbor.Contracts.Core.{Capability, Message}
  alias Arbor.Identifiers
  alias Arbor.Types

  @typedoc "Session state"
  @type state :: %{
          session_id: Types.session_id(),
          created_at: DateTime.t(),
          created_by: String.t() | nil,
          metadata: map(),
          security_context: map(),
          execution_history: [map()],
          active_agents: MapSet.t(),
          subscriptions: MapSet.t(),
          timeout: non_neg_integer(),
          last_activity: DateTime.t()
        }

  # Client API

  @doc """
  Start a session process.

  ## Options

  - `:session_id` (required) - Unique session identifier
  - `:created_by` - Entity that created this session
  - `:metadata` - Initial metadata
  - `:timeout` - Session timeout in milliseconds
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  @impl true
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    # For testing, use regular Registry instead of Horde
    # Use dedicated session registry
    name =
      if Application.get_env(:arbor_core, :registry_impl, :auto) == :mock do
        {:via, Registry, {Arbor.Core.MockSessionRegistry, session_id}}
      else
        {:via, Horde.Registry, {Arbor.Core.SessionRegistry, session_id}}
      end

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Send a message to the session.

  ## Parameters

  - `session` - Session PID or registered name
  - `message` - Message to send

  ## Returns

  - `:ok` - Message sent successfully
  """
  @spec send_message(GenServer.server(), Message.t()) :: :ok
  def send_message(session, %Message{} = message) do
    GenServer.cast(session, {:message, message})
  end

  @doc """
  Get current session state.

  ## Parameters

  - `session` - Session PID or registered name

  ## Returns

  - `{:ok, state}` - Current session state
  """
  @spec get_state(GenServer.server()) :: {:ok, map()}
  def get_state(session) do
    GenServer.call(session, :get_state)
  end

  @doc """
  Get session as a contract-compliant struct.

  Transforms the session's internal state into the Session.t() struct
  required by the Arbor.Contracts.Session.Manager behaviour.

  ## Parameters

  - `session` - Session PID or registered name

  ## Returns

  - `{:ok, Session.t()}` - Session struct
  - `{:error, reason}` - Failed to get struct
  """
  @spec to_struct(GenServer.server()) ::
          {:ok, Arbor.Contracts.Core.Session.t()} | {:error, term()}
  def to_struct(session) do
    GenServer.call(session, :to_struct)
  end

  @doc """
  Subscribe to session events.

  ## Parameters

  - `session` - Session PID or registered name

  ## Returns

  - `:ok` - Subscription successful
  """
  @spec subscribe_events(GenServer.server()) :: :ok
  def subscribe_events(session) do
    GenServer.cast(session, {:subscribe_events, self()})
  end

  @doc """
  Grant a capability to the session.

  ## Parameters

  - `session` - Session PID or registered name
  - `capability` - Capability to grant

  ## Returns

  - `:ok` - Capability granted
  - `{:error, reason}` - Capability grant failed
  """
  @spec grant_capability(GenServer.server(), Capability.t()) :: :ok | {:error, term()}
  def grant_capability(session, %Capability{} = capability) do
    GenServer.call(session, {:grant_capability, capability})
  end

  @doc """
  Add an agent to the session.

  ## Parameters

  - `session` - Session PID or registered name
  - `agent_id` - Agent identifier to associate

  ## Returns

  - `:ok` - Agent added successfully
  """
  @spec add_agent(GenServer.server(), Types.agent_id()) :: :ok
  def add_agent(session, agent_id) do
    GenServer.cast(session, {:add_agent, agent_id})
  end

  @doc """
  Remove an agent from the session.

  ## Parameters

  - `session` - Session PID or registered name
  - `agent_id` - Agent identifier to remove

  ## Returns

  - `:ok` - Agent removed successfully
  """
  @spec remove_agent(GenServer.server(), Types.agent_id()) :: :ok
  def remove_agent(session, agent_id) do
    GenServer.cast(session, {:remove_agent, agent_id})
  end

  # Server implementation

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    # 1 hour default
    timeout = opts[:timeout] || 3_600_000

    Logger.info("Starting session",
      session_id: session_id,
      created_by: opts[:created_by],
      timeout: timeout
    )

    # Subscribe to session-specific events
    Phoenix.PubSub.subscribe(Arbor.Core.PubSub, "session:#{session_id}")

    # Set timeout for session cleanup
    if timeout > 0 do
      Process.send_after(self(), :timeout_check, timeout)
    end

    # Emit telemetry
    :telemetry.execute(
      [:arbor, :session, :start],
      %{count: 1},
      %{session_id: session_id}
    )

    state = %{
      session_id: session_id,
      created_at: DateTime.utc_now(),
      created_by: opts[:created_by],
      metadata: opts[:metadata] || %{},
      security_context: %{
        capabilities: [],
        permissions: MapSet.new(),
        audit_trail: []
      },
      execution_history: [],
      active_agents: MapSet.new(),
      subscriptions: MapSet.new(),
      timeout: timeout,
      last_activity: DateTime.utc_now()
    }

    # Register in the distributed session registry with metadata
    metadata_for_registry = %{
      created_at: state.created_at,
      created_by: state.created_by,
      timeout: state.timeout,
      metadata: state.metadata
    }

    # Register with the SessionRegistry for distributed lookup
    case Application.get_env(:arbor_core, :registry_impl, :auto) do
      :mock ->
        # For tests, register with mock registry
        Registry.register(Arbor.Core.MockSessionRegistry, state.session_id, metadata_for_registry)

      _ ->
        # For production, register with distributed SessionRegistry
        case Arbor.Core.SessionRegistry.register_session(
               state.session_id,
               self(),
               metadata_for_registry
             ) do
          :ok ->
            :ok

          {:error, {:session_conflict, existing_pid}} ->
            # Another session with this ID already exists - this is a serious conflict
            # Better to fail fast than to continue with a conflicted state
            Logger.error("Session registration conflict",
              session_id: state.session_id,
              existing_pid: existing_pid,
              current_pid: self()
            )

            exit({:session_conflict, existing_pid})
        end
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    # Return a sanitized version of state for external consumption
    external_state = %{
      session_id: state.session_id,
      created_at: state.created_at,
      created_by: state.created_by,
      metadata: state.metadata,
      active_agents: MapSet.to_list(state.active_agents),
      execution_count: length(state.execution_history),
      last_activity: state.last_activity,
      uptime_seconds: DateTime.diff(DateTime.utc_now(), state.created_at),
      timeout: state.timeout
    }

    {:reply, {:ok, external_state}, update_activity(state)}
  end

  @impl true
  def handle_call(:to_struct, _from, state) do
    case build_session_struct(state) do
      {:ok, session_struct} ->
        {:reply, {:ok, session_struct}, update_activity(state)}

      {:error, reason} ->
        Logger.error("Failed to build session struct",
          session_id: state.session_id,
          reason: reason
        )

        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:grant_capability, capability}, _from, state) do
    case validate_capability_grant(capability, state) do
      :ok ->
        # Add capability to security context
        new_capabilities = [capability | state.security_context.capabilities]

        new_permissions =
          add_capability_permissions(capability, state.security_context.permissions)

        audit_entry = %{
          action: :capability_granted,
          capability_id: capability.id,
          resource_uri: capability.resource_uri,
          timestamp: DateTime.utc_now()
        }

        new_audit_trail = [audit_entry | state.security_context.audit_trail]

        new_security_context = %{
          state.security_context
          | capabilities: new_capabilities,
            permissions: new_permissions,
            audit_trail: new_audit_trail
        }

        # Broadcast capability grant event
        broadcast_session_event(state.session_id, :capability_granted, %{capability: capability})

        # Emit telemetry
        :telemetry.execute(
          [:arbor, :session, :capability, :granted],
          %{count: 1},
          %{session_id: state.session_id, resource_uri: capability.resource_uri}
        )

        Logger.info("Capability granted to session",
          session_id: state.session_id,
          capability_id: capability.id,
          resource_uri: capability.resource_uri
        )

        new_state = %{state | security_context: new_security_context}
        {:reply, :ok, update_activity(new_state)}

      {:error, reason} ->
        Logger.warning("Capability grant denied",
          session_id: state.session_id,
          capability_id: capability.id,
          reason: reason
        )

        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:message, message}, state) do
    # Process incoming message
    Logger.debug("Session received message",
      session_id: state.session_id,
      from: message.from,
      message_id: message.id
    )

    # Add to execution history
    history_entry = %{
      type: :message_received,
      message_id: message.id,
      from: message.from,
      payload_type: get_payload_type(message.payload),
      timestamp: DateTime.utc_now()
    }

    new_history = [history_entry | Enum.take(state.execution_history, 99)]

    # Broadcast message event
    broadcast_session_event(state.session_id, :message_received, %{
      message_id: message.id,
      from: message.from
    })

    new_state = %{state | execution_history: new_history}
    {:noreply, update_activity(new_state)}
  end

  @impl true
  def handle_cast({:subscribe_events, subscriber_pid}, state) do
    # Add subscriber to session event notifications
    new_subscriptions = MapSet.put(state.subscriptions, subscriber_pid)

    Logger.debug("Process subscribed to session events",
      session_id: state.session_id,
      subscriber: subscriber_pid
    )

    {:noreply, %{state | subscriptions: new_subscriptions}}
  end

  @impl true
  def handle_cast({:add_agent, agent_id}, state) do
    new_agents = MapSet.put(state.active_agents, agent_id)

    # Broadcast agent addition event
    broadcast_session_event(state.session_id, :agent_added, %{agent_id: agent_id})

    Logger.info("Agent added to session",
      session_id: state.session_id,
      agent_id: agent_id
    )

    {:noreply, update_activity(%{state | active_agents: new_agents})}
  end

  @impl true
  def handle_cast({:remove_agent, agent_id}, state) do
    new_agents = MapSet.delete(state.active_agents, agent_id)

    # Broadcast agent removal event
    broadcast_session_event(state.session_id, :agent_removed, %{agent_id: agent_id})

    Logger.info("Agent removed from session",
      session_id: state.session_id,
      agent_id: agent_id
    )

    {:noreply, update_activity(%{state | active_agents: new_agents})}
  end

  @impl true
  def handle_info(:timeout_check, state) do
    now = DateTime.utc_now()
    idle_seconds = DateTime.diff(now, state.last_activity)

    if idle_seconds * 1000 >= state.timeout do
      Logger.info("Session timed out due to inactivity",
        session_id: state.session_id,
        idle_seconds: idle_seconds
      )

      # Broadcast timeout event
      broadcast_session_event(state.session_id, :timeout, %{idle_seconds: idle_seconds})

      {:stop, :timeout, state}
    else
      # Schedule next timeout check
      remaining_timeout = state.timeout - idle_seconds * 1000
      Process.send_after(self(), :timeout_check, max(remaining_timeout, 60_000))
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:execution_event, event}, state) do
    # Forward execution events to subscribers
    Enum.each(state.subscriptions, fn subscriber ->
      if Process.alive?(subscriber) do
        send(subscriber, {:session_execution_event, state.session_id, event})
      end
    end)

    # Add to execution history if it's a completion event
    new_history =
      case event.status do
        status when status in [:completed, :failed] ->
          history_entry = %{
            type: :execution_completed,
            execution_id: event.execution_id,
            status: status,
            timestamp: event.timestamp
          }

          [history_entry | Enum.take(state.execution_history, 99)]

        _ ->
          state.execution_history
      end

    {:noreply, update_activity(%{state | execution_history: new_history})}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Session received unexpected message",
      session_id: state.session_id,
      message: msg
    )

    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Session terminating",
      session_id: state.session_id,
      reason: reason,
      uptime_seconds: DateTime.diff(DateTime.utc_now(), state.created_at)
    )

    # Clean up distributed registry registration
    case Application.get_env(:arbor_core, :registry_impl, :auto) do
      :mock ->
        # For tests, unregister from mock registry
        Registry.unregister(Arbor.Core.MockSessionRegistry, state.session_id)

      _ ->
        # For production, unregister from distributed SessionRegistry
        Arbor.Core.SessionRegistry.unregister_session(state.session_id)
    end

    # Broadcast termination event
    broadcast_session_event(state.session_id, :terminated, %{reason: reason})

    # Emit telemetry
    :telemetry.execute(
      [:arbor, :session, :stop],
      %{duration: DateTime.diff(DateTime.utc_now(), state.created_at) * 1000},
      %{session_id: state.session_id, reason: reason}
    )

    :ok
  end

  # Private functions

  defp update_activity(state) do
    %{state | last_activity: DateTime.utc_now()}
  end

  defp validate_capability_grant(capability, _state) do
    # Basic capability validation
    if Capability.valid?(capability) do
      :ok
    else
      {:error, :invalid_capability}
    end
  end

  defp add_capability_permissions(capability, existing_permissions) do
    # Extract permissions from capability resource URI
    case Identifiers.parse_resource_uri(capability.resource_uri) do
      {:ok, %{type: type, operation: operation, path: path}} ->
        permission = "#{type}:#{operation}:#{path}"
        MapSet.put(existing_permissions, permission)

      {:error, _} ->
        existing_permissions
    end
  end

  defp get_payload_type(payload) when is_map(payload) do
    Map.get(payload, :type, :unknown)
  end

  defp get_payload_type(payload) when is_atom(payload), do: payload
  defp get_payload_type(payload) when is_tuple(payload), do: elem(payload, 0)
  defp get_payload_type(_), do: :unknown

  defp broadcast_session_event(session_id, event_type, data) do
    event = %{
      session_id: session_id,
      type: event_type,
      data: data,
      timestamp: DateTime.utc_now()
    }

    Phoenix.PubSub.broadcast(Arbor.Core.PubSub, "session:#{session_id}", {:session_event, event})
  end

  defp build_session_struct(state) do
    alias Arbor.Contracts.Core.Session, as: SessionContract

    # Map session GenServer state to Session.t() struct
    session_struct = %SessionContract{
      id: state.session_id,
      user_id: state.created_by || "unknown",
      purpose: Map.get(state.metadata, :purpose, "General session"),
      status: determine_session_status(state),
      context: Map.get(state.metadata, :context, %{}),
      # TODO: Map from security_context.capabilities
      capabilities: [],
      agents: build_agents_map(state),
      max_agents: Map.get(state.metadata, :max_agents, 10),
      agent_count: MapSet.size(state.active_agents),
      created_at: state.created_at,
      updated_at: state.last_activity,
      expires_at: calculate_session_expiry(state),
      # Session is active if we can call this function
      terminated_at: nil,
      timeout: state.timeout,
      cleanup_policy: :graceful,
      metadata: state.metadata
    }

    {:ok, session_struct}
  rescue
    e ->
      {:error, {:struct_build_failed, Exception.message(e)}}
  end

  defp determine_session_status(state) do
    # Simple status determination based on activity
    time_since_activity = DateTime.diff(DateTime.utc_now(), state.last_activity)

    cond do
      time_since_activity > state.timeout / 1000 -> :suspended
      MapSet.size(state.active_agents) > 0 -> :active
      true -> :active
    end
  end

  defp build_agents_map(state) do
    # Convert MapSet of agent_ids to a map with basic info
    state.active_agents
    |> MapSet.to_list()
    |> Enum.into(%{}, fn agent_id ->
      {agent_id,
       %{
         # Placeholder - would need to track this
         joined_at: DateTime.utc_now(),
         type: :unknown,
         status: :active
       }}
    end)
  end

  defp calculate_session_expiry(state) do
    if state.timeout do
      DateTime.add(state.created_at, state.timeout, :millisecond)
    else
      nil
    end
  end
end
