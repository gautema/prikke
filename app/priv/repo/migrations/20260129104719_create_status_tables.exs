defmodule Prikke.Repo.Migrations.CreateStatusTables do
  use Ecto.Migration

  def change do
    # One row per component, updated every minute
    create table(:status_checks, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :component, :string, null: false
      add :status, :string, null: false, default: "up"
      add :message, :string
      # When monitoring started
      add :started_at, :utc_datetime, null: false
      add :last_checked_at, :utc_datetime, null: false
      # When status last changed
      add :last_status_change_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:status_checks, [:component])

    # Historical record of incidents
    create table(:status_incidents, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :component, :string, null: false
      add :status, :string, null: false, default: "down"
      add :message, :string
      add :started_at, :utc_datetime, null: false
      add :resolved_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:status_incidents, [:component])
    create index(:status_incidents, [:started_at])
  end
end
