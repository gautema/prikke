defmodule Prikke.Endpoints.InboundEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Prikke.UUID7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "inbound_events" do
    field :method, :string
    field :headers, :map, default: %{}
    field :body, :string
    field :source_ip, :string
    field :received_at, :utc_datetime
    field :task_ids, {:array, Ecto.UUID}, default: []

    belongs_to :endpoint, Prikke.Endpoints.Endpoint

    timestamps(type: :utc_datetime)
  end

  def create_changeset(event, attrs) do
    event
    |> cast(attrs, [
      :endpoint_id,
      :method,
      :headers,
      :body,
      :source_ip,
      :received_at,
      :task_ids
    ])
    |> validate_required([:endpoint_id, :method, :received_at])
  end
end
