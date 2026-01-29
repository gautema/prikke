defmodule Prikke.Repo.Migrations.CreatePageviews do
  use Ecto.Migration

  def change do
    create table(:pageviews, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :path, :string, null: false
      add :session_id, :string, null: false
      add :referrer, :string
      add :user_agent, :string
      add :ip_hash, :string
      add :user_id, references(:users, on_delete: :nilify_all, type: :binary_id)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:pageviews, [:inserted_at])
    create index(:pageviews, [:session_id])
    create index(:pageviews, [:path])
    create index(:pageviews, [:user_id])
  end
end
