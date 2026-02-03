defmodule PrikkeWeb.PageController do
  use PrikkeWeb, :controller

  plug :put_layout, false when action in [:home]

  def home(conn, params) do
    if conn.assigns[:current_scope] && params["preview"] != "true" do
      # Logged in: redirect to LiveView dashboard
      redirect(conn, to: ~p"/dashboard")
    else
      # Not logged in (or preview mode): show landing page
      conn
      |> assign(:hide_header, true)
      |> assign(:hide_footer, true)
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
    |> render(:terms)
  end

  def privacy(conn, _params) do
    conn
    |> assign(:page_title, "Privacy Policy")
    |> render(:privacy)
  end
end
