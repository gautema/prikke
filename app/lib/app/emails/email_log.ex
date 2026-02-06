defmodule Prikke.Emails.EmailLog do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Prikke.UUID7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "email_logs" do
    field :to, :string
    field :subject, :string
    field :email_type, :string
    field :status, :string
    field :error, :string

    belongs_to :organization, Prikke.Accounts.Organization

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(email_log, attrs) do
    email_log
    |> cast(attrs, [:to, :subject, :email_type, :status, :error, :organization_id])
    |> validate_required([:to, :subject, :email_type, :status])
    |> validate_inclusion(:status, ~w(sent failed))
  end
end
