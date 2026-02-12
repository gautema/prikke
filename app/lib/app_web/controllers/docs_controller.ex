defmodule PrikkeWeb.DocsController do
  use PrikkeWeb, :controller

  plug :put_layout, false
  plug :assign_hide_header

  defp assign_hide_header(conn, _opts) do
    conn
    |> assign(:hide_header, true)
    |> assign(:hide_footer, true)
  end

  def index(conn, _params) do
    render(conn, :index, page_title: "Documentation")
  end

  def getting_started(conn, _params) do
    render(conn, :getting_started, page_title: "Getting Started")
  end

  def api(conn, _params) do
    render(conn, :api, page_title: "API Reference")
  end

  def cron(conn, _params) do
    render(conn, :cron, page_title: "Cron Syntax")
  end

  def webhooks(conn, _params) do
    render(conn, :webhooks, page_title: "Webhooks")
  end

  def monitors(conn, _params) do
    render(conn, :monitors, page_title: "Cron Monitoring")
  end

  def use_cases(conn, _params) do
    render(conn, :use_cases, page_title: "Use Cases")
  end

  def endpoints(conn, _params) do
    render(conn, :endpoints, page_title: "Inbound Endpoints")
  end

  def badges(conn, _params) do
    render(conn, :badges, page_title: "Status Badges")
  end
end
