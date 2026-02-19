defmodule Prikke.Monitors.MonitorPing do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Prikke.UUID7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "monitor_pings" do
    field :received_at, :utc_datetime
    field :expected_interval_seconds, :integer

    belongs_to :monitor, Prikke.Monitors.Monitor

    timestamps(type: :utc_datetime)
  end

  def changeset(ping, attrs) do
    ping
    |> cast(attrs, [:monitor_id, :received_at, :expected_interval_seconds])
    |> validate_required([:monitor_id, :received_at])
    |> foreign_key_constraint(:monitor_id)
  end
end
