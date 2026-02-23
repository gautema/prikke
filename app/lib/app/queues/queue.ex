defmodule Prikke.Queues.Queue do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "queues" do
    field :name, :string
    field :paused, :boolean, default: false
    field :organization_id, :binary_id

    timestamps()
  end

  def changeset(queue, attrs) do
    queue
    |> cast(attrs, [:organization_id, :name, :paused])
    |> validate_required([:organization_id, :name])
    |> unique_constraint([:organization_id, :name])
  end
end
