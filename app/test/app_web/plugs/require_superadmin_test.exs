defmodule PrikkeWeb.Plugs.RequireSuperadminTest do
  use PrikkeWeb.ConnCase, async: true

  alias Prikke.Accounts.Scope
  import Prikke.AccountsFixtures

  defp setup_conn(conn) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> fetch_flash()
  end

  describe "require_superadmin plug" do
    test "allows superadmin users", %{conn: conn} do
      superadmin = superadmin_fixture()

      conn =
        conn
        |> setup_conn()
        |> assign(:current_scope, Scope.for_user(superadmin))
        |> PrikkeWeb.Plugs.RequireSuperadmin.call([])

      refute conn.halted
    end

    test "redirects non-superadmin users to dashboard", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> setup_conn()
        |> assign(:current_scope, Scope.for_user(user))
        |> PrikkeWeb.Plugs.RequireSuperadmin.call([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/dashboard"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "permission"
    end

    test "redirects unauthenticated users to login", %{conn: conn} do
      conn =
        conn
        |> setup_conn()
        |> assign(:current_scope, nil)
        |> PrikkeWeb.Plugs.RequireSuperadmin.call([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "log in"
    end
  end
end
