defmodule Prikke.Endpoints.Endpoint do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Prikke.UUID7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "endpoints" do
    field :name, :string
    field :slug, :string
    field :forward_urls, {:array, :string}, default: []
    field :enabled, :boolean, default: true
    field :retry_attempts, :integer, default: 5
    field :use_queue, :boolean, default: true
    field :notify_on_failure, :boolean
    field :notify_on_recovery, :boolean
    field :on_failure_url, :string
    field :on_recovery_url, :string
    field :forward_headers, :map, default: %{}
    field :forward_body, :string
    field :forward_method, :string

    belongs_to :organization, Prikke.Accounts.Organization
    has_many :inbound_events, Prikke.Endpoints.InboundEvent

    timestamps(type: :utc_datetime)
  end

  def changeset(endpoint, attrs) do
    endpoint
    |> cast(attrs, [
      :name,
      :forward_urls,
      :enabled,
      :retry_attempts,
      :use_queue,
      :notify_on_failure,
      :notify_on_recovery,
      :on_failure_url,
      :on_recovery_url,
      :forward_headers,
      :forward_body,
      :forward_method
    ])
    |> validate_required([:name])
    |> validate_number(:retry_attempts, greater_than_or_equal_to: 0, less_than_or_equal_to: 10)
    |> validate_forward_urls_required()
    |> validate_forward_urls()
    |> validate_optional_url(:on_failure_url)
    |> validate_optional_url(:on_recovery_url)
    |> validate_inclusion(:forward_method, ~w(GET POST PUT PATCH DELETE HEAD OPTIONS),
      message: "must be a valid HTTP method"
    )
  end

  def create_changeset(endpoint, attrs, organization_id) do
    endpoint
    |> changeset(attrs)
    |> put_change(:organization_id, organization_id)
    |> put_change(:slug, generate_slug())
    |> validate_required([:organization_id, :slug])
    |> unique_constraint(:slug)
  end

  defp validate_forward_urls_required(changeset) do
    urls = get_field(changeset, :forward_urls) || []

    cond do
      urls == [] ->
        add_error(changeset, :forward_urls, "can't be blank")

      length(urls) > 10 ->
        add_error(changeset, :forward_urls, "can't have more than 10 URLs")

      true ->
        changeset
    end
  end

  defp validate_forward_urls(changeset) do
    validate_change(changeset, :forward_urls, fn :forward_urls, urls ->
      urls
      |> Enum.with_index()
      |> Enum.flat_map(fn {url, _idx} ->
        case URI.parse(url) do
          %URI{scheme: scheme, host: host}
          when scheme in ["http", "https"] and not is_nil(host) ->
            []

          _ ->
            [{:forward_urls, "contains an invalid URL: #{url}"}]
        end
      end)
    end)
  end

  defp validate_optional_url(changeset, field) do
    validate_change(changeset, field, fn _, url ->
      if url == "" or is_nil(url) do
        []
      else
        case URI.parse(url) do
          %URI{scheme: scheme, host: host}
          when scheme in ["http", "https"] and not is_nil(host) ->
            []

          _ ->
            [{field, "must be a valid HTTP or HTTPS URL"}]
        end
      end
    end)
  end

  defp generate_slug do
    "ep_" <> (:crypto.strong_rand_bytes(24) |> Base.url_encode64() |> binary_part(0, 32))
  end
end
