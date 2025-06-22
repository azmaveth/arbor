defmodule Arbor.Persistence.Schemas.Event do
  @moduledoc """
  Ecto schema for events in the event store.

  Maps to the events table and provides persistence for event sourcing.
  Uses UUID primary keys and includes optimistic locking via version fields.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "events" do
    field(:stream_id, :string)
    field(:stream_version, :integer)
    field(:event_type, :string)
    field(:event_version, :string)
    field(:aggregate_id, :string)
    field(:aggregate_type, :string)
    field(:data, :map)
    field(:metadata, :map, default: %{})
    field(:causation_id, :binary_id)
    field(:correlation_id, :string)
    field(:trace_id, :string)
    field(:global_position, :integer)
    field(:occurred_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating new events.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :id,
      :stream_id,
      :stream_version,
      :event_type,
      :event_version,
      :aggregate_id,
      :aggregate_type,
      :data,
      :metadata,
      :causation_id,
      :correlation_id,
      :trace_id,
      :global_position,
      :occurred_at
    ])
    |> validate_required([
      :id,
      :stream_id,
      :stream_version,
      :event_type,
      :event_version,
      :aggregate_id,
      :aggregate_type,
      :data,
      :occurred_at
    ])
    |> validate_length(:stream_id, min: 1, max: 255)
    |> validate_length(:event_type, min: 1, max: 100)
    |> validate_length(:aggregate_id, min: 1, max: 255)
    |> validate_length(:aggregate_type, min: 1, max: 100)
    |> validate_number(:stream_version, greater_than_or_equal_to: 0)
    |> unique_constraint(:stream_version, name: :events_stream_id_stream_version_index)
  end

  @doc """
  Convert from contract event to database schema.
  """
  @spec from_contract(any()) :: %__MODULE__{}
  def from_contract(contract_event) do
    %__MODULE__{
      id: contract_event.id,
      stream_id: contract_event.stream_id || contract_event.aggregate_id,
      stream_version: contract_event.stream_version || 0,
      event_type: to_string(contract_event.type),
      event_version: contract_event.version,
      aggregate_id: contract_event.aggregate_id,
      aggregate_type: to_string(contract_event.aggregate_type),
      data: contract_event.data,
      metadata: contract_event.metadata || %{},
      causation_id: contract_event.causation_id,
      correlation_id: contract_event.correlation_id,
      trace_id: contract_event.trace_id,
      global_position: contract_event.global_position,
      occurred_at: contract_event.timestamp
    }
  end

  @doc """
  Convert from contract event to map for insert_all.
  """
  @spec to_map(any()) :: map()
  def to_map(contract_event) do
    timestamp = DateTime.utc_now()

    base_map = %{
      id: contract_event.id,
      stream_id: contract_event.stream_id || contract_event.aggregate_id,
      stream_version: contract_event.stream_version || 0,
      event_type: to_string(contract_event.type),
      event_version: contract_event.version,
      aggregate_id: contract_event.aggregate_id,
      aggregate_type: to_string(contract_event.aggregate_type),
      data: contract_event.data,
      metadata: contract_event.metadata || %{},
      correlation_id: contract_event.correlation_id,
      trace_id: contract_event.trace_id,
      occurred_at: contract_event.timestamp,
      inserted_at: timestamp,
      updated_at: timestamp
    }

    # Only include non-nil optional fields
    maybe_put(base_map, :causation_id, contract_event.causation_id)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Convert from database schema to contract event.
  """
  @spec to_contract(%__MODULE__{}) :: any()
  def to_contract(%__MODULE__{} = event) do
    %Arbor.Contracts.Events.Event{
      id: event.id,
      type: String.to_existing_atom(event.event_type),
      version: event.event_version,
      aggregate_id: event.aggregate_id,
      aggregate_type: String.to_existing_atom(event.aggregate_type),
      data: event.data,
      timestamp: event.occurred_at,
      causation_id: event.causation_id,
      correlation_id: event.correlation_id,
      trace_id: event.trace_id,
      stream_id: event.stream_id,
      stream_version: event.stream_version,
      global_position: event.global_position,
      metadata: event.metadata
    }
  end
end
