defmodule Prikke.Repo.Migrations.AddNextRunAtToJobs do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :next_run_at, :utc_datetime
    end

    # Index for scheduler to find due jobs efficiently
    create index(:jobs, [:enabled, :next_run_at], where: "enabled = true")
  end
end
