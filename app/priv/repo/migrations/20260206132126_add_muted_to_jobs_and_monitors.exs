defmodule Prikke.Repo.Migrations.AddMutedToJobsAndMonitors do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :muted, :boolean, default: false, null: false
    end

    alter table(:monitors) do
      add :muted, :boolean, default: false, null: false
    end
  end
end
