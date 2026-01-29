defmodule Prikke.Status.StatusCheck do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Prikke.UUID7, autogenerate: true}
  schema "status_checks" do
    field :component, :string
    field :status, :string, default: "up"
    field :message, :string
    field :started_at, :utc_datetime
    field :last_checked_at, :utc_datetime
    field :last_status_change_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @components ~w(scheduler workers api)
  @statuses ~w(up down degraded)

  def changeset(check, attrs) do
    check
    |> cast(attrs, [
      :component,
      :status,
      :message,
      :started_at,
      :last_checked_at,
      :last_status_change_at
    ])
    |> validate_required([:component, :status, :started_at, :last_checked_at])
    |> validate_inclusion(:component, @components)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:component)
  end

  def update_changeset(check, attrs) do
    check
    |> cast(attrs, [:status, :message, :last_checked_at, :last_status_change_at])
    |> validate_required([:status, :last_checked_at])
    |> validate_inclusion(:status, @statuses)
  end
end
