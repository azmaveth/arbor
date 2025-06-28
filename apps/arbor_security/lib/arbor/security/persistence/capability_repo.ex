defmodule Arbor.Security.Persistence.CapabilityRepo do
  @moduledoc """
  Real PostgreSQL implementation for capability persistence.

  This module implements the same interface as the mock PostgresDB
  but uses Ecto and a real database for durable storage.
  """

  import Ecto.Query

  alias Arbor.Contracts.Core.Capability, as: CoreCapability
  alias Arbor.Security.Repo
  alias Arbor.Security.Schemas.Capability, as: SchemaCapability

  @doc """
  Insert a capability into the database.
  """
  @spec insert_capability(CoreCapability.t()) :: :ok | {:error, any()}
  def insert_capability(%CoreCapability{} = capability) do
    attrs = capability_to_attrs(capability)

    %SchemaCapability{}
    |> SchemaCapability.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Get a capability by ID.
  """
  @spec get_capability(String.t()) :: {:ok, CoreCapability.t()} | {:error, atom()}
  def get_capability(capability_id) do
    case Repo.get(SchemaCapability, capability_id) do
      nil ->
        {:error, :not_found}

      schema_cap ->
        # Don't return revoked capabilities
        if schema_cap.revoked do
          {:error, :not_found}
        else
          {:ok, attrs_to_capability(schema_cap)}
        end
    end
  end

  @doc """
  Delete (revoke) a capability.
  """
  @spec delete_capability(String.t(), atom() | String.t(), String.t()) :: :ok | {:error, atom()}
  def delete_capability(capability_id, reason, revoker_id) do
    case Repo.get(SchemaCapability, capability_id) do
      nil ->
        {:error, :not_found}

      schema_cap ->
        attrs = %{
          revoked: true,
          revoked_at: DateTime.utc_now(),
          revocation_reason: to_string(reason),
          revoker_id: revoker_id
        }

        schema_cap
        |> SchemaCapability.revocation_changeset(attrs)
        |> Repo.update()
        |> case do
          {:ok, _} -> :ok
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @doc """
  List capabilities for a principal.
  """
  @spec list_capabilities(String.t(), keyword()) :: {:ok, [CoreCapability.t()]}
  def list_capabilities(principal_id, filters \\ []) do
    query =
      from(c in SchemaCapability,
        where: c.principal_id == ^principal_id,
        where: c.revoked == false
      )

    query = apply_filters(query, filters)

    capabilities =
      query
      |> Repo.all()
      |> Enum.map(&attrs_to_capability/1)

    {:ok, capabilities}
  end

  @doc """
  Get capabilities delegated from a parent.
  """
  @spec get_delegated_capabilities(String.t()) :: {:ok, [CoreCapability.t()]}
  def get_delegated_capabilities(parent_capability_id) do
    capabilities =
      from(c in SchemaCapability,
        where: c.parent_capability_id == ^parent_capability_id,
        where: c.revoked == false
      )
      |> Repo.all()
      |> Enum.map(&attrs_to_capability/1)

    {:ok, capabilities}
  end

  @doc """
  Clear all capabilities (for testing).
  """
  @spec clear_all() :: :ok
  def clear_all do
    Repo.delete_all(SchemaCapability)
    :ok
  end

  # Private functions

  defp capability_to_attrs(%CoreCapability{} = cap) do
    %{
      id: cap.id,
      resource_uri: cap.resource_uri,
      principal_id: cap.principal_id,
      granted_at: cap.granted_at,
      expires_at: cap.expires_at,
      parent_capability_id: cap.parent_capability_id,
      delegation_depth: cap.delegation_depth,
      constraints: cap.constraints,
      metadata: cap.metadata
    }
  end

  defp attrs_to_capability(schema_cap) do
    {:ok, cap} =
      CoreCapability.new(
        id: schema_cap.id,
        resource_uri: schema_cap.resource_uri,
        principal_id: schema_cap.principal_id,
        granted_at: schema_cap.granted_at,
        expires_at: schema_cap.expires_at,
        parent_capability_id: schema_cap.parent_capability_id,
        delegation_depth: schema_cap.delegation_depth,
        constraints: schema_cap.constraints,
        metadata: schema_cap.metadata
      )

    cap
  end

  defp apply_filters(query, []), do: query

  defp apply_filters(query, [{:expires_before, datetime} | rest]) do
    query
    |> where([c], c.expires_at < ^datetime)
    |> apply_filters(rest)
  end

  defp apply_filters(query, [{:resource_prefix, prefix} | rest]) do
    query
    |> where([c], like(c.resource_uri, ^"#{prefix}%"))
    |> apply_filters(rest)
  end

  defp apply_filters(query, [_ | rest]), do: apply_filters(query, rest)
end
