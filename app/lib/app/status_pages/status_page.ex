defmodule Prikke.StatusPages.StatusPage do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Prikke.UUID7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "status_pages" do
    field :title, :string
    field :description, :string
    field :slug, :string
    field :enabled, :boolean, default: false

    belongs_to :organization, Prikke.Accounts.Organization

    timestamps(type: :utc_datetime)
  end

  @reserved_slugs ~w(admin api status health docs badge in ping webhooks dev)

  def changeset(status_page, attrs) do
    status_page
    |> cast(attrs, [:title, :description, :slug, :enabled])
    |> validate_required([:title, :slug])
    |> validate_length(:title, min: 1, max: 100)
    |> validate_length(:description, max: 500)
    |> validate_slug()
    |> unique_constraint(:slug)
    |> unique_constraint(:organization_id)
  end

  def create_changeset(status_page, attrs, organization_id) do
    status_page
    |> changeset(attrs)
    |> put_change(:organization_id, organization_id)
    |> validate_required([:organization_id])
  end

  defp validate_slug(changeset) do
    changeset
    |> validate_length(:slug, min: 3, max: 60)
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/,
      message: "must be lowercase letters, numbers, and hyphens only"
    )
    |> validate_exclusion(:slug, @reserved_slugs, message: "is reserved")
  end
end
