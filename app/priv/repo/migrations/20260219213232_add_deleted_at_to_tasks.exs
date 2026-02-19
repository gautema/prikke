defmodule Prikke.Repo.Migrations.AddDeletedAtToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :deleted_at, :utc_datetime
    end

    create index(:tasks, [:deleted_at],
             where: "deleted_at IS NOT NULL",
             name: :tasks_deleted_at_idx
           )
  end
end
