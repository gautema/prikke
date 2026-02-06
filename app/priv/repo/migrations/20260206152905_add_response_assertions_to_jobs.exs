defmodule Prikke.Repo.Migrations.AddResponseAssertionsToJobs do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :expected_status_codes, :text
      add :expected_body_pattern, :text
    end
  end
end
