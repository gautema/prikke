defmodule Prikke.Repo.Migrations.AddNotifyOnRecoveryToOrganizations do
  use Ecto.Migration

  def change do
    alter table(:organizations) do
      add :notify_on_recovery, :boolean, default: true, null: false
    end
  end
end
