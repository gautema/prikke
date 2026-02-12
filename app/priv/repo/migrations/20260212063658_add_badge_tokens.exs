defmodule Prikke.Repo.Migrations.AddBadgeTokens do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :badge_token, :string
    end

    alter table(:monitors) do
      add :badge_token, :string
    end

    alter table(:endpoints) do
      add :badge_token, :string
    end

    create unique_index(:tasks, [:badge_token], where: "badge_token IS NOT NULL")
    create unique_index(:monitors, [:badge_token], where: "badge_token IS NOT NULL")
    create unique_index(:endpoints, [:badge_token], where: "badge_token IS NOT NULL")
  end
end
