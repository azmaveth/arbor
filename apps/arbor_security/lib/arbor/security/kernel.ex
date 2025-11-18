defmodule Arbor.Security.Kernel do
  @moduledoc """
  Main security kernel GenServer for the Arbor system.

  This is the central coordinator for all security operations:
  - Capability lifecycle management (grant, revoke, delegate)
  - Authorization decisions using the enforcer
  - Integration with persistence (CapabilityStore) and audit logging
  - Process monitoring for automatic capability revocation
  - Telemetry event emission for monitoring

  The kernel maintains in-memory state for fast operations while ensuring
  all security decisions are persisted and auditable.
  """

  use GenServer

  alias Arbor.Contracts.Core.Capability
  alias Arbor.Contracts.Security.AuditEvent
  alias Arbor.Security.{AuditLogger, CapabilityStore, ProductionEnforcer}

  require Logger

  defstruct [
    :enforcer_impl,
    :capability_store,
    :audit_logger,
    :process_monitors,
    :telemetry_enabled
  ]

  @type state :: %__MODULE__{
          enforcer_impl: module(),
          capability_store: pid() | module(),
          audit_logger: pid() | module(),
          process_monitors: map(),
          telemetry_enabled: boolean()
        }

  # Client API

  @doc """
  Start the security kernel.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Grant a new capability to a principal.

  ## Options

  - `:principal_id` - Agent receiving the capability
  - `:resource_uri` - Resource the capability grants access to
  - `:constraints` - Usage constraints for the capability
  - `:granter_id` - ID of the entity granting the capability
  - `:metadata` - Additional metadata for the capability
  """
  @spec grant_capability(keyword()) :: {:ok, Capability.t()} | {:error, term()}
  def grant_capability(opts) do
    GenServer.call(__MODULE__, {:grant_capability, opts})
  end

  @doc """
  Authorize an operation using a capability.

  ## Options

  - `:capability` - The capability to use for authorization
  - `:resource_uri` - URI of the resource being accessed
  - `:operation` - Operation being requested
  - `:context` - Additional context for the authorization
  """
  @spec authorize(keyword()) :: {:ok, :authorized} | {:error, term()}
  def authorize(opts) do
    GenServer.call(__MODULE__, {:authorize, opts})
  end

  @doc """
  Revoke an existing capability.

  ## Options

  - `:capability_id` - ID of capability to revoke
  - `:reason` - Reason for revocation
  - `:revoker_id` - ID of entity revoking the capability
  - `:cascade` - Whether to revoke delegated capabilities
  """
  @spec revoke_capability(keyword()) :: :ok | {:error, term()}
  def revoke_capability(opts) do
    GenServer.call(__MODULE__, {:revoke_capability, opts})
  end

  @doc """
  Delegate a capability to another principal.

  ## Options

  - `:parent_capability` - Capability being delegated
  - `:delegate_to` - Agent receiving the delegation
  - `:constraints` - Additional constraints for delegated capability
  - `:delegator_id` - ID of agent doing the delegation
  - `:metadata` - Additional metadata
  """
  @spec delegate_capability(keyword()) :: {:ok, Capability.t()} | {:error, term()}
  def delegate_capability(opts) do
    GenServer.call(__MODULE__, {:delegate_capability, opts})
  end

  @doc """
  Reset kernel state for testing purposes.
  """
  @spec reset_for_testing() :: :ok
  def reset_for_testing do
    GenServer.call(__MODULE__, :reset_for_testing)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    # Initialize kernel state
    state = %__MODULE__{
      enforcer_impl: opts[:enforcer_impl] || ProductionEnforcer,
      capability_store: opts[:capability_store] || CapabilityStore,
      audit_logger: opts[:audit_logger] || AuditLogger,
      process_monitors: %{},
      telemetry_enabled: opts[:telemetry_enabled] != false
    }

    # Start dependent services
    {:ok, _store_pid} = start_capability_store(state.capability_store)
    {:ok, _logger_pid} = start_audit_logger(state.audit_logger)

    Logger.info("Security kernel started successfully")

    {:ok, state}
  end

  @impl true
  def handle_call({:grant_capability, opts}, _from, state) do
    start_time = System.monotonic_time()

    result =
      with {:ok, capability} <- create_capability(opts),
           {:ok, stored_capability} <- store_capability(capability, state),
           :ok <- log_capability_grant(stored_capability, opts, state),
           :ok <- emit_telemetry(:capability_granted, stored_capability, state) do
        # Setup process monitoring and update state
        new_state = setup_process_monitoring(stored_capability, opts, state)
        {:ok, stored_capability, new_state}
      else
        {:error, reason} ->
          Logger.warning("Failed to grant capability: #{inspect(reason)}")
          {:error, reason, state}
      end

    # Emit performance telemetry
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:arbor, :security, :kernel, :call],
      %{duration: duration},
      %{function: :grant_capability, success: match?({:ok, _, _}, result)}
    )

    case result do
      {:ok, capability, new_state} -> {:reply, {:ok, capability}, new_state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:authorize, opts}, _from, state) do
    request_id = Base.encode16(:crypto.strong_rand_bytes(8))
    capability = Keyword.fetch!(opts, :capability)
    resource_uri = Keyword.fetch!(opts, :resource_uri)
    operation = Keyword.fetch!(opts, :operation)
    context = Keyword.get(opts, :context, %{})

    # Start authorization telemetry
    :telemetry.execute(
      [:arbor, :security, :authorization, :start],
      %{system_time: System.system_time()},
      %{request_id: request_id, principal_id: Map.get(capability, :principal_id, "unknown")}
    )

    start_time = System.monotonic_time()

    result =
      case authorize_with_enforcer(capability, resource_uri, operation, context, state) do
        {:ok, :authorized} = success ->
          :ok = log_authorization_success(capability, resource_uri, operation, context, state)
          :ok = emit_telemetry(:authorization_success, capability, state)
          success

        {:error, reason} = error ->
          :ok =
            log_authorization_denied(capability, resource_uri, operation, reason, context, state)

          :ok = emit_telemetry(:authorization_denied, capability, state)

          # Check if this is a policy violation
          if reason in [:policy_violation, :security_alert] do
            :telemetry.execute(
              [:arbor, :security, :policy, :violation],
              %{count: 1},
              %{principal_id: Map.get(capability, :principal_id), policy: reason}
            )
          end

          error
      end

    # Stop authorization telemetry
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:arbor, :security, :authorization, :stop],
      %{duration: duration},
      %{request_id: request_id, principal_id: Map.get(capability, :principal_id, "unknown")}
    )

    {:reply, result, state}
  end

  @impl true
  def handle_call({:revoke_capability, opts}, _from, state) do
    capability_id = Keyword.fetch!(opts, :capability_id)
    reason = Keyword.fetch!(opts, :reason)
    revoker_id = Keyword.fetch!(opts, :revoker_id)
    cascade = Keyword.get(opts, :cascade, false)

    case revoke_capability_impl(capability_id, reason, revoker_id, cascade, state) do
      :ok ->
        :ok = log_capability_revocation(capability_id, reason, revoker_id, state)
        :ok = emit_telemetry(:capability_revoked, %{id: capability_id}, state)
        {:reply, :ok, state}

      {:error, reason} = error ->
        Logger.warning("Failed to revoke capability #{capability_id}: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:delegate_capability, opts}, _from, state) do
    parent_capability = Keyword.fetch!(opts, :parent_capability)
    delegate_to = Keyword.fetch!(opts, :delegate_to)
    constraints = Keyword.get(opts, :constraints, %{})
    delegator_id = Keyword.fetch!(opts, :delegator_id)
    metadata = Keyword.get(opts, :metadata, %{})

    case delegate_capability_impl(
           parent_capability,
           delegate_to,
           constraints,
           delegator_id,
           metadata,
           state
         ) do
      {:ok, delegated_capability} ->
        :ok =
          log_capability_delegation(delegated_capability, parent_capability, delegator_id, state)

        :ok = emit_telemetry(:capability_delegated, delegated_capability, state)
        {:reply, {:ok, delegated_capability}, state}

      {:error, reason} = error ->
        Logger.warning("Failed to delegate capability: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:reset_for_testing, _from, state) do
    # Clear process monitors for testing
    new_state = %{state | process_monitors: %{}}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    # Handle process termination - revoke associated capabilities
    case Map.get(state.process_monitors, pid) do
      nil ->
        {:noreply, state}

      capability_ids ->
        Logger.info(
          "Process #{inspect(pid)} terminated (#{reason}), revoking #{length(capability_ids)} capabilities"
        )

        # Revoke all capabilities associated with the terminated process
        revoke_process_capabilities(capability_ids, state)

        # Remove from monitors
        new_state = %{state | process_monitors: Map.delete(state.process_monitors, pid)}
        {:noreply, new_state}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Security kernel terminating: #{inspect(reason)}")

    # Cleanup process monitors
    Enum.each(state.process_monitors, fn {pid, _capability_ids} ->
      Process.demonitor(pid, [:flush])
    end)

    :ok
  end

  # Private helper functions

  defp create_capability(opts) do
    Capability.new(
      resource_uri: Keyword.fetch!(opts, :resource_uri),
      principal_id: Keyword.fetch!(opts, :principal_id),
      constraints: Keyword.get(opts, :constraints, %{}),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  defp store_capability(capability, state) do
    case state.capability_store.store_capability(capability) do
      :ok -> {:ok, capability}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize_with_enforcer(capability, resource_uri, operation, context, state) do
    # Pass the capability store to the enforcer so it can check revocation status
    enforcer_state = %{capability_store: state.capability_store}
    state.enforcer_impl.authorize(capability, resource_uri, operation, context, enforcer_state)
  end

  defp revoke_capability_impl(capability_id, reason, revoker_id, cascade, state) do
    state.capability_store.revoke_capability(capability_id, reason, revoker_id, cascade)
  end

  defp delegate_capability_impl(
         parent_capability,
         delegate_to,
         constraints,
         _delegator_id,
         metadata,
         state
       ) do
    case Capability.delegate(parent_capability, delegate_to,
           constraints: constraints,
           metadata: metadata
         ) do
      {:ok, delegated_capability} ->
        case store_capability(delegated_capability, state) do
          {:ok, stored_capability} -> {:ok, stored_capability}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp log_capability_grant(capability, opts, state) do
    granter_id = Keyword.fetch!(opts, :granter_id)

    {:ok, event} =
      AuditEvent.capability_event(:granted,
        capability_id: capability.id,
        principal_id: capability.principal_id,
        actor_id: granter_id,
        resource_uri: capability.resource_uri
      )

    state.audit_logger.log_event(event)
    :ok
  end

  defp log_authorization_success(capability, resource_uri, operation, context, state) do
    {:ok, event} =
      AuditEvent.authorization(:authorized,
        capability_id: capability.id,
        principal_id: capability.principal_id,
        resource_uri: resource_uri,
        operation: operation,
        context: context
      )

    state.audit_logger.log_event(event)
    :ok
  end

  defp log_authorization_denied(capability, resource_uri, operation, reason, context, state) do
    # Handle cases where capability might not have expected fields
    capability_id = Map.get(capability, :id, "unknown")
    principal_id = Map.get(capability, :principal_id, "agent_unknown")

    {:ok, event} =
      AuditEvent.authorization(:denied,
        capability_id: capability_id,
        principal_id: principal_id,
        resource_uri: resource_uri,
        operation: operation,
        reason: reason,
        context: context
      )

    state.audit_logger.log_event(event)
    :ok
  end

  defp log_capability_revocation(capability_id, reason, revoker_id, state) do
    # Try to get the capability to extract principal_id
    principal_id =
      case state.capability_store.get_capability(capability_id) do
        {:ok, capability} -> capability.principal_id
        # Must be valid format for contracts
        {:error, _} -> "agent_unknown"
      end

    {:ok, event} =
      AuditEvent.capability_event(:revoked,
        capability_id: capability_id,
        principal_id: principal_id,
        actor_id: revoker_id,
        reason: reason
      )

    state.audit_logger.log_event(event)
    :ok
  end

  defp log_capability_delegation(delegated_capability, parent_capability, delegator_id, state) do
    {:ok, event} =
      AuditEvent.new(
        event_type: :capability_delegated,
        capability_id: delegated_capability.id,
        principal_id: delegated_capability.principal_id,
        actor_id: delegator_id,
        resource_uri: delegated_capability.resource_uri,
        context: %{parent_capability_id: parent_capability.id}
      )

    state.audit_logger.log_event(event)
    :ok
  end

  defp emit_telemetry(event_type, capability, state) do
    if state.telemetry_enabled do
      :telemetry.execute(
        [:arbor, :security, :capability, event_type],
        %{count: 1},
        %{
          capability_id: Map.get(capability, :id),
          principal_id: Map.get(capability, :principal_id),
          resource_uri: Map.get(capability, :resource_uri)
        }
      )
    end

    :ok
  end

  defp setup_process_monitoring(capability, opts, state) do
    # Check both top-level opts and capability constraints for process_pid
    pid =
      Keyword.get(opts, :process_pid) ||
        get_in(capability.constraints, [:process_pid]) ||
        get_in(opts, [:constraints, :process_pid])

    case pid do
      nil ->
        state

      pid when is_pid(pid) ->
        # Monitor the process and associate capability with it
        _ref = Process.monitor(pid)

        # Update state to track this capability with the process
        capability_ids = Map.get(state.process_monitors, pid, [])
        new_monitors = Map.put(state.process_monitors, pid, [capability.id | capability_ids])

        %{state | process_monitors: new_monitors}
    end
  end

  defp start_capability_store(CapabilityStore) do
    # Start the capability store if it's not already running
    # In dev/prod mode, it will use Arbor.Security.Persistence.CapabilityRepo (PostgreSQL)
    # In test mode with :use_mock, it will use CapabilityStore.PostgresDB (mock Agent)
    case Process.whereis(CapabilityStore) do
      nil ->
        # Only start mock DB if we're in test mode AND use_mock is enabled
        if Application.get_env(:arbor_security, :use_mock_db, false) do
          case Process.whereis(CapabilityStore.PostgresDB) do
            nil ->
              {:ok, _db_pid} = CapabilityStore.PostgresDB.start_link([])

            _pid ->
              :ok
          end
        end

        CapabilityStore.start_link([])

      pid ->
        {:ok, pid}
    end
  end

  defp start_audit_logger(AuditLogger) do
    # Start the audit logger if it's not already running
    # In dev/prod mode, it will use Arbor.Security.Persistence.AuditRepo (PostgreSQL)
    # In test mode with :use_mock, it will use AuditLogger.PostgresDB (mock Agent)
    case Process.whereis(AuditLogger) do
      nil ->
        # Only start mock DB if we're in test mode AND use_mock is enabled
        if Application.get_env(:arbor_security, :use_mock_db, false) do
          case Process.whereis(AuditLogger.PostgresDB) do
            nil ->
              {:ok, _db_pid} = AuditLogger.PostgresDB.start_link([])

            _pid ->
              :ok
          end
        end

        AuditLogger.start_link([])

      pid ->
        {:ok, pid}
    end
  end

  defp revoke_process_capabilities(capability_ids, state) do
    Enum.each(capability_ids, fn capability_id ->
      case revoke_capability_impl(capability_id, :process_terminated, "system", false, state) do
        :ok ->
          :ok = log_capability_revocation(capability_id, :process_terminated, "system", state)
          :ok = emit_telemetry(:capability_revoked, %{id: capability_id}, state)

        {:error, reason} ->
          Logger.warning(
            "Failed to revoke capability #{capability_id} on process termination: #{inspect(reason)}"
          )
      end
    end)
  end
end
