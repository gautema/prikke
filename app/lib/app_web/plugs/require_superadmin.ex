defmodule PrikkeWeb.Plugs.RequireSuperadmin do
  @moduledoc """
  Plug that requires the current user to be a superadmin.

  Redirects to dashboard with an error if:
  - User is not authenticated
  - User is not a superadmin
  """
  use PrikkeWeb, :verified_routes
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    user = conn.assigns[:current_scope] && conn.assigns.current_scope.user

    cond do
      is_nil(user) ->
        conn
        |> put_flash(:error, "You must log in to access this page.")
        |> redirect(to: ~p"/users/log-in")
        |> halt()

      user.is_superadmin ->
        conn

      true ->
        conn
        |> put_flash(:error, "You don't have permission to access this page.")
        |> redirect(to: ~p"/dashboard")
        |> halt()
    end
  end
end
