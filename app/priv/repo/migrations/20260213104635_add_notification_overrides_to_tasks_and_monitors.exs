defmodule Prikke.Repo.Migrations.AddNotificationOverridesToTasksAndMonitors do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :notify_on_failure, :boolean, null: true, default: nil
      add :notify_on_recovery, :boolean, null: true, default: nil
    end

    alter table(:monitors) do
      add :notify_on_failure, :boolean, null: true, default: nil
      add :notify_on_recovery, :boolean, null: true, default: nil
    end
  end
end
