defmodule Prikke.Repo do
  use Ecto.Repo,
    otp_app: :app,
    adapter: Ecto.Adapters.Postgres

  @doc """
  Use UUIDs as primary keys by default.
  """
  @impl true
  def default_options(_operation) do
    [primary_key: :uuid]
  end
end
