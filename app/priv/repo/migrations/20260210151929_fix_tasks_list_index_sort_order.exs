defmodule Prikke.Repo.Migrations.FixTasksListIndexSortOrder do
  use Ecto.Migration

  def up do
    # Drop the ASC index that Postgres can't use for DESC NULLS LAST sorting
    drop index(:tasks, [:organization_id, :last_execution_at],
      name: :tasks_org_last_execution_idx
    )

    # Create index matching the exact sort order used by list_tasks:
    # ORDER BY last_execution_at DESC NULLS LAST, inserted_at DESC
    # Postgres can do a forward index scan and return rows in order without sorting.
    execute """
    CREATE INDEX tasks_org_last_execution_idx
    ON tasks (organization_id, last_execution_at DESC NULLS LAST, inserted_at DESC)
    """
  end

  def down do
    execute "DROP INDEX tasks_org_last_execution_idx"

    create index(:tasks, [:organization_id, :last_execution_at],
      name: :tasks_org_last_execution_idx
    )
  end
end
