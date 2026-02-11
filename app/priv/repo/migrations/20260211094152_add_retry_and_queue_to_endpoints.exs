defmodule Prikke.Repo.Migrations.AddRetryAndQueueToEndpoints do
  use Ecto.Migration

  def change do
    alter table(:endpoints) do
      add :retry_attempts, :integer, default: 5, null: false
      add :use_queue, :boolean, default: true, null: false
    end
  end
end
