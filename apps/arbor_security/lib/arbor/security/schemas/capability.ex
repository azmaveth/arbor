defmodule Arbor.Security.Schemas.Capability do
  @moduledoc """
  Ecto schema for persisting capabilities in PostgreSQL.

  Capabilities are stored with all their properties and constraints
  in a way that allows efficient querying and cascade operations.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, []}
  @derive {Jason.Encoder, except: [:__meta__]}

  schema "capabilities" do
    field(:resource_uri, :string)
    field(:principal_id, :string)
    field(:granted_at, :utc_datetime)
    field(:expires_at, :utc_datetime)
    field(:parent_capability_id, :string)
    field(:delegation_depth, :integer, default: 0)
    field(:constraints, :map, default: %{})
    field(:metadata, :map, default: %{})
    field(:revoked, :boolean, default: false)
    field(:revoked_at, :utc_datetime)
    field(:revocation_reason, :string)
    field(:revoker_id, :string)

    timestamps()
  end

  @required_fields [:id, :resource_uri, :principal_id, :granted_at]
  @optional_fields [
    :expires_at,
    :parent_capability_id,
    :delegation_depth,
    :constraints,
    :metadata,
    :revoked,
    :revoked_at,
    :revocation_reason,
    :revoker_id
  ]

  @doc """
  Create a changeset for a new capability.
  """
  def changeset(capability, attrs) do
    capability
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_format(:resource_uri, ~r/^arbor:\/\/[a-z]+\/[a-z]+\/.+$/)
    |> validate_format(:principal_id, ~r/^agent_/)
    |> validate_number(:delegation_depth, greater_than_or_equal_to: 0)
    |> validate_expiration()
  end

  @doc """
  Create a changeset for revoking a capability.
  """
  def revocation_changeset(capability, attrs) do
    capability
    |> cast(attrs, [:revoked, :revoked_at, :revocation_reason, :revoker_id])
    |> validate_required([:revoked, :revoked_at, :revocation_reason, :revoker_id])
    |> put_change(:revoked, true)
  end

  defp validate_expiration(changeset) do
    case get_change(changeset, :expires_at) do
      nil ->
        changeset

      expires_at ->
        granted_at = get_field(changeset, :granted_at)

        if DateTime.compare(expires_at, granted_at) == :gt do
          changeset
        else
          add_error(changeset, :expires_at, "must be after granted_at")
        end
    end
  end
end
