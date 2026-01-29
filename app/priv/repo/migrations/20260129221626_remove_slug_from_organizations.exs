defmodule Prikke.Repo.Migrations.RemoveSlugFromOrganizations do
  use Ecto.Migration

  def change do
    alter table(:organizations) do
      remove :slug, :string
    end
  end
end
