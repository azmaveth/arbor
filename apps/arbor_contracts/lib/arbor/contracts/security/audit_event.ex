defmodule Arbor.Contracts.Security.AuditEvent do
  @moduledoc """
  Security audit event for compliance and monitoring.

  Audit events provide an immutable record of all security-relevant
  activities in the system. They are critical for:
  - Compliance with security policies
  - Forensic analysis after incidents
  - Real-time security monitoring
  - Access pattern analysis

  ## Event Types

  - `:capability_granted` - New capability created
  - `:capability_revoked` - Capability invalidated
  - `:capability_delegated` - Capability delegated to another agent
  - `:authorization_success` - Operation authorized
  - `:authorization_denied` - Operation denied
  - `:policy_violation` - System policy violated
  - `:security_alert` - Suspicious activity detected

  ## Retention

  Audit events should be retained according to compliance requirements,
  typically 90 days minimum for operational events and years for
  security violations.

  ## Usage

      event = AuditEvent.new(
        event_type: :authorization_denied,
        capability_id: "cap_123",
        principal_id: "agent_456",
        resource_uri: "arbor://fs/write/sensitive",
        operation: :write,
        decision: :denied,
        reason: :insufficient_permissions,
        context: %{ip_address: "192.168.1.1"}
      )

  @version "1.0.0"
  """

  use TypedStruct

  alias Arbor.Types

  @derive Jason.Encoder
  typedstruct enforce: true do
    @typedoc "An immutable security audit event"

    # Event identification
    field(:id, String.t())
    field(:event_type, atom())
    field(:timestamp, DateTime.t())

    # Security context
    field(:capability_id, Types.capability_id(), enforce: false)
    field(:principal_id, Types.agent_id())
    field(:actor_id, String.t(), enforce: false)
    field(:session_id, Types.session_id(), enforce: false)

    # Operation details
    field(:resource_uri, Types.resource_uri(), enforce: false)
    field(:operation, Types.operation(), enforce: false)
    field(:decision, atom(), enforce: false)
    field(:reason, atom() | String.t(), enforce: false)

    # Tracing
    field(:trace_id, Types.trace_id(), enforce: false)
    field(:correlation_id, String.t(), enforce: false)

    # Additional context
    field(:context, map(), default: %{})
    field(:metadata, map(), default: %{})
  end

  @valid_event_types [
    :capability_granted,
    :capability_revoked,
    :capability_delegated,
    :authorization_success,
    :authorization_denied,
    :policy_violation,
    :security_alert,
    :capability_expired,
    :invalid_capability,
    :rate_limit_exceeded
  ]

  @valid_decisions [:authorized, :denied, :granted, :revoked, nil]

  @doc """
  Create a new audit event with validation.

  ## Required Fields

  - `:event_type` - Type of security event
  - `:principal_id` - Agent involved in the event

  ## Optional Fields

  - `:capability_id` - Capability involved (if applicable)
  - `:actor_id` - Agent that triggered the event (if different from principal)
  - `:resource_uri` - Resource accessed
  - `:operation` - Operation attempted
  - `:decision` - Security decision made
  - `:reason` - Reason for decision
  - `:session_id` - Session context
  - `:trace_id` - Distributed trace ID
  - `:context` - Additional context data
  - `:metadata` - Event metadata

  ## Examples

      # Authorization success
      {:ok, event} = AuditEvent.new(
        event_type: :authorization_success,
        principal_id: "agent_123",
        capability_id: "cap_456",
        resource_uri: "arbor://fs/read/docs",
        operation: :read,
        decision: :authorized
      )
      
      # Capability grant
      {:ok, event} = AuditEvent.new(
        event_type: :capability_granted,
        principal_id: "agent_789",
        actor_id: "agent_admin",
        capability_id: "cap_new_123",
        resource_uri: "arbor://api/call/external",
        context: %{granted_by: "admin_user", reason: "approved_request"}
      )
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    event = %__MODULE__{
      id: attrs[:id] || generate_event_id(),
      event_type: Keyword.fetch!(attrs, :event_type),
      timestamp: attrs[:timestamp] || DateTime.utc_now(),
      capability_id: attrs[:capability_id],
      principal_id: Keyword.fetch!(attrs, :principal_id),
      actor_id: attrs[:actor_id] || attrs[:principal_id],
      session_id: attrs[:session_id],
      resource_uri: attrs[:resource_uri],
      operation: attrs[:operation],
      decision: attrs[:decision],
      reason: attrs[:reason],
      trace_id: attrs[:trace_id],
      correlation_id: attrs[:correlation_id],
      context: attrs[:context] || %{},
      metadata: attrs[:metadata] || %{}
    }

    case validate_event(event) do
      :ok -> {:ok, event}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Create an authorization event.

  Convenience function for creating authorization success/denial events.

  ## Example

      AuditEvent.authorization(
        :denied,
        capability_id: "cap_123",
        principal_id: "agent_456",
        resource_uri: "arbor://fs/write/secure",
        operation: :write,
        reason: :capability_expired
      )
  """
  @spec authorization(atom(), keyword()) :: {:ok, t()} | {:error, term()}
  def authorization(decision, attrs) when decision in [:authorized, :denied] do
    event_type =
      if decision == :authorized,
        do: :authorization_success,
        else: :authorization_denied

    new(
      attrs
      |> Keyword.put(:event_type, event_type)
      |> Keyword.put(:decision, decision)
    )
  end

  @doc """
  Create a capability lifecycle event.

  Convenience function for capability grant/revoke/delegate events.

  ## Example

      AuditEvent.capability_event(
        :granted,
        capability_id: "cap_new_123",
        principal_id: "agent_789",
        actor_id: "agent_admin",
        resource_uri: "arbor://tool/execute/analyzer"
      )
  """
  @spec capability_event(atom(), keyword()) :: {:ok, t()} | {:error, term()}
  def capability_event(action, attrs) when action in [:granted, :revoked, :delegated] do
    event_type = :"capability_#{action}"

    new(
      attrs
      |> Keyword.put(:event_type, event_type)
      |> Keyword.put(:decision, action)
    )
  end

  @doc """
  Check if an event represents a security failure.

  Returns true for denied authorizations, policy violations, and security alerts.
  """
  @spec security_failure?(t()) :: boolean()
  def security_failure?(%__MODULE__{event_type: type}) do
    type in [:authorization_denied, :policy_violation, :security_alert, :invalid_capability]
  end

  @doc """
  Get severity level of the audit event.

  Used for alerting and prioritization.

  ## Severity Levels

  - `:critical` - Immediate action required
  - `:high` - Security violation or repeated failures
  - `:medium` - Failed authorization attempts
  - `:low` - Normal security operations
  - `:info` - Informational events
  """
  @spec severity(t()) :: atom()
  def severity(%__MODULE__{event_type: type, context: context}) do
    base_severity = severity_map()[type] || :info

    # Elevate severity for specific context conditions
    case {type, context} do
      {:authorization_denied, %{repeated_failures: true}} -> :high
      {:capability_revoked, %{security_incident: true}} -> :high
      _ -> base_severity
    end
  end

  defp severity_map do
    %{
      security_alert: :critical,
      policy_violation: :high,
      invalid_capability: :high,
      authorization_denied: :medium,
      capability_revoked: :low,
      capability_granted: :low,
      capability_delegated: :low
    }
  end

  @doc """
  Convert event to a map suitable for serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    Map.from_struct(event)
  end

  @doc """
  Format event as a log message.

  Creates a human-readable log entry for the event.
  """
  @spec to_log_message(t()) :: String.t()
  def to_log_message(%__MODULE__{} = event) do
    base = "#{event.event_type} - Principal: #{event.principal_id}"

    details = []

    details =
      if event.resource_uri, do: ["Resource: #{event.resource_uri}" | details], else: details

    details = if event.operation, do: ["Operation: #{event.operation}" | details], else: details
    details = if event.decision, do: ["Decision: #{event.decision}" | details], else: details

    details =
      if event.reason, do: ["Reason: #{format_reason(event.reason)}" | details], else: details

    if details == [] do
      base
    else
      "#{base} - #{Enum.join(details, ", ")}"
    end
  end

  # Private functions

  defp generate_event_id do
    "audit_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
  end

  defp validate_event(%__MODULE__{} = event) do
    validators = [
      &validate_event_type/1,
      &validate_principal_id/1,
      &validate_decision/1,
      &validate_operation/1
    ]

    Enum.reduce_while(validators, :ok, fn validator, :ok ->
      case validator.(event) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_event_type(%{event_type: type}) when type in @valid_event_types, do: :ok

  defp validate_event_type(%{event_type: type}) do
    {:error, {:invalid_event_type, type, @valid_event_types}}
  end

  defp validate_principal_id(%{principal_id: id}) when is_binary(id) and byte_size(id) > 0 do
    if String.starts_with?(id, "agent_") or id == "system" do
      :ok
    else
      {:error, {:invalid_principal_id, id}}
    end
  end

  defp validate_principal_id(%{principal_id: id}) do
    {:error, {:invalid_principal_id, id}}
  end

  defp validate_decision(%{decision: nil}), do: :ok
  defp validate_decision(%{decision: decision}) when decision in @valid_decisions, do: :ok

  defp validate_decision(%{decision: decision}) do
    {:error, {:invalid_decision, decision, @valid_decisions}}
  end

  defp validate_operation(%{operation: nil}), do: :ok
  defp validate_operation(%{operation: op}) when is_atom(op), do: :ok

  defp validate_operation(%{operation: op}) do
    {:error, {:invalid_operation, op}}
  end

  defp format_reason(reason) when is_atom(reason), do: reason
  defp format_reason(reason) when is_binary(reason), do: reason

  defp format_reason({:authorization_denied, sub_reason}),
    do: "authorization_denied(#{sub_reason})"

  defp format_reason(reason) when is_tuple(reason), do: inspect(reason)
  defp format_reason(reason), do: inspect(reason)
end
