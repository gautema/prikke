{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:argon2_elixir)
{:ok, _} = Prikke.Repo.start_link([pool_size: 2])

import Ecto.Query

# Get or create user
user = case Prikke.Repo.get_by(Prikke.Accounts.User, email: "loadtest@runlater.eu") do
  nil ->
    {:ok, user} = Prikke.Accounts.register_user(%{email: "loadtest@runlater.eu", password: "LoadTest2026Pass1"})
    user
  existing -> existing
end

now = DateTime.utc_now() |> DateTime.truncate(:second)
user = user |> Ecto.Changeset.change(%{confirmed_at: now}) |> Prikke.Repo.update!()

# Get or create organization
membership = Prikke.Repo.one(from m in Prikke.Accounts.Membership, where: m.user_id == ^user.id, limit: 1)

org = if membership do
  Prikke.Repo.get!(Prikke.Accounts.Organization, membership.organization_id)
else
  {:ok, org} = Prikke.Accounts.create_organization(user, %{name: "Load Test Org"})
  org
end

org |> Ecto.Changeset.change(%{tier: "pro"}) |> Prikke.Repo.update!()

# Create new API key (delete old one if exists)
old_key = Prikke.Repo.one(from k in Prikke.Accounts.ApiKey, where: k.organization_id == ^org.id and k.name == "loadtest-key", limit: 1)
if old_key, do: Prikke.Repo.delete!(old_key)

{:ok, api_key, raw_secret} = Prikke.Accounts.create_api_key(org, user, %{name: "loadtest-key"})
IO.puts("API_KEY: #{api_key.key_id}.#{raw_secret}")
IO.puts("ORG_ID: #{org.id}")
IO.puts("USER_ID: #{user.id}")
