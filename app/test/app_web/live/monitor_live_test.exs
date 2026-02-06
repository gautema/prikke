defmodule PrikkeWeb.MonitorLiveTest do
  use PrikkeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Prikke.AccountsFixtures
  import Prikke.MonitorsFixtures

  describe "Monitor Index" do
    setup :register_and_log_in_user

    test "renders monitor list page", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      monitor = monitor_fixture(org, %{name: "Nightly Backup"})

      {:ok, _view, html} = live(conn, ~p"/monitors")

      assert html =~ "Monitors"
      assert html =~ monitor.name
    end

    test "shows empty state when no monitors", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, _view, html} = live(conn, ~p"/monitors")

      assert html =~ "No monitors yet"
    end
  end

  describe "Monitor Show" do
    setup :register_and_log_in_user

    test "renders monitor details", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      monitor = monitor_fixture(org, %{name: "Heartbeat Check"})

      {:ok, _view, html} = live(conn, ~p"/monitors/#{monitor.id}")

      assert html =~ "Heartbeat Check"
      assert html =~ monitor.ping_token
      assert html =~ "Ping URL"
      assert html =~ "curl"
    end

    test "shows actions menu", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      monitor = monitor_fixture(org)

      {:ok, view, _html} = live(conn, ~p"/monitors/#{monitor.id}")

      html = view |> element("#monitor-actions-menu button") |> render_click()

      assert html =~ "Edit"
      assert html =~ "Delete"
    end
  end

  describe "Monitor New" do
    setup :register_and_log_in_user

    test "renders new monitor form", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, _view, html} = live(conn, ~p"/monitors/new")

      assert html =~ "Create New Monitor"
      assert html =~ "Create Monitor"
    end

    test "creates monitor and redirects to show", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, view, _html} = live(conn, ~p"/monitors/new")

      view
      |> form("#monitor-form",
        monitor: %{
          name: "My Monitor",
          schedule_type: "interval",
          interval_seconds: "3600",
          grace_period_seconds: "300"
        }
      )
      |> render_submit()

      {path, flash} = assert_redirect(view)
      assert path =~ "/monitors/"
      assert flash["info"] =~ "created"
    end
  end

  describe "Monitor Edit" do
    setup :register_and_log_in_user

    test "renders edit form", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      monitor = monitor_fixture(org, %{name: "Original Name"})

      {:ok, _view, html} = live(conn, ~p"/monitors/#{monitor.id}/edit")

      assert html =~ "Edit Monitor"
      assert html =~ "Original Name"
      assert html =~ "Save Changes"
    end
  end
end
