defmodule Prikke.Repo.Migrations.CreateIdempotencyKeys do
  use Ecto.Migration

  def change do
    create table(:idempotency_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false
      add :key, :string, null: false
      add :status_code, :integer, null: false
      add :response_body, :text, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:idempotency_keys, [:organization_id, :key])
  end
end
