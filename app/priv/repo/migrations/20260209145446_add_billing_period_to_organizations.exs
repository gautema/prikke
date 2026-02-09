defmodule Prikke.Repo.Migrations.AddBillingPeriodToOrganizations do
  use Ecto.Migration

  def change do
    alter table(:organizations) do
      add :billing_period, :string
    end
  end
end
