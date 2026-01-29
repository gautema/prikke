defmodule Prikke.Repo.Migrations.CreateOrganizationInvites do
  use Ecto.Migration

  def change do
    create table(:organization_invites, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :token, :binary, null: false
      add :role, :string, null: false, default: "member"
      add :accepted_at, :utc_datetime

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :invited_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:organization_invites, [:organization_id])
    create unique_index(:organization_invites, [:token])

    create unique_index(:organization_invites, [:organization_id, :email],
             where: "accepted_at IS NULL"
           )
  end
end
