defmodule Prikke.Repo.Migrations.AddDescriptionToStatusPages do
  use Ecto.Migration

  def change do
    alter table(:status_pages) do
      add :description, :string
    end
  end
end
