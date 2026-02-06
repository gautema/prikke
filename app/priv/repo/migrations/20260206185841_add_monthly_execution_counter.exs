defmodule Prikke.Repo.Migrations.AddMonthlyExecutionCounter do
  use Ecto.Migration

  def change do
    alter table(:organizations) do
      add :monthly_execution_count, :integer, null: false, default: 0
      add :monthly_execution_reset_at, :utc_datetime
    end

    # Backfill: set counts from existing execution data for current month
    flush()

    execute(
      """
      UPDATE organizations SET monthly_execution_count = COALESCE((
        SELECT COUNT(e.id)
        FROM executions e
        JOIN jobs j ON e.job_id = j.id
        WHERE j.organization_id = organizations.id
          AND e.scheduled_for >= date_trunc('month', now() AT TIME ZONE 'UTC')
          AND e.status IN ('success', 'failed', 'timeout')
          AND e.attempt = 1
      ), 0),
      monthly_execution_reset_at = date_trunc('month', now() AT TIME ZONE 'UTC')
      """,
      "SELECT 1"
    )
  end
end
