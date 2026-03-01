defmodule Prikke.Repo.Migrations.AddEndpointCustomForwarding do
  use Ecto.Migration

  def change do
    alter table(:endpoints) do
      add :forward_headers, :map, default: %{}
      add :forward_body, :text
    end
  end
end
