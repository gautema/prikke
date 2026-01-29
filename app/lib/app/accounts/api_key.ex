defmodule Prikke.Accounts.ApiKey do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Prikke.UUID7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "api_keys" do
    field :name, :string
    field :key_id, :string
    field :key_hash, :string
    field :last_used_at, :utc_datetime

    # Virtual field for the raw secret (only available at creation time)
    field :raw_secret, :string, virtual: true

    belongs_to :organization, Prikke.Accounts.Organization
    belongs_to :created_by, Prikke.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:name, :key_id, :key_hash, :organization_id, :created_by_id])
    |> validate_required([:key_id, :key_hash, :organization_id])
    |> unique_constraint(:key_id)
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:created_by_id)
  end

  @doc """
  Generates a new API key pair.
  Returns {key_id, raw_secret} where:
  - key_id is the public identifier (pk_live_xxx)
  - raw_secret is the secret to be shown once (sk_live_xxx)
  """
  def generate_key_pair do
    key_id = "pk_live_" <> random_string(24)
    raw_secret = "sk_live_" <> random_string(32)
    {key_id, raw_secret}
  end

  @doc """
  Hashes the secret for storage.
  """
  def hash_secret(secret) do
    :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
  end

  @doc """
  Verifies a secret against a stored hash.
  """
  def verify_secret(secret, hash) do
    hash_secret(secret) == hash
  end

  defp random_string(length) do
    :crypto.strong_rand_bytes(length)
    |> Base.url_encode64()
    |> binary_part(0, length)
  end
end
