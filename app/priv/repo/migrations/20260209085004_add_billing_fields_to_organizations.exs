defmodule Prikke.Repo.Migrations.AddBillingFieldsToOrganizations do
  use Ecto.Migration

  def change do
    alter table(:organizations) do
      add :creem_customer_id, :string
      add :creem_subscription_id, :string
      add :subscription_status, :string
    end

    create index(:organizations, [:creem_customer_id])
    create unique_index(:organizations, [:creem_subscription_id])
  end
end
