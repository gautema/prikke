defmodule Prikke.Idempotency.IdempotencyKey do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Prikke.UUID7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "idempotency_keys" do
    field :key, :string
    field :status_code, :integer
    field :response_body, :string

    belongs_to :organization, Prikke.Accounts.Organization

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(idempotency_key, attrs) do
    idempotency_key
    |> cast(attrs, [:key, :status_code, :response_body, :organization_id])
    |> validate_required([:key, :status_code, :response_body])
    |> unique_constraint([:organization_id, :key])
    |> foreign_key_constraint(:organization_id)
  end
end
