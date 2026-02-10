defmodule Prikke.Repo.Migrations.UpgradeTaskExecutionCoveringIndex do
  use Ecto.Migration

  def change do
    # Upgrade (task_id, scheduled_for) to include status for covering scans.
    # Per-org dashboard queries join executions through tasks and count by status —
    # with status in the index, Postgres can answer without heap lookups.
    execute "DROP INDEX IF EXISTS executions_task_id_scheduled_for_idx",
            "CREATE INDEX executions_task_id_scheduled_for_idx ON executions (task_id, scheduled_for)"

    execute "CREATE INDEX executions_task_id_scheduled_for_status_idx ON executions (task_id, scheduled_for, status)",
            "DROP INDEX IF EXISTS executions_task_id_scheduled_for_status_idx"
  end
end
