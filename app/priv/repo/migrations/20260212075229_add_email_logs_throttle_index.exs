defmodule Prikke.Repo.Migrations.AddEmailLogsThrottleIndex do
  use Ecto.Migration

  def change do
    create index(:email_logs, [:organization_id, :email_type, :inserted_at],
             where: "status = 'sent'",
             name: :email_logs_throttle_idx
           )
  end
end
