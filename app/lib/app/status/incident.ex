defmodule Prikke.Status.Incident do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Prikke.UUID7, autogenerate: true}
  schema "status_incidents" do
    field :component, :string
    field :status, :string, default: "down"
    field :message, :string
    field :started_at, :utc_datetime
    field :resolved_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @components ~w(scheduler workers api)
  @statuses ~w(down degraded)

  def changeset(incident, attrs) do
    incident
    |> cast(attrs, [:component, :status, :message, :started_at, :resolved_at])
    |> validate_required([:component, :status, :started_at])
    |> validate_inclusion(:component, @components)
    |> validate_inclusion(:status, @statuses)
  end

  def resolve_changeset(incident) do
    incident
    |> change(resolved_at: DateTime.utc_now(:second))
  end
end
