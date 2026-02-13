defmodule Prikke.Repo.Migrations.CreateSchedulingPrecisionDaily do
  use Ecto.Migration

  def change do
    create table(:scheduling_precision_daily, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :date, :date, null: false
      add :request_count, :integer, null: false, default: 0
      add :total_delay_ms, :bigint, null: false, default: 0
      add :p50_ms, :integer, null: false, default: 0
      add :p95_ms, :integer, null: false, default: 0
      add :p99_ms, :integer, null: false, default: 0
      add :max_ms, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:scheduling_precision_daily, [:date])
  end
end
