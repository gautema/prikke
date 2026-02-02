defmodule Prikke.Repo.Migrations.AddLimitNotificationFieldsToOrganizations do
  use Ecto.Migration

  def change do
    alter table(:organizations) do
      # Track when we last sent limit notifications to avoid spamming
      # These reset monthly (we check if in current month before sending)
      add :limit_warning_sent_at, :utc_datetime
      add :limit_reached_sent_at, :utc_datetime
    end
  end
end
