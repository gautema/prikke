defmodule PrikkeWeb.BadgeController do
  use PrikkeWeb, :controller
  import Ecto.Query, warn: false

  alias Prikke.Badges
  alias Prikke.StatusPages
  alias Prikke.Monitors
  alias Prikke.Endpoints
  alias Prikke.Executions

  @cache_max_age 60

  # -- Task badges --

  def task_status(conn, %{"token" => token}) do
    with_resource(conn, token, "task", fn task ->
      send_svg(conn, Badges.task_status_badge(task))
    end)
  end

  def task_uptime(conn, %{"token" => token}) do
    with_resource(conn, token, "task", fn task ->
      executions = Executions.list_task_executions(task, limit: 50)
      send_svg(conn, Badges.task_uptime_bars(task, Enum.reverse(executions), name: task.name))
    end)
  end

  # -- Monitor badges --

  def monitor_status(conn, %{"token" => token}) do
    with_resource(conn, token, "monitor", fn monitor ->
      send_svg(conn, Badges.monitor_status_badge(monitor))
    end)
  end

  def monitor_uptime(conn, %{"token" => token}) do
    with_resource(conn, token, "monitor", fn monitor ->
      daily_status = Monitors.get_daily_status([monitor], 30)
      days = Map.get(daily_status, monitor.id, [])
      send_svg(conn, Badges.monitor_uptime_bars(monitor, days, name: monitor.name))
    end)
  end

  # -- Endpoint badges --

  def endpoint_status(conn, %{"token" => token}) do
    with_resource(conn, token, "endpoint", fn endpoint ->
      last_status = Endpoints.get_last_event_status(endpoint)
      send_svg(conn, Badges.endpoint_status_badge(endpoint, last_status))
    end)
  end

  def endpoint_uptime(conn, %{"token" => token}) do
    with_resource(conn, token, "endpoint", fn endpoint ->
      last_status = Endpoints.get_last_event_status(endpoint)
      events = Endpoints.list_inbound_events(endpoint, limit: 50)

      statuses =
        events
        |> Enum.reverse()
        |> Enum.map(fn event ->
          if event.execution, do: event.execution.status, else: "pending"
        end)

      send_svg(conn, Badges.endpoint_uptime_bars(endpoint, statuses, last_status))
    end)
  end

  # -- Queue badges --

  def queue_status(conn, %{"token" => token}) do
    with_resource(conn, token, "queue", fn queue ->
      last_status = Executions.get_last_queue_status(queue.organization_id, queue.name)
      send_svg(conn, Badges.queue_status_badge(queue.name, last_status))
    end)
  end

  def queue_uptime(conn, %{"token" => token}) do
    with_resource(conn, token, "queue", fn queue ->
      last_status = Executions.get_last_queue_status(queue.organization_id, queue.name)
      daily_status = Executions.get_daily_status_for_queue(queue.organization_id, queue.name, 30)
      send_svg(conn, Badges.queue_uptime_bars(queue.name, daily_status, last_status))
    end)
  end

  # -- Helpers --

  defp with_resource(conn, token, expected_type, fun) do
    case StatusPages.get_item_by_badge_token(token) do
      nil ->
        send_not_found_badge(conn)

      %{resource_type: ^expected_type, resource_id: resource_id} ->
        case load_resource(expected_type, resource_id) do
          nil -> send_not_found_badge(conn)
          resource -> fun.(resource)
        end

      _wrong_type ->
        send_not_found_badge(conn)
    end
  end

  defp load_resource("task", id) do
    Prikke.Repo.one(
      from t in Prikke.Tasks.Task, where: t.id == ^id and is_nil(t.deleted_at)
    )
  end

  defp load_resource("monitor", id) do
    Prikke.Repo.get(Prikke.Monitors.Monitor, id)
  end

  defp load_resource("endpoint", id) do
    Prikke.Repo.get(Prikke.Endpoints.Endpoint, id)
  end

  defp load_resource("queue", id) do
    Prikke.Repo.get(Prikke.Queues.Queue, id)
  end

  defp send_svg(conn, svg) do
    conn
    |> put_resp_header("content-type", "image/svg+xml; charset=utf-8")
    |> put_resp_header(
      "cache-control",
      "public, max-age=#{@cache_max_age}, s-maxage=#{@cache_max_age}"
    )
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
