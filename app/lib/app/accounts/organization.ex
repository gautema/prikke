defmodule Prikke.Accounts.Organization do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "organizations" do
    field :name, :string
    field :slug, :string
    field :tier, :string, default: "free"

    has_many :memberships, Prikke.Accounts.Membership
    has_many :users, through: [:memberships, :user]
    has_many :api_keys, Prikke.Accounts.ApiKey

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(organization, attrs) do
    organization
    |> cast(attrs, [:name, :slug, :tier])
    |> validate_required([:name, :slug])
    |> validate_inclusion(:tier, ["free", "pro"])
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/, message: "must be lowercase letters, numbers, and hyphens only")
    |> validate_length(:slug, min: 3, max: 50)
    |> unique_constraint(:slug)
  end

  @doc """
  Generates a slug from the organization name.
  """
  def generate_slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.trim("-")
  end
end
