defmodule Prikke.Analytics.Pageview do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Prikke.UUID7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "pageviews" do
    field :path, :string
    field :session_id, :string
    field :referrer, :string
    field :user_agent, :string
    field :ip_hash, :string

    belongs_to :user, Prikke.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(pageview, attrs) do
    pageview
    |> cast(attrs, [:path, :user_id, :session_id, :referrer, :user_agent, :ip_hash])
    |> validate_required([:path, :session_id])
    |> validate_length(:path, max: 2048)
    |> validate_length(:referrer, max: 2048)
    |> validate_length(:user_agent, max: 1024)
  end
end
