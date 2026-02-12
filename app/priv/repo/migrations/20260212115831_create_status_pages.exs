defmodule Prikke.Repo.Migrations.CreateStatusPages do
  use Ecto.Migration

  def change do
    create table(:status_pages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false
      add :title, :string, null: false
      add :slug, :string, null: false
      add :enabled, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:status_pages, [:organization_id])
    create unique_index(:status_pages, [:slug])
  end
end
