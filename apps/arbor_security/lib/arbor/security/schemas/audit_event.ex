defmodule Arbor.Security.Schemas.AuditEvent do
  @moduledoc """
  Ecto schema for persisting audit events in PostgreSQL.

  Audit events provide an immutable trail of all security-relevant
  activities for compliance and forensic analysis.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, []}
  @derive {Jason.Encoder, except: [:__meta__]}

  schema "audit_events" do
    field(:event_type, :string)
    field(:timestamp, :utc_datetime)
    field(:capability_id, :string)
    field(:principal_id, :string)
    field(:actor_id, :string)
    field(:session_id, :string)
    field(:resource_uri, :string)
    field(:operation, :string)
    field(:decision, :string)
    field(:reason, :string)
    field(:trace_id, :string)
    field(:correlation_id, :string)
    field(:context, :map, default: %{})
    field(:metadata, :map, default: %{})

    # Audit events are immutable
    timestamps(updated_at: false)
  end

  @required_fields [:id, :event_type, :timestamp, :principal_id]
  @optional_fields [
    :capability_id,
    :actor_id,
    :session_id,
    :resource_uri,
    :operation,
    :decision,
    :reason,
    :trace_id,
    :correlation_id,
    :context,
    :metadata
  ]

  @valid_event_types ~w(capability_granted capability_revoked capability_delegated
                       authorization_success authorization_denied policy_violation
                       security_alert capability_expired invalid_capability
                       rate_limit_exceeded)

  @doc """
  Create a changeset for a new audit event.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(audit_event, attrs) do
    audit_event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:event_type, @valid_event_types)
    |> validate_format(:principal_id, ~r/^(agent_|system)/)
  end
end
