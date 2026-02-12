defmodule PrikkeWeb.PublicStatusLiveTest do
  use PrikkeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Prikke.AccountsFixtures
  import Prikke.StatusPagesFixtures
  import Prikke.TasksFixtures
  import Prikke.MonitorsFixtures
  import Prikke.EndpointsFixtures

  describe "Public Status Page" do
    test "renders enabled status page", %{conn: conn} do
      org = organization_fixture()
      _sp = status_page_fixture(org, %{title: "Acme Status", slug: "acme-status", enabled: true})

      {:ok, _view, html} = live(conn, ~p"/s/acme-status")

      assert html =~ "Acme Status"
      assert html =~ "All systems operational"
      assert html =~ "Powered by Runlater"
    end

    test "shows not found for disabled status page", %{conn: conn} do
      org = organization_fixture()
      _sp = status_page_fixture(org, %{slug: "disabled-page", enabled: false})

      {:ok, _view, html} = live(conn, ~p"/s/disabled-page")

      assert html =~ "Status page not found"
    end

    test "shows not found for non-existent slug", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/s/no-such-page")

      assert html =~ "Status page not found"
    end

    test "shows badge-enabled tasks", %{conn: conn} do
      org = organization_fixture()
      _sp = status_page_fixture(org, %{title: "Task Status", slug: "task-status", enabled: true})

      task = task_fixture(org, %{name: "Visible Task"})
      {:ok, _} = Prikke.Tasks.enable_badge(org, task)

      # A task without badge should not appear
      _hidden = task_fixture(org, %{name: "Hidden Task"})

      {:ok, _view, html} = live(conn, ~p"/s/task-status")

      assert html =~ "Visible Task"
      refute html =~ "Hidden Task"
    end

    test "shows badge-enabled monitors", %{conn: conn} do
      org = organization_fixture()
      _sp = status_page_fixture(org, %{title: "Mon Status", slug: "mon-status", enabled: true})

      monitor = monitor_fixture(org, %{name: "Visible Monitor"})
      {:ok, _} = Prikke.Monitors.enable_badge(org, monitor)

      _hidden = monitor_fixture(org, %{name: "Hidden Monitor"})

      {:ok, _view, html} = live(conn, ~p"/s/mon-status")

      assert html =~ "Visible Monitor"
      refute html =~ "Hidden Monitor"
    end

    test "shows badge-enabled endpoints", %{conn: conn} do
      org = organization_fixture()
      _sp = status_page_fixture(org, %{title: "EP Status", slug: "ep-status", enabled: true})

      endpoint = endpoint_fixture(org, %{name: "Visible Endpoint"})
      {:ok, _} = Prikke.Endpoints.enable_badge(org, endpoint)

      _hidden = endpoint_fixture(org, %{name: "Hidden Endpoint"})

      {:ok, _view, html} = live(conn, ~p"/s/ep-status")

      assert html =~ "Visible Endpoint"
      refute html =~ "Hidden Endpoint"
    end

    test "shows major outage when a task is failing", %{conn: conn} do
      org = organization_fixture()
      _sp = status_page_fixture(org, %{title: "Outage", slug: "outage-test", enabled: true})

      task = task_fixture(org, %{name: "Failing Task"})

      # Set last_execution_status directly
      task
      |> Ecto.Changeset.change(last_execution_status: "failed")
      |> Prikke.Repo.update!()

      task = Prikke.Tasks.get_task!(org, task.id)
      {:ok, _} = Prikke.Tasks.enable_badge(org, task)

      {:ok, _view, html} = live(conn, ~p"/s/outage-test")

      assert html =~ "Major outage"
    end

    test "does not require authentication", %{conn: conn} do
      org = organization_fixture()
      _sp = status_page_fixture(org, %{title: "Public Page", slug: "public-test", enabled: true})

      # No login needed
      {:ok, _view, html} = live(conn, ~p"/s/public-test")

      assert html =~ "Public Page"
    end
  end
end
