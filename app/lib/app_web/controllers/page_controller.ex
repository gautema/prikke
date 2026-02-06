defmodule PrikkeWeb.PageController do
  use PrikkeWeb, :controller

  plug :put_layout, false when action in [:home, :presentation]

  def home(conn, params) do
    if conn.assigns[:current_scope] && params["preview"] != "true" do
      # Logged in: redirect to LiveView dashboard
      redirect(conn, to: ~p"/dashboard")
    else
      # Not logged in (or preview mode): show landing page
      conn
      |> assign(:hide_header, true)
      |> assign(:hide_footer, true)
      |> assign(:page_title, "Simple Cron & Job Scheduling")
      |> assign(
        :page_description,
        "Schedule HTTP webhooks, cron jobs, and one-time tasks. EU-hosted, GDPR-native. Monitor executions, automatic retries, failure notifications."
      )
      |> assign(
        :current_scope,
        if(params["preview"] == "true", do: nil, else: conn.assigns[:current_scope])
      )
      |> render(:home)
    end
  end

  def terms(conn, _params) do
    conn
    |> assign(:page_title, "Terms of Service")
    |> assign(:page_description, "Terms of Service for Runlater job scheduling service.")
    |> render(:terms)
  end

  def privacy(conn, _params) do
    conn
    |> assign(:page_title, "Privacy Policy")
    |> assign(:page_description, "Privacy Policy for Runlater. EU-hosted, GDPR-compliant job scheduling.")
    |> render(:privacy)
  end

  def presentation(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, Application.app_dir(:app, "priv/static/presentation.html"))
  end
end
