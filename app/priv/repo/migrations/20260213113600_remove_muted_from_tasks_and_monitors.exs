defmodule Prikke.Repo.Migrations.RemoveMutedFromTasksAndMonitors do
  use Ecto.Migration

  def up do
    # Migrate muted tasks: set both notification overrides to false
    execute """
    UPDATE tasks
    SET notify_on_failure = false, notify_on_recovery = false
    WHERE muted = true AND notify_on_failure IS NULL AND notify_on_recovery IS NULL
    """

    execute """
    UPDATE monitors
    SET notify_on_failure = false, notify_on_recovery = false
    WHERE muted = true AND notify_on_failure IS NULL AND notify_on_recovery IS NULL
    """

    alter table(:tasks) do
      remove :muted
    end

    alter table(:monitors) do
      remove :muted
    end
  end

  def down do
    alter table(:tasks) do
      add :muted, :boolean, default: false, null: false
    end

    alter table(:monitors) do
      add :muted, :boolean, default: false, null: false
    end

    # Restore muted from notification overrides
    execute """
    UPDATE tasks
    SET muted = true
    WHERE notify_on_failure = false AND notify_on_recovery = false
    """

    execute """
    UPDATE monitors
    SET muted = true
    WHERE notify_on_failure = false AND notify_on_recovery = false
    """
  end
end
