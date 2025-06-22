defmodule Arbor.Security.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  def change do
    create table(:audit_events, primary_key: false) do
      add :id, :string, primary_key: true
      add :event_type, :string, null: false
      add :timestamp, :utc_datetime, null: false
      add :capability_id, :string
      add :principal_id, :string, null: false
      add :actor_id, :string
      add :session_id, :string
      add :resource_uri, :string
      add :operation, :string
      add :decision, :string
      add :reason, :string
      add :trace_id, :string
      add :correlation_id, :string
      add :context, :map, default: %{}
      add :metadata, :map, default: %{}

      # Audit events are immutable, only need inserted_at
      timestamps(updated_at: false)
    end

    # Indexes for common queries
    create index(:audit_events, [:capability_id])
    create index(:audit_events, [:principal_id])
    create index(:audit_events, [:event_type])
    create index(:audit_events, [:timestamp])
    create index(:audit_events, [:session_id])
    create index(:audit_events, [:trace_id])

    # Compound indexes for filtering
    create index(:audit_events, [:principal_id, :event_type])
    create index(:audit_events, [:capability_id, :event_type])

    # JSONB index for metadata queries (PostgreSQL specific)
    execute "CREATE INDEX audit_events_metadata_idx ON audit_events USING gin (metadata);",
            "DROP INDEX audit_events_metadata_idx;"
  end
end