defmodule Arbor.Security.Persistence.AuditRepo do
  @moduledoc """
  Real PostgreSQL implementation for audit event persistence.

  This module implements the same interface as the mock PostgresDB
  but uses Ecto and a real database for durable, compliant audit storage.
  """

  import Ecto.Query

  alias Arbor.Contracts.Security.AuditEvent, as: CoreAuditEvent
  alias Arbor.Security.Repo
  alias Arbor.Security.Schemas.AuditEvent, as: SchemaAuditEvent

  @doc """
  Insert audit events into the database.
  """
  @spec insert_audit_events([any()]) :: :ok | {:error, any()}
  def insert_audit_events(events) when is_list(events) do
    # Convert to schema structs
    changesets =
      Enum.map(events, fn event ->
        attrs = audit_event_to_attrs(event)
        SchemaAuditEvent.changeset(%SchemaAuditEvent{}, attrs)
      end)

    # Validate all changesets first
    case Enum.find(changesets, &(not &1.valid?)) do
      nil ->
        # All valid, insert in transaction
        insert_changesets_in_transaction(changesets)

      invalid_changeset ->
        {:error, invalid_changeset}
    end
  end

  @doc """
  Query audit events with filters.
  """
  @spec get_audit_events(keyword()) :: {:ok, [any()]}
  def get_audit_events(filters) do
    query = from(e in SchemaAuditEvent)

    query = apply_audit_filters(query, filters)

    events =
      query
      |> order_by([e], desc: e.timestamp)
      |> Repo.all()
      |> Enum.map(&attrs_to_audit_event/1)

    {:ok, events}
  end

  @doc """
  Clear all audit events (for testing).
  """
  @spec clear_all() :: :ok
  def clear_all do
    Repo.delete_all(SchemaAuditEvent)
    :ok
  end

  # Private functions

  defp audit_event_to_attrs(%CoreAuditEvent{} = event) do
    %{
      id: event.id,
      event_type: to_string(event.event_type),
      timestamp: event.timestamp,
      capability_id: event.capability_id,
      principal_id: event.principal_id,
      actor_id: event.actor_id,
      session_id: event.session_id,
      resource_uri: event.resource_uri,
      operation: event.operation && to_string(event.operation),
      decision: event.decision && to_string(event.decision),
      reason: format_reason(event.reason),
      trace_id: event.trace_id,
      correlation_id: event.correlation_id,
      context: event.context,
      metadata: event.metadata
    }
  end

  defp attrs_to_audit_event(schema_event) do
    {:ok, event} =
      CoreAuditEvent.new(
        id: schema_event.id,
        event_type: String.to_atom(schema_event.event_type),
        timestamp: schema_event.timestamp,
        capability_id: schema_event.capability_id,
        principal_id: schema_event.principal_id,
        actor_id: schema_event.actor_id,
        session_id: schema_event.session_id,
        resource_uri: schema_event.resource_uri,
        operation: schema_event.operation && String.to_atom(schema_event.operation),
        decision: schema_event.decision && String.to_atom(schema_event.decision),
        reason: parse_reason(schema_event.reason),
        trace_id: schema_event.trace_id,
        correlation_id: schema_event.correlation_id,
        context: schema_event.context,
        metadata: schema_event.metadata
      )

    event
  end

  defp format_reason(nil), do: nil
  defp format_reason(reason) when is_atom(reason), do: to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: reason

  defp format_reason({:authorization_denied, sub_reason}),
    do: "authorization_denied:#{sub_reason}"

  defp format_reason(reason), do: inspect(reason)

  defp parse_reason(nil), do: nil

  defp parse_reason("authorization_denied:" <> sub_reason),
    do: {:authorization_denied, String.to_atom(sub_reason)}

  defp parse_reason(reason) when is_binary(reason) do
    # Try to convert back to atom if it was one originally
    String.to_existing_atom(reason)
  rescue
    _ -> reason
  end

  defp insert_changesets_in_transaction(changesets) do
    case Repo.transaction(fn ->
           Enum.each(changesets, &insert_or_rollback/1)
         end) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp apply_audit_filters(query, []), do: query

  defp apply_audit_filters(query, [{:capability_id, id} | rest]) do
    query
    |> where([e], e.capability_id == ^id)
    |> apply_audit_filters(rest)
  end

  defp apply_audit_filters(query, [{:principal_id, id} | rest]) do
    query
    |> where([e], e.principal_id == ^id)
    |> apply_audit_filters(rest)
  end

  defp apply_audit_filters(query, [{:event_type, type} | rest]) do
    query
    |> where([e], e.event_type == ^to_string(type))
    |> apply_audit_filters(rest)
  end

  defp apply_audit_filters(query, [{:reason, reason} | rest]) do
    query
    |> where([e], e.reason == ^format_reason(reason))
    |> apply_audit_filters(rest)
  end

  defp apply_audit_filters(query, [{:limit, limit} | rest]) do
    query
    |> limit(^limit)
    |> apply_audit_filters(rest)
  end

  defp apply_audit_filters(query, [{:from, datetime} | rest]) do
    query
    |> where([e], e.timestamp >= ^datetime)
    |> apply_audit_filters(rest)
  end

  defp apply_audit_filters(query, [{:to, datetime} | rest]) do
    query
    |> where([e], e.timestamp <= ^datetime)
    |> apply_audit_filters(rest)
  end

  defp apply_audit_filters(query, [{:metadata, metadata} | rest]) do
    # PostgreSQL JSONB containment operator @>
    query
    |> where([e], fragment("? @> ?", e.metadata, ^metadata))
    |> apply_audit_filters(rest)
  end

  defp apply_audit_filters(query, [_ | rest]), do: apply_audit_filters(query, rest)
end
