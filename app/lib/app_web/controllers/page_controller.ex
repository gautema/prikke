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
      |> assign(:page_title, "Async Task Infrastructure for Europe")
      |> assign(
        :page_description,
        "Queue delayed tasks, schedule recurring jobs, and monitor everything. One API, zero infrastructure, fully GDPR-native. Retries, callbacks, webhook signatures."
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
    |> assign(
      :page_description,
      "Privacy Policy for Runlater. EU-hosted, GDPR-compliant job scheduling."
    )
    |> render(:privacy)
  end

  def dpa(conn, _params) do
    conn
    |> assign(:page_title, "Data Processing Agreement")
    |> assign(:page_description, "DPA for Runlater. GDPR Article 28 compliant data processing terms.")
    |> render(:dpa)
  end

  def slo(conn, _params) do
    conn
    |> assign(:page_title, "Service Level Objectives")
    |> assign(:page_description, "Runlater uptime targets, execution timing, and support response times.")
    |> render(:slo)
  end

  def subprocessors(conn, _params) do
    conn
    |> assign(:page_title, "Sub-processors")
    |> assign(:page_description, "List of sub-processors used by Runlater to operate the service.")
    |> render(:subprocessors)
  end

  def presentation(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, Application.app_dir(:app, "priv/static/presentation.html"))
  end
end
