defmodule Prikke.Repo.Migrations.AddMissingErrorTrackerColumns do
  use Ecto.Migration

  def change do
    # Add the muted column that was missing from the ErrorTracker v4 migration
    alter table(:error_tracker_errors) do
      add_if_not_exists :muted, :boolean, default: false, null: false
    end
  end
end
