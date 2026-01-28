defmodule Prikke.Accounts.Membership do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "memberships" do
    field :role, :string, default: "member"

    belongs_to :user, Prikke.Accounts.User
    belongs_to :organization, Prikke.Accounts.Organization

    timestamps(type: :utc_datetime)
  end

  @roles ["owner", "admin", "member"]

  @doc false
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role, :user_id, :organization_id])
    |> validate_required([:role, :user_id, :organization_id])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:user_id, :organization_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:organization_id)
  end

  def roles, do: @roles
end
