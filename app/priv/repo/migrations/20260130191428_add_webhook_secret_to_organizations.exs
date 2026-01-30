defmodule Prikke.Repo.Migrations.AddWebhookSecretToOrganizations do
  use Ecto.Migration

  def up do
    alter table(:organizations) do
      add :webhook_secret, :string
    end

    flush()

    # Backfill existing organizations with secrets using Elixir
    execute(fn ->
      repo().query!(
        "SELECT id FROM organizations WHERE webhook_secret IS NULL",
        []
      )
      |> Map.get(:rows)
      |> Enum.each(fn [id] ->
        secret = "whsec_" <> Base.encode16(:crypto.strong_rand_bytes(24), case: :lower)
        repo().query!("UPDATE organizations SET webhook_secret = $1 WHERE id = $2", [secret, id])
      end)
    end)

    # Now make it non-nullable
    alter table(:organizations) do
      modify :webhook_secret, :string, null: false
    end
  end

  def down do
    alter table(:organizations) do
      remove :webhook_secret
    end
  end
end
