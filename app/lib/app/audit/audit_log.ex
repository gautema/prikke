defmodule Prikke.Audit.AuditLog do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Prikke.UUID7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "audit_logs" do
    field :actor_type, :string
    field :action, :string
    field :resource_type, :string
    field :resource_id, :binary_id
    field :changes, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :actor, Prikke.Accounts.User
    belongs_to :organization, Prikke.Accounts.Organization

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @actor_types ~w(user system api)
  @actions ~w(created updated deleted enabled disabled triggered retried upgraded downgraded invited removed role_changed api_key_created api_key_deleted)
  @resource_types ~w(organization job execution membership invite api_key)

  @doc false
  def changeset(audit_log, attrs) do
    audit_log
    |> cast(attrs, [
      :actor_id,
      :actor_type,
      :action,
      :resource_type,
      :resource_id,
      :organization_id,
      :changes,
      :metadata
    ])
    |> validate_required([:actor_type, :action, :resource_type, :resource_id])
    |> validate_inclusion(:actor_type, @actor_types)
    |> validate_inclusion(:action, @actions)
    |> validate_inclusion(:resource_type, @resource_types)
  end
end
