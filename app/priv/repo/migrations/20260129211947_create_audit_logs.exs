defmodule Prikke.Repo.Migrations.CreateAuditLogs do
  use Ecto.Migration

  def change do
    create table(:audit_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :actor_id, references(:users, on_delete: :nilify_all, type: :binary_id)
      # user, system, api
      add :actor_type, :string, null: false
      # created, updated, deleted, etc.
      add :action, :string, null: false
      # organization, job, execution
      add :resource_type, :string, null: false
      add :resource_id, :binary_id, null: false
      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id)
      # JSONB - what changed
      add :changes, :map, default: %{}
      # JSONB - IP, user agent, API key name, etc.
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:audit_logs, [:organization_id, :inserted_at])
    create index(:audit_logs, [:resource_type, :resource_id])
    create index(:audit_logs, [:actor_id])
    create index(:audit_logs, [:inserted_at])
  end
end
