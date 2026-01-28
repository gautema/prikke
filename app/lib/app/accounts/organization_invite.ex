defmodule Prikke.Accounts.OrganizationInvite do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "organization_invites" do
    field :email, :string
    field :token, :binary
    field :role, :string, default: "member"
    field :accepted_at, :utc_datetime

    belongs_to :organization, Prikke.Accounts.Organization
    belongs_to :invited_by, Prikke.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @hash_algorithm :sha256
  @rand_size 32

  @doc """
  Generates a random token for the invite.
  Returns {raw_token, hashed_token}.
  """
  def build_token do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)
    {Base.url_encode64(token, padding: false), hashed_token}
  end

  @doc """
  Verifies a token and returns the hashed version for lookup.
  """
  def hash_token(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} -> {:ok, :crypto.hash(@hash_algorithm, decoded_token)}
      :error -> :error
    end
  end

  @doc false
  def changeset(invite, attrs) do
    invite
    |> cast(attrs, [:email, :token, :role, :organization_id, :invited_by_id])
    |> validate_required([:email, :token, :organization_id])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_inclusion(:role, ["owner", "admin", "member"])
    |> unique_constraint([:organization_id, :email],
      name: :organization_invites_organization_id_email_index,
      message: "has already been invited"
    )
    |> unique_constraint(:token)
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:invited_by_id)
  end

  @doc false
  def accept_changeset(invite) do
    invite
    |> change(accepted_at: DateTime.utc_now(:second))
  end
end
