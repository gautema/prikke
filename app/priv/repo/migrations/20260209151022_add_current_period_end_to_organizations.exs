defmodule Prikke.Repo.Migrations.AddCurrentPeriodEndToOrganizations do
  use Ecto.Migration

  def change do
    alter table(:organizations) do
      add :current_period_end, :utc_datetime
    end
  end
end
