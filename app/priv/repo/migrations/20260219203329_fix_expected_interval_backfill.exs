defmodule Prikke.Repo.Migrations.FixExpectedIntervalBackfill do
  use Ecto.Migration

  def up do
    # The previous backfill incorrectly set all pings to the monitor's CURRENT
    # interval. This re-computes using the actual gap to the nearest neighbor,
    # taking the smaller of (gap_to_prev, gap_to_next). This correctly reflects
    # the interval that was active when each ping was recorded.
    execute("""
    WITH ping_neighbors AS (
      SELECT
        id,
        EXTRACT(EPOCH FROM (received_at - lag(received_at) OVER (PARTITION BY monitor_id ORDER BY received_at))) AS gap_prev,
        EXTRACT(EPOCH FROM (lead(received_at) OVER (PARTITION BY monitor_id ORDER BY received_at) - received_at)) AS gap_next
      FROM monitor_pings
    )
    UPDATE monitor_pings mp
    SET expected_interval_seconds = ROUND(LEAST(
      COALESCE(pn.gap_prev, pn.gap_next),
      COALESCE(pn.gap_next, pn.gap_prev)
    ))::integer
    FROM ping_neighbors pn
    WHERE mp.id = pn.id
      AND (pn.gap_prev IS NOT NULL OR pn.gap_next IS NOT NULL)
    """)
  end

  def down do
    # Reset to NULL; the original migration's backfill can re-run if needed
    execute("UPDATE monitor_pings SET expected_interval_seconds = NULL")
  end
end
