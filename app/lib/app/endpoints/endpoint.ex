defmodule Prikke.Endpoints.Endpoint do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Prikke.UUID7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "endpoints" do
    field :name, :string
    field :slug, :string
    field :forward_url, :string
    field :enabled, :boolean, default: true
    field :retry_attempts, :integer, default: 5
    field :use_queue, :boolean, default: true
    field :badge_token, :string
    field :notify_on_failure, :boolean
    field :notify_on_recovery, :boolean

    belongs_to :organization, Prikke.Accounts.Organization
    has_many :inbound_events, Prikke.Endpoints.InboundEvent

    timestamps(type: :utc_datetime)
  end

  def changeset(endpoint, attrs) do
    endpoint
    |> cast(attrs, [:name, :forward_url, :enabled, :retry_attempts, :use_queue, :notify_on_failure, :notify_on_recovery])
    |> validate_required([:name, :forward_url])
    |> validate_number(:retry_attempts, greater_than_or_equal_to: 0, less_than_or_equal_to: 10)
    |> validate_url(:forward_url)
  end

  def create_changeset(endpoint, attrs, organization_id) do
    endpoint
    |> changeset(attrs)
    |> put_change(:organization_id, organization_id)
    |> put_change(:slug, generate_slug())
    |> validate_required([:organization_id, :slug])
    |> unique_constraint(:slug)
  end

  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn _, url ->
      case URI.parse(url) do
        %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and not is_nil(host) ->
          []

        _ ->
          [{field, "must be a valid HTTP or HTTPS URL"}]
      end
    end)
  end

  defp generate_slug do
    "ep_" <> (:crypto.strong_rand_bytes(24) |> Base.url_encode64() |> binary_part(0, 32))
  end
end
