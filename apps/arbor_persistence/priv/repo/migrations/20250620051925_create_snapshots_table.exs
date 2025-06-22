defmodule Arbor.Persistence.Repo.Migrations.CreateSnapshotsTable do
  use Ecto.Migration

  def change do
    create table(:snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :stream_id, :string, null: false, size: 255
      add :aggregate_id, :string, null: false, size: 255
      add :aggregate_type, :string, null: false, size: 100
      add :aggregate_version, :integer, null: false
      add :state, :map, null: false
      add :state_hash, :string, size: 255
      add :snapshot_version, :string, null: false, size: 50
      add :metadata, :map, null: false, default: %{}
      add :created_at_snapshot, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # One snapshot per stream - unique constraint
    create unique_index(:snapshots, [:stream_id],
                       name: :snapshots_stream_id_index)

    # Index for querying by aggregate
    create index(:snapshots, [:aggregate_id, :aggregate_type])

    # Index for temporal queries
    create index(:snapshots, [:created_at_snapshot])
  end
end
