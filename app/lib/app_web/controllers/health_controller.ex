defmodule PrikkeWeb.HealthController do
  use PrikkeWeb, :controller

  def check(conn, _params) do
    # Check database connectivity
    case Ecto.Adapters.SQL.query(Prikke.Repo, "SELECT 1", []) do
      {:ok, _} ->
        conn
        |> put_status(:ok)
        |> json(%{status: "ok", database: "connected"})

      {:error, _} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "error", database: "disconnected"})
    end
  end
end
