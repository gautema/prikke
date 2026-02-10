defmodule Prikke.Repo.Migrations.AddTasksInsertedAtIndex do
  use Ecto.Migration

  def change do
    # Supports: list_recent_tasks_all() which sorts by inserted_at DESC
    create index(:tasks, ["inserted_at DESC"])
  end
end
