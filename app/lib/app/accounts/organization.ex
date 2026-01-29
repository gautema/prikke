defmodule Prikke.Accounts.Organization do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Prikke.UUID7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "organizations" do
    field :name, :string
    field :slug, :string
    field :tier, :string, default: "free"

    # Notification settings
    field :notify_on_failure, :boolean, default: true
    field :notification_email, :string
    field :notification_webhook_url, :string

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
  Changeset for updating notification settings.
  """
  def notification_changeset(organization, attrs) do
    organization
    |> cast(attrs, [:notify_on_failure, :notification_email, :notification_webhook_url])
    |> validate_format(:notification_email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    |> validate_webhook_url()
  end

  defp validate_webhook_url(changeset) do
    case get_change(changeset, :notification_webhook_url) do
      nil -> changeset
      "" -> changeset
      url ->
        uri = URI.parse(url)
        if uri.scheme in ["http", "https"] and uri.host do
          changeset
        else
          add_error(changeset, :notification_webhook_url, "must be a valid HTTP or HTTPS URL")
        end
    end
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
