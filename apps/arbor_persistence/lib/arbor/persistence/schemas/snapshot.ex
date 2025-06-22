defmodule Arbor.Persistence.Schemas.Snapshot do
  @moduledoc """
  Ecto schema for snapshots in the event store.

  Snapshots provide point-in-time state reconstruction for performance optimization.
  One snapshot per stream, automatically replaced when newer snapshots are created.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "snapshots" do
    field(:stream_id, :string)
    field(:aggregate_id, :string)
    field(:aggregate_type, :string)
    field(:aggregate_version, :integer)
    field(:state, :map)
    field(:state_hash, :string)
    field(:snapshot_version, :string)
    field(:metadata, :map, default: %{})
    field(:created_at_snapshot, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating new snapshots.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :id,
      :stream_id,
      :aggregate_id,
      :aggregate_type,
      :aggregate_version,
      :state,
      :state_hash,
      :snapshot_version,
      :metadata,
      :created_at_snapshot
    ])
    |> validate_required([
      :id,
      :stream_id,
      :aggregate_id,
      :aggregate_type,
      :aggregate_version,
      :state,
      :snapshot_version,
      :created_at_snapshot
    ])
    |> validate_length(:stream_id, min: 1, max: 255)
    |> validate_length(:aggregate_id, min: 1, max: 255)
    |> validate_length(:aggregate_type, min: 1, max: 100)
    |> validate_length(:snapshot_version, min: 1, max: 50)
    |> validate_number(:aggregate_version, greater_than_or_equal_to: 0)
    |> unique_constraint(:stream_id, name: :snapshots_stream_id_index)
  end

  @doc """
  Convert from contract snapshot to database schema.
  """
  @spec from_contract(Arbor.Contracts.Persistence.Snapshot.t()) :: %__MODULE__{}
  def from_contract(contract_snapshot) do
    %__MODULE__{
      id: contract_snapshot.id,
      # Use aggregate_id as stream_id
      stream_id: contract_snapshot.aggregate_id,
      aggregate_id: contract_snapshot.aggregate_id,
      aggregate_type: to_string(contract_snapshot.aggregate_type),
      aggregate_version: contract_snapshot.aggregate_version,
      state: contract_snapshot.state,
      state_hash: contract_snapshot.state_hash,
      snapshot_version: contract_snapshot.snapshot_version,
      metadata: contract_snapshot.metadata || %{},
      created_at_snapshot: contract_snapshot.created_at
    }
  end

  @doc """
  Convert from contract snapshot to map for insert with custom stream_id.
  """
  @spec to_map(Arbor.Contracts.Persistence.Snapshot.t(), String.t()) :: map()
  def to_map(contract_snapshot, stream_id) do
    timestamp = DateTime.utc_now()

    %{
      id: contract_snapshot.id,
      stream_id: stream_id,
      aggregate_id: contract_snapshot.aggregate_id,
      aggregate_type: to_string(contract_snapshot.aggregate_type),
      aggregate_version: contract_snapshot.aggregate_version,
      state: contract_snapshot.state,
      state_hash: contract_snapshot.state_hash,
      snapshot_version: contract_snapshot.snapshot_version,
      metadata: contract_snapshot.metadata || %{},
      created_at_snapshot: contract_snapshot.created_at,
      inserted_at: timestamp,
      updated_at: timestamp
    }
  end

  @doc """
  Convert from database schema to contract snapshot.
  """
  @spec to_contract(%__MODULE__{}) :: Arbor.Contracts.Persistence.Snapshot.t()
  def to_contract(%__MODULE__{} = snapshot) do
    %Arbor.Contracts.Persistence.Snapshot{
      id: snapshot.id,
      aggregate_id: snapshot.aggregate_id,
      aggregate_type: String.to_existing_atom(snapshot.aggregate_type),
      aggregate_version: snapshot.aggregate_version,
      state: snapshot.state,
      state_hash: snapshot.state_hash,
      created_at: snapshot.created_at_snapshot,
      snapshot_version: snapshot.snapshot_version,
      metadata: snapshot.metadata
    }
  end
end
