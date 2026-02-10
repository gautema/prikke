defmodule Prikke.Repo.Migrations.AddLastExecutionAtToTasks do
  use Ecto.Migration

  def up do
    alter table(:tasks) do
      add :last_execution_at, :utc_datetime
    end

    # Backfill from executions (single efficient UPDATE ... FROM)
    execute """
    UPDATE tasks SET last_execution_at = sub.last_exec
    FROM (
      SELECT task_id, MAX(scheduled_for) AS last_exec
      FROM executions
      GROUP BY task_id
    ) sub
    WHERE tasks.id = sub.task_id
    """

    # Composite index for the list_tasks sort: org filter + sort by last_execution_at
    create index(:tasks, [:organization_id, :last_execution_at],
      name: :tasks_org_last_execution_idx
    )
  end

  def down do
    drop index(:tasks, [:organization_id, :last_execution_at],
      name: :tasks_org_last_execution_idx
    )

    alter table(:tasks) do
      remove :last_execution_at
    end
  end
end
