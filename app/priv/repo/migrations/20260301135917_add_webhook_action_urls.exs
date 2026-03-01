defmodule Prikke.Repo.Migrations.AddWebhookActionUrls do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :on_failure_url, :text
      add :on_recovery_url, :text
    end

    alter table(:monitors) do
      add :on_failure_url, :text
      add :on_recovery_url, :text
    end

    alter table(:endpoints) do
      add :on_failure_url, :text
      add :on_recovery_url, :text
    end
  end
end
