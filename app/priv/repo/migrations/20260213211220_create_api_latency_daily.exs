defmodule Prikke.Repo.Migrations.CreateApiLatencyDaily do
  use Ecto.Migration

  def change do
    create table(:api_latency_daily, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :date, :date, null: false
      add :group, :string, null: false
      add :request_count, :integer, null: false, default: 0
      add :total_duration_us, :bigint, null: false, default: 0

      # Histogram buckets (13 total)
      # bucket_0: < 1ms, bucket_1: 1-5ms, bucket_2: 5-10ms, bucket_3: 10-25ms,
      # bucket_4: 25-50ms, bucket_5: 50-100ms, bucket_6: 100-250ms, bucket_7: 250-500ms,
      # bucket_8: 500ms-1s, bucket_9: 1-2.5s, bucket_10: 2.5-5s, bucket_11: 5-10s,
      # bucket_12: > 10s
      add :bucket_0, :integer, null: false, default: 0
      add :bucket_1, :integer, null: false, default: 0
      add :bucket_2, :integer, null: false, default: 0
      add :bucket_3, :integer, null: false, default: 0
      add :bucket_4, :integer, null: false, default: 0
      add :bucket_5, :integer, null: false, default: 0
      add :bucket_6, :integer, null: false, default: 0
      add :bucket_7, :integer, null: false, default: 0
      add :bucket_8, :integer, null: false, default: 0
      add :bucket_9, :integer, null: false, default: 0
      add :bucket_10, :integer, null: false, default: 0
      add :bucket_11, :integer, null: false, default: 0
      add :bucket_12, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_latency_daily, [:date, :group])
  end
end
