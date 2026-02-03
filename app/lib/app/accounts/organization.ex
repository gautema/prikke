defmodule Prikke.Accounts.Organization do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Prikke.UUID7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "organizations" do
    field :name, :string
    field :tier, :string, default: "free"
    field :webhook_secret, :string

    # Notification settings
    field :notify_on_failure, :boolean, default: true
    field :notification_email, :string
    field :notification_webhook_url, :string

    # Limit notification tracking (to avoid spamming)
    field :limit_warning_sent_at, :utc_datetime
    field :limit_reached_sent_at, :utc_datetime

    has_many :memberships, Prikke.Accounts.Membership
    has_many :users, through: [:memberships, :user]
    has_many :api_keys, Prikke.Accounts.ApiKey

    timestamps(type: :utc_datetime)
  end

  @doc """
  Generates a new webhook secret.
  Format: whsec_<48 hex chars> (24 random bytes)
  """
  def generate_webhook_secret do
    "whsec_" <> Base.encode16(:crypto.strong_rand_bytes(24), case: :lower)
  end

  @doc false
  def changeset(organization, attrs) do
    organization
    |> cast(attrs, [:name, :tier])
    |> validate_required([:name])
    |> validate_inclusion(:tier, ["free", "pro"])
    |> maybe_generate_webhook_secret()
  end

  defp maybe_generate_webhook_secret(changeset) do
    if get_field(changeset, :webhook_secret) do
      changeset
    else
      put_change(changeset, :webhook_secret, generate_webhook_secret())
    end
  end

  @doc """
  Changeset for updating notification settings.
  """
  def notification_changeset(organization, attrs) do
    organization
    |> cast(attrs, [:notify_on_failure, :notification_email, :notification_webhook_url])
    |> validate_format(:notification_email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    |> Prikke.UrlValidator.validate_webhook_url_safe(:notification_webhook_url)
  end
end
