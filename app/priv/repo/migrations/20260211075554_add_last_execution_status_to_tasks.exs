defmodule Prikke.Repo.Migrations.AddLastExecutionStatusToTasks do
  use Ecto.Migration

  @doc """
  Denormalize last_execution_status onto tasks so the task list can filter
  by execution status at the DB level instead of client-side.
  Raw SQL because tasks is partitioned.
  """

  def up do
    # Add nullable column (instant, no table rewrite)
    execute "ALTER TABLE tasks ADD COLUMN last_execution_status text"

    # Backfill from the latest execution per task
    execute """
    UPDATE tasks t SET last_execution_status = (
      SELECT e.status FROM executions e
      WHERE e.task_id = t.id
      ORDER BY e.scheduled_for DESC LIMIT 1
    )
    """
  end

  def down do
    execute "ALTER TABLE tasks DROP COLUMN last_execution_status"
  end
end
