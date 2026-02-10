defmodule Prikke.Repo.Migrations.AddClaimQueryIndex do
  use Ecto.Migration

  @doc """
  Add a targeted partial index for the claim_next_execution query.

  The claim query filters: status = 'pending' AND scheduled_for <= now
  Then sorts by tier, interval_minutes, scheduled_for.

  This index lets Postgres find pending executions in scheduled_for order
  without scanning completed/failed rows.
  """

  def change do
    # Covers the WHERE clause of claim_next_execution efficiently
    execute(
      "CREATE INDEX executions_pending_scheduled_for_idx ON executions (scheduled_for ASC) WHERE status = 'pending'",
      "DROP INDEX executions_pending_scheduled_for_idx"
    )
  end
end
