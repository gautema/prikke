defmodule Prikke.Repo.Migrations.CreateErrorTrackerTables do
  use Ecto.Migration

  def up do
    ErrorTracker.Migration.up(version: 4)
  end

  def down do
    ErrorTracker.Migration.down(version: 4)
  end
end
