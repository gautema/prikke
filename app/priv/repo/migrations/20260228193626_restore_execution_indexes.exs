defmodule Prikke.Repo.Migrations.RestoreExecutionIndexes do
  use Ecto.Migration

  @doc """
  Restore execution indexes dropped in the previous migration.
  Load testing showed the claim query doubled from 2.50ms to 5.09ms
  without these indexes, causing a significant performance regression.
  """

  def up do
    execute "CREATE INDEX IF NOT EXISTS executions_finished_at_status_index ON executions (finished_at, status)"

    execute "CREATE INDEX IF NOT EXISTS executions_scheduled_for_status_index ON executions (scheduled_for, status)"
  end

  def down do
    execute "DROP INDEX IF EXISTS executions_finished_at_status_index"
    execute "DROP INDEX IF EXISTS executions_scheduled_for_status_index"
  end
end
