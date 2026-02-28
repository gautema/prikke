defmodule Prikke.StatusPages.StatusPageItem do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "status_page_items" do
    field :resource_type, :string
    field :resource_id, :binary_id
    field :badge_token, :string
    field :position, :integer, default: 0

    belongs_to :status_page, Prikke.StatusPages.StatusPage

    timestamps(type: :utc_datetime)
  end

  @resource_types ~w(task monitor endpoint queue)

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:resource_type, :resource_id, :badge_token, :position])
    |> validate_required([:resource_type, :resource_id, :badge_token])
    |> validate_inclusion(:resource_type, @resource_types)
    |> unique_constraint(:badge_token)
    |> unique_constraint([:status_page_id, :resource_type, :resource_id],
      name: "status_page_items_status_page_id_resource_type_resource_id_inde"
    )
  end

  def create_changeset(item, attrs, status_page_id) do
    item
    |> changeset(attrs)
    |> put_change(:status_page_id, status_page_id)
    |> validate_required([:status_page_id])
  end
end
