defmodule Prikke.Executions.SchedulingPrecisionDaily do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "scheduling_precision_daily" do
    field :date, :date
    field :request_count, :integer, default: 0
    field :total_delay_ms, :integer, default: 0
    field :p50_ms, :integer, default: 0
    field :p95_ms, :integer, default: 0
    field :p99_ms, :integer, default: 0
    field :max_ms, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:date, :request_count, :total_delay_ms, :p50_ms, :p95_ms, :p99_ms, :max_ms])
    |> validate_required([:date])
    |> unique_constraint(:date)
  end
end
