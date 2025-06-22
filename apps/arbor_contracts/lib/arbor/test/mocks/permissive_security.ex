defmodule Arbor.Test.Mocks.PermissiveSecurity do
  @moduledoc """
  TEST MOCK - DO NOT USE IN PRODUCTION

  Permissive security enforcer for testing that allows all operations.
  This mock is useful for testing business logic without security concerns.

  ## Features

  - Allows all authorization requests by default
  - Tracks all authorization attempts for verification
  - Supports configurable denials for testing error paths
  - Records audit events in memory

  ## Usage in Tests

      defmodule MyTest do
        use ExUnit.Case
        alias Arbor.Test.Mocks.PermissiveSecurity

        setup do
          {:ok, enforcer} = PermissiveSecurity.init([])
          {:ok, enforcer: enforcer}
        end

        test "tracks authorization attempts", %{enforcer: enforcer} do
          cap = %Capability{id: "cap_123", resource_uri: "arbor://fs/read/test"}
          {:ok, :authorized} = PermissiveSecurity.authorize(cap, "arbor://fs/read/test", :read, %{}, enforcer)

          # Verify authorization was tracked
          {:ok, attempts} = PermissiveSecurity.get_authorization_attempts(enforcer)
          assert length(attempts) == 1
        end
      end

  ## Configuring Denials

  You can configure the mock to deny specific operations:

      # Deny next authorization
      PermissiveSecurity.configure_denial(enforcer, :next)

      # Deny specific resource
      PermissiveSecurity.configure_denial(enforcer, {:resource, "arbor://fs/write/secure"})

      # Deny specific capability
      PermissiveSecurity.configure_denial(enforcer, {:capability, "cap_123"})

  @warning This is a TEST MOCK - allows all operations!
  """

  @behaviour Arbor.Contracts.Security.Enforcer

  alias Arbor.Contracts.Core.Capability
  alias Arbor.Contracts.Security.AuditEvent
  alias Arbor.Types

  defstruct [
    :authorization_attempts,
    :audit_events,
    :capabilities,
    :denials,
    :config
  ]

  @impl true
  def init(opts) do
    state = %__MODULE__{
      authorization_attempts: :ets.new(:auth_attempts, [:bag, :public]),
      audit_events: :ets.new(:audit_events, [:ordered_set, :public]),
      capabilities: :ets.new(:capabilities, [:set, :public]),
      denials: :ets.new(:denials, [:set, :public]),
      config: opts
    }

    {:ok, state}
  end

  @impl true
  def authorize(capability, resource_uri, operation, context, state) do
    # Record attempt
    attempt = %{
      capability: capability,
      resource_uri: resource_uri,
      operation: operation,
      context: context,
      timestamp: DateTime.utc_now()
    }

    :ets.insert(state.authorization_attempts, {:attempt, attempt})

    # Check for configured denials
    cond do
      should_deny?(:next, state) ->
        clear_denial(:next, state)
        emit_audit_event(:denied, capability, resource_uri, operation, context, state)
        {:error, {:authorization_denied, :mock_denial}}

      should_deny?({:resource, resource_uri}, state) ->
        emit_audit_event(:denied, capability, resource_uri, operation, context, state)
        {:error, {:authorization_denied, :resource_denied}}

      should_deny?({:capability, capability.id}, state) ->
        emit_audit_event(:denied, capability, resource_uri, operation, context, state)
        {:error, {:authorization_denied, :capability_denied}}

      true ->
        # Default: allow everything
        emit_audit_event(:authorized, capability, resource_uri, operation, context, state)
        {:ok, :authorized}
    end
  end

  @impl true
  def validate_capability(capability, state) do
    if should_deny?({:validate, capability.id}, state) do
      {:error, :invalid_capability}
    else
      # Check basic validity (expiration)
      if capability.expires_at &&
           DateTime.compare(DateTime.utc_now(), capability.expires_at) == :gt do
        {:error, :capability_expired}
      else
        {:ok, :valid}
      end
    end
  end

  @impl true
  def grant_capability(principal_id, resource_uri, constraints, granter_id, state) do
    capability = %Capability{
      id: Types.generate_capability_id(),
      resource_uri: resource_uri,
      principal_id: principal_id,
      granted_at: DateTime.utc_now(),
      expires_at: constraints[:expires_at],
      constraints: constraints,
      metadata: %{granter: granter_id, mock: true}
    }

    :ets.insert(state.capabilities, {capability.id, capability})

    # Emit audit event
    {:ok, event} =
      AuditEvent.capability_event(
        :granted,
        capability_id: capability.id,
        principal_id: principal_id,
        actor_id: granter_id,
        resource_uri: resource_uri
      )

    record_audit_event(event, state)

    {:ok, capability}
  end

  @impl true
  def revoke_capability(capability_id, reason, revoker_id, cascade, state) do
    case :ets.lookup(state.capabilities, capability_id) do
      [{_, capability}] ->
        :ets.delete(state.capabilities, capability_id)

        # Emit audit event
        {:ok, event} =
          AuditEvent.capability_event(
            :revoked,
            capability_id: capability_id,
            principal_id: capability.principal_id,
            actor_id: revoker_id,
            context: %{reason: reason, cascade: cascade}
          )

        record_audit_event(event, state)

        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @impl true
  def delegate_capability(parent_capability, delegate_to, constraints, delegator_id, state) do
    if parent_capability.delegation_depth <= 0 do
      {:error, :delegation_depth_exhausted}
    else
      delegated = %Capability{
        id: Types.generate_capability_id(),
        resource_uri: parent_capability.resource_uri,
        principal_id: delegate_to,
        granted_at: DateTime.utc_now(),
        expires_at: constraints[:expires_at] || parent_capability.expires_at,
        parent_capability_id: parent_capability.id,
        delegation_depth: parent_capability.delegation_depth - 1,
        constraints: Map.merge(parent_capability.constraints, constraints),
        metadata: %{delegator: delegator_id, mock: true}
      }

      :ets.insert(state.capabilities, {delegated.id, delegated})

      # Emit audit event
      {:ok, event} =
        AuditEvent.capability_event(
          :delegated,
          capability_id: delegated.id,
          principal_id: delegate_to,
          actor_id: delegator_id,
          context: %{parent_capability: parent_capability.id}
        )

      record_audit_event(event, state)

      {:ok, delegated}
    end
  end

  @impl true
  def list_capabilities(principal_id, filters, state) do
    all_caps = :ets.tab2list(state.capabilities)

    filtered =
      all_caps
      |> Enum.map(fn {_, cap} -> cap end)
      |> Enum.filter(fn cap -> cap.principal_id == principal_id end)

    # Apply filters
    filtered =
      if filters[:resource_type] do
        type = to_string(filters[:resource_type])

        Enum.filter(filtered, fn cap ->
          String.contains?(cap.resource_uri, "arbor://#{type}/")
        end)
      else
        filtered
      end

    filtered =
      if filters[:include_expired] do
        filtered
      else
        Enum.filter(filtered, fn cap ->
          !cap.expires_at || DateTime.compare(DateTime.utc_now(), cap.expires_at) == :lt
        end)
      end

    {:ok, filtered}
  end

  @impl true
  def get_audit_trail(filters, state) do
    events =
      :ets.tab2list(state.audit_events)
      |> Enum.map(fn {_, event} -> event end)
      |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})

    # Apply filters
    filtered = events

    filtered =
      if filters[:capability_id] do
        Enum.filter(filtered, fn event -> event.capability_id == filters[:capability_id] end)
      else
        filtered
      end

    filtered =
      if filters[:principal_id] do
        Enum.filter(filtered, fn event -> event.principal_id == filters[:principal_id] end)
      else
        filtered
      end

    filtered =
      if filters[:event_type] do
        Enum.filter(filtered, fn event -> event.event_type == filters[:event_type] end)
      else
        filtered
      end

    filtered =
      if filters[:limit] do
        Enum.take(filtered, filters[:limit])
      else
        filtered
      end

    {:ok, filtered}
  end

  @impl true
  def check_policies(_operation, _resource_uri, _context, _state) do
    # Mock always allows unless configured otherwise
    :ok
  end

  @impl true
  def terminate(_reason, state) do
    # Clean up ETS tables
    :ets.delete(state.authorization_attempts)
    :ets.delete(state.audit_events)
    :ets.delete(state.capabilities)
    :ets.delete(state.denials)
    :ok
  end

  # Mock-specific functions for testing

  @doc """
  Configure the mock to deny specific operations.
  """
  @spec configure_denial(map(), any()) :: :ok
  def configure_denial(state, denial_spec) do
    :ets.insert(state.denials, {denial_spec})
    :ok
  end

  @doc """
  Clear a denial configuration.
  """
  @spec clear_denial(any(), map()) :: :ok | true
  def clear_denial(denial_spec, state) do
    :ets.delete(state.denials, denial_spec)
  end

  @doc """
  Get all authorization attempts for verification.
  """
  @spec get_authorization_attempts(map()) :: {:ok, [map()]}
  def get_authorization_attempts(state) do
    attempts =
      Enum.map(:ets.match_object(state.authorization_attempts, {:attempt, :_}), fn {:attempt,
                                                                                    attempt} ->
        attempt
      end)

    {:ok, attempts}
  end

  @doc """
  Clear all tracked data.
  """
  @spec reset(map()) :: :ok
  def reset(state) do
    :ets.delete_all_objects(state.authorization_attempts)
    :ets.delete_all_objects(state.audit_events)
    :ets.delete_all_objects(state.capabilities)
    :ets.delete_all_objects(state.denials)
    :ok
  end

  # Private functions

  defp should_deny?(spec, state) do
    :ets.member(state.denials, spec)
  end

  defp emit_audit_event(decision, capability, resource_uri, operation, context, state) do
    {:ok, event} =
      AuditEvent.authorization(
        decision,
        capability_id: capability.id,
        principal_id: capability.principal_id,
        resource_uri: resource_uri,
        operation: operation,
        session_id: context[:session_id],
        trace_id: context[:trace_id]
      )

    record_audit_event(event, state)
  end

  defp record_audit_event(event, state) do
    key = {event.timestamp, event.id}
    :ets.insert(state.audit_events, {key, event})
  end
end
