defmodule Prikke.Repo.Migrations.CreateOrganizations do
  use Ecto.Migration

  def change do
    create table(:organizations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :tier, :string, null: false, default: "free"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:organizations, [:slug])

    create table(:memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :role, :string, null: false, default: "member"
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create index(:memberships, [:user_id])
    create index(:memberships, [:organization_id])
    create unique_index(:memberships, [:user_id, :organization_id])

    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string
      add :key_id, :string, null: false
      add :key_hash, :string, null: false
      add :last_used_at, :utc_datetime

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :created_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_keys, [:key_id])
    create index(:api_keys, [:organization_id])
  end
end
