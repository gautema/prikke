defmodule PrikkeWeb.PublicStatusLiveTest do
  use PrikkeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Prikke.AccountsFixtures
  import Prikke.StatusPagesFixtures
  import Prikke.TasksFixtures
  import Prikke.MonitorsFixtures
  import Prikke.EndpointsFixtures

  alias Prikke.StatusPages

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

    test "shows visible tasks via status page items", %{conn: conn} do
      org = organization_fixture()
      sp = status_page_fixture(org, %{title: "Task Status", slug: "task-status", enabled: true})

      task = task_fixture(org, %{name: "Visible Task"})
      StatusPages.add_item(sp, "task", task.id)

      # A task without item should not appear
      _hidden = task_fixture(org, %{name: "Hidden Task"})

      {:ok, _view, html} = live(conn, ~p"/s/task-status")

      assert html =~ "Visible Task"
      refute html =~ "Hidden Task"
    end

    test "shows visible monitors via status page items", %{conn: conn} do
      org = organization_fixture()
      sp = status_page_fixture(org, %{title: "Mon Status", slug: "mon-status", enabled: true})

      monitor = monitor_fixture(org, %{name: "Visible Monitor"})
      StatusPages.add_item(sp, "monitor", monitor.id)

      _hidden = monitor_fixture(org, %{name: "Hidden Monitor"})

      {:ok, _view, html} = live(conn, ~p"/s/mon-status")

      assert html =~ "Visible Monitor"
      refute html =~ "Hidden Monitor"
    end

    test "shows visible endpoints via status page items", %{conn: conn} do
      org = organization_fixture()
      sp = status_page_fixture(org, %{title: "EP Status", slug: "ep-status", enabled: true})

      endpoint = endpoint_fixture(org, %{name: "Visible Endpoint"})
      StatusPages.add_item(sp, "endpoint", endpoint.id)

      _hidden = endpoint_fixture(org, %{name: "Hidden Endpoint"})

      {:ok, _view, html} = live(conn, ~p"/s/ep-status")

      assert html =~ "Visible Endpoint"
      refute html =~ "Hidden Endpoint"
    end

    test "shows visible queues", %{conn: conn} do
      org = organization_fixture()
      sp = status_page_fixture(org, %{title: "Queue Status", slug: "queue-status", enabled: true})

      queue = Prikke.Queues.get_or_create_queue!(org, "emails")
      StatusPages.add_item(sp, "queue", queue.id)

      {:ok, _view, html} = live(conn, ~p"/s/queue-status")

      assert html =~ "emails"
      assert html =~ "Queue"
    end

    test "shows major outage when a task is failing", %{conn: conn} do
      org = organization_fixture()
      sp = status_page_fixture(org, %{title: "Outage", slug: "outage-test", enabled: true})

      task = task_fixture(org, %{name: "Failing Task"})

      # Set last_execution_status directly
      task
      |> Ecto.Changeset.change(last_execution_status: "failed")
      |> Prikke.Repo.update!()

      task = Prikke.Tasks.get_task!(org, task.id)
      StatusPages.add_item(sp, "task", task.id)

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
