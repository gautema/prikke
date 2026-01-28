ExUnit.start()

# Only setup Ecto sandbox when not in CI mode (database available)
unless Application.get_env(:app, :ci_mode, false) do
  Ecto.Adapters.SQL.Sandbox.mode(Prikke.Repo, :manual)
end
