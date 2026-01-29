defmodule Prikke.Repo.Migrations.AddSuperadminToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :is_superadmin, :boolean, default: false, null: false
    end

    # Set gaute.magnussen@gmail.com as superadmin
    execute(
      "UPDATE users SET is_superadmin = true WHERE email = 'gaute.magnussen@gmail.com'",
      "UPDATE users SET is_superadmin = false WHERE email = 'gaute.magnussen@gmail.com'"
    )
  end
end
