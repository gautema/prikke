defmodule Prikke.Repo.Migrations.CreateExecutions do
  use Ecto.Migration

  def change do
    create table(:executions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :job_id, references(:jobs, type: :binary_id, on_delete: :delete_all), null: false

      add :status, :string, null: false, default: "pending"
      add :scheduled_for, :utc_datetime, null: false
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      add :status_code, :integer
      add :duration_ms, :integer
      add :response_body, :text
      add :error_message, :text
      add :attempt, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create index(:executions, [:job_id])
    create index(:executions, [:job_id, :scheduled_for])
    create index(:executions, [:status, :scheduled_for])

    create index(:executions, [:status],
             where: "status = 'pending'",
             name: :executions_pending_status_idx
           )
  end
end
