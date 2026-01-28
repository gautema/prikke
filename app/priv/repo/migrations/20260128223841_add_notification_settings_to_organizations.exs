defmodule Prikke.Repo.Migrations.AddNotificationSettingsToOrganizations do
  use Ecto.Migration

  def change do
    alter table(:organizations) do
      add :notify_on_failure, :boolean, default: true, null: false
      add :notification_email, :string
      add :notification_webhook_url, :string
    end
  end
end
