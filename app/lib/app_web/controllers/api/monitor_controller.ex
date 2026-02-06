defmodule PrikkeWeb.Api.MonitorController do
  use PrikkeWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Prikke.Monitors
  alias Prikke.Monitors.Monitor
  alias PrikkeWeb.Schemas

  action_fallback PrikkeWeb.Api.FallbackController

  tags(["Monitors"])
  security([%{"bearerAuth" => []}])

  operation(:index,
    summary: "List all monitors",
    description: "Returns all monitors for the authenticated organization",
    responses: [
      ok: {"Monitors list", "application/json", Schemas.MonitorsResponse},
      unauthorized: {"Unauthorized", "application/json", Schemas.ErrorResponse}
    ]
  )

  def index(conn, _params) do
    org = conn.assigns.current_organization
    monitors = Monitors.list_monitors(org)
    json(conn, %{data: Enum.map(monitors, &monitor_json(conn, &1))})
  end

  operation(:show,
    summary: "Get a monitor",
    description: "Returns a single monitor by ID",
    parameters: [
      id: [in: :path, type: :string, description: "Monitor ID", required: true]
    ],
    responses: [
      ok: {"Monitor", "application/json", Schemas.MonitorResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]
  )

  def show(conn, %{"id" => id}) do
    org = conn.assigns.current_organization

    case Monitors.get_monitor(org, id) do
      nil -> {:error, :not_found}
      monitor -> json(conn, %{data: monitor_json(conn, monitor)})
    end
  end

  operation(:create,
    summary: "Create a monitor",
    description: "Creates a new heartbeat monitor",
    request_body: {"Monitor parameters", "application/json", Schemas.MonitorRequest},
    responses: [
      created: {"Monitor created", "application/json", Schemas.MonitorResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ErrorResponse}
    ]
  )

  def create(conn, %{"monitor" => monitor_params}) do
    org = conn.assigns.current_organization

    case Monitors.create_monitor(org, monitor_params) do
      {:ok, monitor} ->
        conn
        |> put_status(:created)
        |> json(%{data: monitor_json(conn, monitor)})

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def create(conn, params) do
    create(conn, %{"monitor" => params})
  end

  operation(:update,
    summary: "Update a monitor",
    description: "Updates an existing monitor",
    parameters: [
      id: [in: :path, type: :string, description: "Monitor ID", required: true]
    ],
    request_body: {"Monitor parameters", "application/json", Schemas.MonitorRequest},
    responses: [
      ok: {"Monitor updated", "application/json", Schemas.MonitorResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ErrorResponse}
    ]
  )

  def update(conn, %{"id" => id, "monitor" => monitor_params}) do
    org = conn.assigns.current_organization

    case Monitors.get_monitor(org, id) do
      nil ->
        {:error, :not_found}

      monitor ->
        case Monitors.update_monitor(org, monitor, monitor_params) do
          {:ok, monitor} -> json(conn, %{data: monitor_json(conn, monitor)})
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  def update(conn, %{"id" => id} = params) do
    monitor_params = Map.drop(params, ["id"])
    update(conn, %{"id" => id, "monitor" => monitor_params})
  end

  operation(:delete,
    summary: "Delete a monitor",
    description: "Deletes a monitor and all its ping history",
    parameters: [
      id: [in: :path, type: :string, description: "Monitor ID", required: true]
    ],
    responses: [
      no_content: "Monitor deleted",
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]
  )

  def delete(conn, %{"id" => id}) do
    org = conn.assigns.current_organization

    case Monitors.get_monitor(org, id) do
      nil ->
        {:error, :not_found}

      monitor ->
        case Monitors.delete_monitor(org, monitor) do
          {:ok, _monitor} -> send_resp(conn, :no_content, "")
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  operation(:pings,
    summary: "List recent pings",
    description: "Returns the recent ping history for a monitor",
    parameters: [
      monitor_id: [in: :path, type: :string, description: "Monitor ID", required: true],
      limit: [in: :query, type: :integer, description: "Maximum results (1-100, default 50)"]
    ],
    responses: [
      ok: {"Pings", "application/json", Schemas.MonitorPingsResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]
  )

  def pings(conn, params) do
    org = conn.assigns.current_organization
    id = params["id"] || params["monitor_id"]
    limit = parse_limit(params["limit"], 50)

    case Monitors.get_monitor(org, id) do
      nil ->
        {:error, :not_found}

      monitor ->
        pings = Monitors.list_recent_pings(monitor, limit: limit)
        json(conn, %{data: Enum.map(pings, &ping_json/1)})
    end
  end

  # JSON serialization helpers

  defp monitor_json(conn, %Monitor{} = m) do
    host = conn.host || "runlater.eu"

    %{
      id: m.id,
      name: m.name,
      ping_token: m.ping_token,
      ping_url: "https://#{host}/ping/#{m.ping_token}",
      schedule_type: m.schedule_type,
      cron_expression: m.cron_expression,
      interval_seconds: m.interval_seconds,
      grace_period_seconds: m.grace_period_seconds,
      status: m.status,
      enabled: m.enabled,
      last_ping_at: m.last_ping_at,
      next_expected_at: m.next_expected_at,
      inserted_at: m.inserted_at,
      updated_at: m.updated_at
    }
  end

  defp ping_json(ping) do
    %{
      id: ping.id,
      received_at: ping.received_at
    }
  end

  defp parse_limit(nil, default), do: default

  defp parse_limit(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} when n > 0 and n <= 100 -> n
      _ -> default
    end
  end

  defp parse_limit(_, default), do: default
end
