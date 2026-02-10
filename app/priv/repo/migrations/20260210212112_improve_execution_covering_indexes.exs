defmodule Prikke.Repo.Migrations.ImproveExecutionCoveringIndexes do
  use Ecto.Migration

  def change do
    # Replace simple scheduled_for index with covering index that includes status.
    # Allows index-only scans for: get_platform_stats_since(), executions_by_day(),
    # get_platform_success_rate() — all filter by scheduled_for and count by status.
    drop index(:executions, [:scheduled_for])
    create index(:executions, [:scheduled_for, :status])

    # Replace simple finished_at index with covering index that includes status.
    # Allows index-only scans for: get_duration_percentiles(), throughput_per_minute(),
    # get_avg_queue_wait() — all filter by finished_at and status.
    drop index(:executions, [:finished_at])
    create index(:executions, [:finished_at, :status])
  end
end
