defmodule Prikke.Repo.Migrations.CreateEmailLogs do
  use Ecto.Migration

  def change do
    create table(:email_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :to, :string, null: false
      add :subject, :string, null: false
      add :email_type, :string, null: false
      add :status, :string, null: false
      add :error, :text
      add :organization_id, references(:organizations, on_delete: :nilify_all, type: :binary_id)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:email_logs, [:inserted_at])
    create index(:email_logs, [:organization_id])
  end
end
