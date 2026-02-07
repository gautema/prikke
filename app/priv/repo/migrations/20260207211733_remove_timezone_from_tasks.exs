defmodule Prikke.Repo.Migrations.RemoveTimezoneFromTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      remove :timezone, :string, default: "UTC"
    end
  end
end
