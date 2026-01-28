defmodule PrikkeWeb.PageController do
  use PrikkeWeb, :controller

  plug :put_layout, false when action in [:home]

  def home(conn, _params) do
    if conn.assigns[:current_scope] do
      # Logged in: redirect to LiveView dashboard
      redirect(conn, to: ~p"/dashboard")
    else
      # Not logged in: show landing page (has its own header)
      conn
      |> assign(:hide_header, true)
      |> render(:home)
    end
  end
end
