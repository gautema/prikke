defmodule Prikke.Repo.Migrations.DropUnusedIndexes do
  use Ecto.Migration

  @doc """
  Drop indexes with zero or near-zero scans in pg_stat_user_indexes.
  These add B-tree maintenance overhead on every INSERT for no read benefit.

  Tasks table (partitioned — drops apply to parent, cascade to partitions):
  - tasks_org_id_covering_idx: 0 scans, 51 MB — plain organization_id_idx serves all queries
  - tasks_enabled_idx: 0 scans, 10 MB — redundant with tasks_enabled_next_run_at_idx
  - tasks_inserted_at_DESC_index: 2 scans, 10 MB — barely used
  - tasks_badge_token_index: 0 scans — never used
  - tasks_deleted_at_idx: 0 scans — never used

  Executions table (partitioned):
  - executions_finished_at_status_index: 45 scans, 6.7 MB — barely used
  - executions_scheduled_for_status_index: 6,984 scans, 7.5 MB — reverse index has 37,850 scans
  """

  def up do
    # Tasks: drop 5 unused indexes (saves ~71 MB, removes 5 B-tree ops per INSERT)
    execute "DROP INDEX IF EXISTS tasks_org_id_covering_idx"
    execute "DROP INDEX IF EXISTS tasks_enabled_idx"
    execute "DROP INDEX IF EXISTS tasks_inserted_at_DESC_index"
    execute "DROP INDEX IF EXISTS tasks_badge_token_index"
    execute "DROP INDEX IF EXISTS tasks_deleted_at_idx"

    # Executions: drop 2 barely-used indexes (saves ~14 MB, removes 2 B-tree ops per INSERT)
    execute "DROP INDEX IF EXISTS executions_finished_at_status_index"
    execute "DROP INDEX IF EXISTS executions_scheduled_for_status_index"
  end

  def down do
    # Tasks
    execute """
    CREATE INDEX tasks_org_id_covering_idx
      ON tasks (organization_id) INCLUDE (enabled, schedule_type, next_run_at)
    """

    execute "CREATE INDEX tasks_enabled_idx ON tasks (enabled) WHERE enabled = true"
    execute "CREATE INDEX tasks_inserted_at_DESC_index ON tasks (inserted_at DESC)"
    execute "CREATE INDEX tasks_badge_token_index ON tasks (badge_token) WHERE badge_token IS NOT NULL"
    execute "CREATE INDEX tasks_deleted_at_idx ON tasks (deleted_at) WHERE deleted_at IS NOT NULL"

    # Executions
    execute "CREATE INDEX executions_finished_at_status_index ON executions (finished_at, status)"
    execute "CREATE INDEX executions_scheduled_for_status_index ON executions (scheduled_for, status)"
  end
end
