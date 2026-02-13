defmodule PrikkeWeb.StatusController do
  use PrikkeWeb, :controller

  alias Prikke.Status
  alias Prikke.ApiMetrics

  plug :put_layout, false
  plug :assign_hide_header_footer

  defp assign_hide_header_footer(conn, _opts) do
    conn
    |> assign(:hide_header, true)
    |> assign(:hide_footer, true)
  end

  def index(conn, _params) do
    status = Status.get_current_status()
    overall = Status.overall_status()
    incidents = Status.list_recent_incidents(10)
    open_incidents = Status.list_open_incidents()
    daily_uptime = Status.get_daily_uptime(90)
    all_incidents = Status.list_all_incidents(90)
    daily_latency = ApiMetrics.list_daily_latency(90)
    today_latency = ApiMetrics.get_today_latency()

    render(conn, :index,
      status: status,
      overall: overall,
      incidents: incidents,
      open_incidents: open_incidents,
      daily_uptime: daily_uptime,
      all_incidents: all_incidents,
      daily_latency: daily_latency,
      today_latency: today_latency
    )
  end
end
