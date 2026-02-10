defmodule Prikke.Repo.Migrations.AddSuperadminQueryIndexes do
  use Ecto.Migration

  def change do
    # Supports: executions_by_day(), get_platform_stats_since(), get_platform_success_rate()
    # These all filter WHERE scheduled_for >= X with no task_id
    create index(:executions, [:scheduled_for])

    # Supports: get_duration_percentiles(), get_avg_queue_wait(), throughput_per_minute()
    # These all filter WHERE finished_at >= X
    create index(:executions, [:finished_at])
  end
end
