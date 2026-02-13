defmodule Prikke.ApiMetrics.DailyLatency do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "api_latency_daily" do
    field :date, :date
    field :group, :string
    field :request_count, :integer, default: 0
    field :total_duration_us, :integer, default: 0
    field :bucket_0, :integer, default: 0
    field :bucket_1, :integer, default: 0
    field :bucket_2, :integer, default: 0
    field :bucket_3, :integer, default: 0
    field :bucket_4, :integer, default: 0
    field :bucket_5, :integer, default: 0
    field :bucket_6, :integer, default: 0
    field :bucket_7, :integer, default: 0
    field :bucket_8, :integer, default: 0
    field :bucket_9, :integer, default: 0
    field :bucket_10, :integer, default: 0
    field :bucket_11, :integer, default: 0
    field :bucket_12, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @bucket_fields ~w(bucket_0 bucket_1 bucket_2 bucket_3 bucket_4 bucket_5 bucket_6
    bucket_7 bucket_8 bucket_9 bucket_10 bucket_11 bucket_12)a

  def bucket_fields, do: @bucket_fields

  def changeset(daily_latency, attrs) do
    daily_latency
    |> cast(attrs, [:date, :group, :request_count, :total_duration_us | @bucket_fields])
    |> validate_required([:date, :group])
  end
end
