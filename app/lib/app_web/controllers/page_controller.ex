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
      |> render(:home)
    end
  end
end
