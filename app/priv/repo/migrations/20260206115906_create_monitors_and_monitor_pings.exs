defmodule Prikke.Repo.Migrations.CreateMonitorsAndMonitorPings do
  use Ecto.Migration

  def change do
    create table(:monitors, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :ping_token, :string, null: false
      add :schedule_type, :string, null: false
      add :cron_expression, :string
      add :interval_seconds, :integer
      add :grace_period_seconds, :integer, null: false, default: 300
      add :status, :string, null: false, default: "new"
      add :last_ping_at, :utc_datetime
      add :next_expected_at, :utc_datetime
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:monitors, [:ping_token])
    create index(:monitors, [:organization_id])

    create index(:monitors, [:status, :enabled, :next_expected_at],
             where: "enabled = true AND status IN ('new', 'up')",
             name: :monitors_active_check_idx
           )

    create table(:monitor_pings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :monitor_id, references(:monitors, type: :binary_id, on_delete: :delete_all),
        null: false

      add :received_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:monitor_pings, [:monitor_id, :received_at])
  end
end
