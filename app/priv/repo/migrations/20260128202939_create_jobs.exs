defmodule Prikke.Repo.Migrations.CreateJobs do
  use Ecto.Migration

  def change do
    create table(:jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :name, :string, null: false
      add :url, :string, null: false
      add :method, :string, default: "GET", null: false
      add :headers, :map, default: %{}
      add :body, :text
      add :schedule_type, :string, null: false
      add :cron_expression, :string
      add :interval_minutes, :integer
      add :scheduled_at, :utc_datetime
      add :timezone, :string, default: "UTC", null: false
      add :enabled, :boolean, default: true, null: false
      add :retry_attempts, :integer, default: 3, null: false
      add :timeout_ms, :integer, default: 30000, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:jobs, [:organization_id])
    create index(:jobs, [:enabled], where: "enabled = true")
    create index(:jobs, [:schedule_type, :scheduled_at], where: "schedule_type = 'once'")

    # Constraint: cron jobs need cron_expression, once jobs need scheduled_at
    create constraint(:jobs, :valid_schedule,
             check: """
             (schedule_type = 'cron' AND cron_expression IS NOT NULL) OR
             (schedule_type = 'once' AND scheduled_at IS NOT NULL)
             """
           )
  end
end
