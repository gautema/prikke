defmodule PrikkeWeb.PingController do
  use PrikkeWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Prikke.Monitors
  alias PrikkeWeb.Schemas

  tags(["Ping"])

  operation(:ping,
    summary: "Record a ping",
    description: """
    Record a heartbeat ping for a monitor. No API key required — the token in the URL
    is the authentication. Accepts both GET and POST requests.
    """,
    parameters: [
      token: [
        in: :path,
        type: :string,
        description: "Monitor ping token (pm_xxx)",
        required: true
      ]
    ],
    responses: [
      ok: {"Ping recorded", "application/json", Schemas.PingResponse},
      not_found: {"Invalid token", "application/json", Schemas.ErrorResponse},
      gone: {"Monitor disabled", "application/json", Schemas.ErrorResponse}
    ]
  )

  def ping(conn, %{"token" => token}) do
    case Monitors.record_ping!(token) do
      {:ok, monitor} ->
        conn
        |> put_status(:ok)
        |> json(%{status: "ok", monitor: monitor.name})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Monitor not found"})

      {:error, :disabled} ->
        conn
        |> put_status(:gone)
        |> json(%{error: "Monitor is disabled"})
    end
  end
end
