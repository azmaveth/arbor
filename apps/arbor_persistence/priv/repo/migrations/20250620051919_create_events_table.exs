defmodule Arbor.Persistence.Repo.Migrations.CreateEventsTable do
  use Ecto.Migration

  def change do
    create table(:events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :stream_id, :string, null: false, size: 255
      add :stream_version, :integer, null: false
      add :event_type, :string, null: false, size: 100
      add :event_version, :string, null: false, size: 50
      add :aggregate_id, :string, null: false, size: 255
      add :aggregate_type, :string, null: false, size: 100
      add :data, :map, null: false
      add :metadata, :map, null: false, default: %{}
      add :causation_id, :binary_id
      add :correlation_id, :string, size: 255
      add :trace_id, :string, size: 255
      add :global_position, :bigserial
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Primary index for event ordering within streams
    create unique_index(:events, [:stream_id, :stream_version],
                       name: :events_stream_id_stream_version_index)

    # Index for querying by aggregate
    create index(:events, [:aggregate_id, :aggregate_type])

    # Index for global event ordering
    create index(:events, [:global_position])

    # Index for temporal queries
    create index(:events, [:occurred_at])

    # Index for correlation tracking
    create index(:events, [:correlation_id])
    create index(:events, [:trace_id])
  end
end
