defmodule Prikke.Repo.Migrations.AddTasksPkeyIndex do
  use Ecto.Migration

  def up do
    # The tasks table is partitioned but the partition (tasks_default) lost its
    # primary key index. Every WHERE id = $1 was doing a full seq scan.
    # This index already exists in production (created manually), but this
    # migration ensures it exists on all environments.
    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS tasks_default_pkey ON tasks_default (id)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS tasks_default_pkey"
  end
end
