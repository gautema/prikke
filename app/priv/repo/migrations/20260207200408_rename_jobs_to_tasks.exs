defmodule Prikke.Repo.Migrations.RenameJobsToTasks do
  use Ecto.Migration

  def change do
    # Rename table
    rename table(:jobs), to: table(:tasks)

    # Rename FK column in executions
    rename table(:executions), :job_id, to: :task_id

    # Add queue string field
    alter table(:tasks) do
      add :queue, :string
    end

    # Update indexes
    drop_if_exists index(:jobs, [:organization_id])
    drop_if_exists index(:jobs, [:enabled])

    create index(:tasks, [:organization_id])
    create index(:tasks, [:enabled], where: "enabled = true")
    create index(:tasks, [:organization_id, :queue], where: "queue IS NOT NULL")
  end
end
