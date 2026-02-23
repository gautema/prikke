defmodule Prikke.Repo.Migrations.AddPausedQueues do
  use Ecto.Migration

  def change do
    create table(:queues, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :text, null: false
      add :paused, :boolean, default: false, null: false
      timestamps()
    end

    create unique_index(:queues, [:organization_id, :name])
  end
end
