defmodule PrikkeWeb.StatusLiveTest do
  use PrikkeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Prikke.AccountsFixtures
  import Prikke.TasksFixtures
  import Prikke.MonitorsFixtures
  import Prikke.EndpointsFixtures

  describe "Status Page Management" do
    setup :register_and_log_in_user

    test "renders status page settings", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, _view, html} = live(conn, ~p"/status-page")

      assert html =~ "Status Page"
      assert html =~ "Settings"
      assert html =~ "Page Title"
      assert html =~ "URL Slug"
    end

    test "auto-creates status page on first visit", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})

      {:ok, _view, html} = live(conn, ~p"/status-page")

      assert html =~ org.name
    end

    test "shows resources section with tasks", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      _task = task_fixture(org, %{name: "My Cron Task"})
      _once_task = once_task_fixture(org, %{name: "One-Time Task"})

      {:ok, _view, html} = live(conn, ~p"/status-page")

      assert html =~ "My Cron Task"
      assert html =~ "Resources"
    end

    test "shows resources section with monitors", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      _monitor = monitor_fixture(org, %{name: "My Monitor"})

      {:ok, _view, html} = live(conn, ~p"/status-page")

      assert html =~ "My Monitor"
    end

    test "shows resources section with endpoints", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      _endpoint = endpoint_fixture(org, %{name: "My Endpoint"})

      {:ok, _view, html} = live(conn, ~p"/status-page")

      assert html =~ "My Endpoint"
    end

    test "can toggle badge on a task", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      task = task_fixture(org, %{name: "Toggle Task"})

      {:ok, view, _html} = live(conn, ~p"/status-page")

      # Enable badge
      html =
        view
        |> element(
          ~s{button[phx-click="enable_badge"][phx-value-type="task"][phx-value-id="#{task.id}"]}
        )
        |> render_click()

      assert html =~ "Visible"

      # Reload task to verify
      updated_task = Prikke.Tasks.get_task!(org, task.id)
      assert updated_task.badge_token != nil
    end

    test "can toggle badge on a monitor", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      monitor = monitor_fixture(org, %{name: "Toggle Monitor"})

      {:ok, view, _html} = live(conn, ~p"/status-page")

      html =
        view
        |> element(
          ~s{button[phx-click="enable_badge"][phx-value-type="monitor"][phx-value-id="#{monitor.id}"]}
        )
        |> render_click()

      assert html =~ "Visible"
    end

    test "can save settings", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, view, _html} = live(conn, ~p"/status-page")

      html =
        view
        |> form("#status-page-form", status_page: %{title: "My Status", slug: "my-status"})
        |> render_submit()

      assert html =~ "Status page updated"
    end

    test "shows embed codes when badges are enabled", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      task = task_fixture(org, %{name: "Badged Task"})
      {:ok, _} = Prikke.Tasks.enable_badge(org, task)

      {:ok, _view, html} = live(conn, ~p"/status-page")

      assert html =~ "Badge Embed Codes"
      assert html =~ "Badged Task"
    end

    test "shows empty state when no resources", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, _view, html} = live(conn, ~p"/status-page")

      assert html =~ "No resources yet"
    end
  end
end
