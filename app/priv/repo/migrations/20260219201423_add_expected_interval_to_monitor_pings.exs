defmodule Prikke.Repo.Migrations.AddExpectedIntervalToMonitorPings do
  use Ecto.Migration

  def change do
    alter table(:monitor_pings) do
      add :expected_interval_seconds, :integer
    end

    # Backfill existing pings with their monitor's current interval_seconds
    execute(
      """
      UPDATE monitor_pings
      SET expected_interval_seconds = m.interval_seconds
      FROM monitors m
      WHERE monitor_pings.monitor_id = m.id
        AND m.schedule_type = 'interval'
      """,
      "SELECT 1"
    )
  end
end
