defmodule Prikke.Repo.Migrations.CreateAuditLogs do
  use Ecto.Migration

  def change do
    create table(:audit_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :actor_id, references(:users, on_delete: :nilify_all, type: :binary_id)
      add :actor_type, :string, null: false  # user, system, api
      add :action, :string, null: false       # created, updated, deleted, etc.
      add :resource_type, :string, null: false # organization, job, execution
      add :resource_id, :binary_id, null: false
      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id)
      add :changes, :map, default: %{}        # JSONB - what changed
      add :metadata, :map, default: %{}       # JSONB - IP, user agent, API key name, etc.

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:audit_logs, [:organization_id, :inserted_at])
    create index(:audit_logs, [:resource_type, :resource_id])
    create index(:audit_logs, [:actor_id])
    create index(:audit_logs, [:inserted_at])
  end
end
