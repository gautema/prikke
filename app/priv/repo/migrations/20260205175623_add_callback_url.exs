defmodule Prikke.Repo.Migrations.AddCallbackUrl do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :callback_url, :string
    end

    alter table(:executions) do
      add :callback_url, :string
    end
  end
end
