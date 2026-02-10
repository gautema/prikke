defmodule Prikke.Repo.Migrations.AddOrganizationIdToExecutions do
  use Ecto.Migration

  @doc """
  Denormalize organization_id onto executions to eliminate join with tasks
  for per-org dashboard queries. Raw SQL needed because executions is partitioned.
  """

  def up do
    # Add nullable column (instant, no table rewrite)
    execute "ALTER TABLE executions ADD COLUMN organization_id uuid"

    # Backfill from tasks
    execute """
    UPDATE executions SET organization_id = (
      SELECT organization_id FROM tasks WHERE tasks.id = executions.task_id
    )
    """

    # Make NOT NULL after backfill
    execute "ALTER TABLE executions ALTER COLUMN organization_id SET NOT NULL"

    # Covering index for per-org aggregate queries
    execute """
    CREATE INDEX executions_org_scheduled_for_status_idx
      ON executions (organization_id, scheduled_for, status)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS executions_org_scheduled_for_status_idx"
    execute "ALTER TABLE executions DROP COLUMN organization_id"
  end
end
