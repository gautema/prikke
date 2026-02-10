defmodule Prikke.Repo.Migrations.AddCoveringIndexesForDashboard do
  use Ecto.Migration

  @doc """
  Covering indexes to enable index-only scans for dashboard queries.
  The tables have large text columns (response_body, headers, body) that make
  seq scans slow. These indexes contain only the columns needed by dashboard
  queries, so Postgres can scan the much smaller index instead of the full table.
  """

  def up do
    # Replace the existing org+scheduled_for+status index with one that
    # also INCLUDEs duration_ms — enables index-only scan for get_dashboard_stats
    execute "DROP INDEX IF EXISTS executions_org_scheduled_for_status_idx"

    execute """
    CREATE INDEX executions_org_scheduled_for_status_idx
      ON executions (organization_id, scheduled_for)
      INCLUDE (status, duration_ms)
    """

    # Covering index on tasks for count_tasks_summary — avoids seq scan
    # on the full tasks table (which includes large headers/body columns)
    execute """
    CREATE INDEX tasks_org_id_covering_idx
      ON tasks (organization_id)
      INCLUDE (enabled, schedule_type, next_run_at)
    """

    # NOTE: Run VACUUM ANALYZE on production after deploying to update
    # the visibility map (required for index-only scans to be effective).
    # VACUUM cannot run inside a migration transaction.
  end

  def down do
    execute "DROP INDEX IF EXISTS tasks_org_id_covering_idx"
    execute "DROP INDEX IF EXISTS executions_org_scheduled_for_status_idx"

    # Recreate the original index
    execute """
    CREATE INDEX executions_org_scheduled_for_status_idx
      ON executions (organization_id, scheduled_for, status)
    """
  end
end
