defmodule PrikkeWeb.BadgeController do
  use PrikkeWeb, :controller

  alias Prikke.Badges
  alias Prikke.Tasks
  alias Prikke.Monitors
  alias Prikke.Endpoints
  alias Prikke.Executions

  @cache_max_age 60

  # -- Task badges --

  def task_status(conn, %{"token" => token}) do
    case Tasks.get_task_by_badge_token(token) do
      nil -> send_not_found_badge(conn)
      task -> send_svg(conn, Badges.task_status_badge(task))
    end
  end

  def task_uptime(conn, %{"token" => token}) do
    case Tasks.get_task_by_badge_token(token) do
      nil ->
        send_not_found_badge(conn)

      task ->
        executions = Executions.list_task_executions(task, limit: 50)
        send_svg(conn, Badges.task_uptime_bars(task, Enum.reverse(executions), name: task.name))
    end
  end

  # -- Monitor badges --

  def monitor_status(conn, %{"token" => token}) do
    case Monitors.get_monitor_by_badge_token(token) do
      nil -> send_not_found_badge(conn)
      monitor -> send_svg(conn, Badges.monitor_status_badge(monitor))
    end
  end

  def monitor_uptime(conn, %{"token" => token}) do
    case Monitors.get_monitor_by_badge_token(token) do
      nil ->
        send_not_found_badge(conn)

      monitor ->
        daily_status = Monitors.get_daily_status([monitor], 30)
        days = Map.get(daily_status, monitor.id, [])
        send_svg(conn, Badges.monitor_uptime_bars(monitor, days, name: monitor.name))
    end
  end

  # -- Endpoint badges --

  def endpoint_status(conn, %{"token" => token}) do
    case Endpoints.get_endpoint_by_badge_token(token) do
      nil ->
        send_not_found_badge(conn)

      endpoint ->
        last_status = Endpoints.get_last_event_status(endpoint)
        send_svg(conn, Badges.endpoint_status_badge(endpoint, last_status))
    end
  end

  def endpoint_uptime(conn, %{"token" => token}) do
    case Endpoints.get_endpoint_by_badge_token(token) do
      nil ->
        send_not_found_badge(conn)

      endpoint ->
        last_status = Endpoints.get_last_event_status(endpoint)
        events = Endpoints.list_inbound_events(endpoint, limit: 50)

        statuses =
          events
          |> Enum.reverse()
          |> Enum.map(fn event ->
            if event.execution, do: event.execution.status, else: "pending"
          end)

        send_svg(conn, Badges.endpoint_uptime_bars(endpoint, statuses, last_status))
    end
  end

  # -- Helpers --

  defp send_svg(conn, svg) do
    conn
    |> put_resp_header("content-type", "image/svg+xml; charset=utf-8")
    |> put_resp_header("cache-control", "public, max-age=#{@cache_max_age}, s-maxage=#{@cache_max_age}")
    |> send_resp(200, svg)
  end

  defp send_not_found_badge(conn) do
    svg = Badges.flat_badge("badge", "not found", "#94a3b8")

    conn
    |> put_resp_header("content-type", "image/svg+xml; charset=utf-8")
    |> put_resp_header("cache-control", "no-cache")
    |> send_resp(404, svg)
  end
end
