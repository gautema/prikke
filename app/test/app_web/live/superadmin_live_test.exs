defmodule PrikkeWeb.SuperadminLiveTest do
  use PrikkeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Prikke.AccountsFixtures
  import Prikke.JobsFixtures

  describe "SuperadminLive" do
    setup do
      superadmin = superadmin_fixture()
      regular_user = user_fixture()
      org = organization_fixture(%{user: superadmin})

      %{superadmin: superadmin, regular_user: regular_user, org: org}
    end

    test "superadmin can access the dashboard", %{conn: conn, superadmin: superadmin} do
      {:ok, _view, html} =
        conn
        |> log_in_user(superadmin)
        |> live(~p"/superadmin")

      assert html =~ "Superadmin Dashboard"
      assert html =~ "Total Users"
      assert html =~ "Organizations"
      assert html =~ "Total Jobs"
      assert html =~ "Execution Stats"
    end

    test "regular user cannot access superadmin dashboard", %{
      conn: conn,
      regular_user: regular_user
    } do
      conn =
        conn
        |> log_in_user(regular_user)
        |> get(~p"/superadmin")

      assert redirected_to(conn) == ~p"/dashboard"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "permission"
    end

    test "unauthenticated user cannot access superadmin dashboard", %{conn: conn} do
      conn = get(conn, ~p"/superadmin")

      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "displays platform stats", %{conn: conn, superadmin: superadmin, org: org} do
      # Create a job to have some data
      job_fixture(org)

      {:ok, _view, html} =
        conn
        |> log_in_user(superadmin)
        |> live(~p"/superadmin")

      assert html =~ "Total Users"
      assert html =~ "Organizations"
      assert html =~ "Total Jobs"
    end

    test "displays recent signups section", %{conn: conn, superadmin: superadmin} do
      {:ok, _view, html} =
        conn
        |> log_in_user(superadmin)
        |> live(~p"/superadmin")

      assert html =~ "Recent Signups"
    end

    test "displays recent jobs section", %{conn: conn, superadmin: superadmin} do
      {:ok, _view, html} =
        conn
        |> log_in_user(superadmin)
        |> live(~p"/superadmin")

      assert html =~ "Recent Jobs"
    end

    test "displays pageviews section", %{conn: conn, superadmin: superadmin} do
      {:ok, _view, html} =
        conn
        |> log_in_user(superadmin)
        |> live(~p"/superadmin")

      assert html =~ "Pageviews"
      assert html =~ "Top Pages"
    end

    test "displays system performance section", %{conn: conn, superadmin: superadmin} do
      {:ok, _view, html} =
        conn
        |> log_in_user(superadmin)
        |> live(~p"/superadmin")

      assert html =~ "System Performance"
      assert html =~ "Queue Depth"
      assert html =~ "Active Workers"
      assert html =~ "CPU Usage"
      assert html =~ "Memory Usage"
      assert html =~ "Response Times"
    end
  end
end
