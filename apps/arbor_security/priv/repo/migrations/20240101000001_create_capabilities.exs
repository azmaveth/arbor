defmodule Arbor.Security.Repo.Migrations.CreateCapabilities do
  use Ecto.Migration

  def change do
    create table(:capabilities, primary_key: false) do
      add :id, :string, primary_key: true
      add :resource_uri, :string, null: false
      add :principal_id, :string, null: false
      add :granted_at, :utc_datetime, null: false
      add :expires_at, :utc_datetime
      add :parent_capability_id, :string
      add :delegation_depth, :integer, default: 0
      add :constraints, :map, default: %{}
      add :metadata, :map, default: %{}
      add :revoked, :boolean, default: false
      add :revoked_at, :utc_datetime
      add :revocation_reason, :string
      add :revoker_id, :string
      
      timestamps()
    end
    
    # Indexes for common queries
    create index(:capabilities, [:principal_id])
    create index(:capabilities, [:parent_capability_id])
    create index(:capabilities, [:resource_uri])
    create index(:capabilities, [:revoked])
    create index(:capabilities, [:expires_at])
    
    # Compound index for authorization queries
    create index(:capabilities, [:principal_id, :revoked])
  end
end