defmodule Prikke.Repo.Migrations.AddNotificationOverridesToEndpoints do
  use Ecto.Migration

  def change do
    alter table(:endpoints) do
      add :notify_on_failure, :boolean, null: true, default: nil
      add :notify_on_recovery, :boolean, null: true, default: nil
    end
  end
end
