defmodule Prikke.Repo.Migrations.AddEndpointForwardMethod do
  use Ecto.Migration

  def change do
    alter table(:endpoints) do
      add :forward_method, :string
    end
  end
end
