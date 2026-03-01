defmodule Prikke.Repo.Migrations.RestoreBadgeTokenAndDeletedAtIndexes do
  use Ecto.Migration

  @doc """
  Restore badge_token and deleted_at indexes. These were dropped based on
  0 scans in pg_stat_user_indexes, but the server had just migrated and
  had no real user traffic yet — the stats were meaningless.

  badge_token: used by public badge URLs (get_task_by_badge_token/1)
  deleted_at: used by soft-delete filtering (not_deleted/1) and purge jobs
  """

  def up do
    execute "CREATE INDEX IF NOT EXISTS tasks_badge_token_index ON tasks (badge_token) WHERE badge_token IS NOT NULL"

    execute "CREATE INDEX IF NOT EXISTS tasks_deleted_at_idx ON tasks (deleted_at) WHERE deleted_at IS NOT NULL"
  end

  def down do
    execute "DROP INDEX IF EXISTS tasks_badge_token_index"
    execute "DROP INDEX IF EXISTS tasks_deleted_at_idx"
  end
end
