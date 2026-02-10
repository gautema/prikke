defmodule Prikke.Repo.Migrations.CreateEndpointsAndInboundEvents do
  use Ecto.Migration

  def change do
    create table(:endpoints, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :slug, :string, null: false
      add :forward_url, :string, null: false
      add :enabled, :boolean, default: true, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:endpoints, [:slug])
    create index(:endpoints, [:organization_id])

    create table(:inbound_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :endpoint_id, references(:endpoints, type: :binary_id, on_delete: :delete_all),
        null: false

      add :method, :string, null: false
      add :headers, :map, default: %{}
      add :body, :text
      add :source_ip, :string
      add :execution_id, references(:executions, type: :binary_id, on_delete: :nilify_all)
      add :received_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:inbound_events, [:endpoint_id, :received_at])
  end
end
