defmodule PrikkeWeb.BadgeControllerTest do
  use PrikkeWeb.ConnCase, async: true

  import Prikke.AccountsFixtures
  import Prikke.TasksFixtures
  import Prikke.MonitorsFixtures
  import Prikke.EndpointsFixtures
  import Prikke.StatusPagesFixtures

  alias Prikke.StatusPages
  alias Prikke.Executions

  setup do
    user = user_fixture()
    {:ok, org} = Prikke.Accounts.create_organization(user, %{name: "Test Org"})
    sp = status_page_fixture(org)
    %{org: org, status_page: sp}
  end

  describe "GET /badge/task/:token/status.svg" do
    test "returns SVG for task with badge token", %{conn: conn, org: org, status_page: sp} do
      task = task_fixture(org)
      item = add_status_page_item(sp, "task", task.id)

      conn = get(conn, "/badge/task/#{item.badge_token}/status.svg")

      assert response(conn, 200) =~ "<svg"
      assert response_content_type(conn, :xml) =~ "image/svg+xml"
      assert get_resp_header(conn, "cache-control") |> List.first() =~ "public"
    end

    test "returns 404 SVG for unknown token", %{conn: conn} do
      conn = get(conn, "/badge/task/bt_nonexistent000000000000/status.svg")

      assert response(conn, 404) =~ "<svg"
    end

    test "shows task name in badge", %{conn: conn, org: org, status_page: sp} do
      task = task_fixture(org, %{name: "my-cron-job"})
      item = add_status_page_item(sp, "task", task.id)

      conn = get(conn, "/badge/task/#{item.badge_token}/status.svg")

      body = response(conn, 200)
      assert body =~ "my-cron-job"
      assert body =~ "<circle"
    end
  end

  describe "GET /badge/task/:token/uptime.svg" do
    test "returns uptime bars SVG", %{conn: conn, org: org, status_page: sp} do
      task = task_fixture(org)
      item = add_status_page_item(sp, "task", task.id)

      # Create some executions
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, exec} = Executions.create_execution_for_task(task, now)
      Executions.complete_execution(exec, %{status_code: 200, response_body: "ok"})

      conn = get(conn, "/badge/task/#{item.badge_token}/uptime.svg")

      assert response(conn, 200) =~ "<svg"
    end

    test "returns dot badge when no executions", %{conn: conn, org: org, status_page: sp} do
      task = task_fixture(org)
      item = add_status_page_item(sp, "task", task.id)

      conn = get(conn, "/badge/task/#{item.badge_token}/uptime.svg")

      assert response(conn, 200) =~ "<circle"
    end
  end

  describe "GET /badge/monitor/:token/status.svg" do
    test "returns SVG for monitor with badge token", %{conn: conn, org: org, status_page: sp} do
      monitor = monitor_fixture(org)
      item = add_status_page_item(sp, "monitor", monitor.id)

      conn = get(conn, "/badge/monitor/#{item.badge_token}/status.svg")

      assert response(conn, 200) =~ "<svg"
      assert response_content_type(conn, :xml) =~ "image/svg+xml"
    end

    test "returns 404 SVG for unknown token", %{conn: conn} do
      conn = get(conn, "/badge/monitor/bt_nonexistent000000000000/status.svg")

      assert response(conn, 404) =~ "<svg"
    end
  end

  describe "GET /badge/monitor/:token/uptime.svg" do
    test "returns uptime bars SVG", %{conn: conn, org: org, status_page: sp} do
      monitor = monitor_fixture(org)
      item = add_status_page_item(sp, "monitor", monitor.id)

      conn = get(conn, "/badge/monitor/#{item.badge_token}/uptime.svg")

      assert response(conn, 200) =~ "<svg"
    end
  end

  describe "GET /badge/endpoint/:token/status.svg" do
    test "returns SVG for endpoint with badge token", %{conn: conn, org: org, status_page: sp} do
      endpoint = endpoint_fixture(org)
      item = add_status_page_item(sp, "endpoint", endpoint.id)

      conn = get(conn, "/badge/endpoint/#{item.badge_token}/status.svg")

      assert response(conn, 200) =~ "<svg"
      assert response(conn, 200) =~ "<circle"
    end

    test "returns 404 SVG for unknown token", %{conn: conn} do
      conn = get(conn, "/badge/endpoint/bt_nonexistent000000000000/status.svg")

      assert response(conn, 404) =~ "<svg"
    end
  end

  describe "GET /badge/endpoint/:token/uptime.svg" do
    test "returns uptime bars SVG", %{conn: conn, org: org, status_page: sp} do
      endpoint = endpoint_fixture(org)
      item = add_status_page_item(sp, "endpoint", endpoint.id)

      conn = get(conn, "/badge/endpoint/#{item.badge_token}/uptime.svg")

      assert response(conn, 200) =~ "<svg"
    end

    test "returns 404 SVG for unknown token", %{conn: conn} do
      conn = get(conn, "/badge/endpoint/bt_nonexistent000000000000/uptime.svg")

      assert response(conn, 404) =~ "<svg"
    end
  end

  describe "GET /badge/queue/:token/status.svg" do
    test "returns SVG for queue with badge token", %{conn: conn, org: org, status_page: sp} do
      queue = Prikke.Queues.get_or_create_queue!(org, "emails")
      item = add_status_page_item(sp, "queue", queue.id)

      conn = get(conn, "/badge/queue/#{item.badge_token}/status.svg")

      assert response(conn, 200) =~ "<svg"
      assert response(conn, 200) =~ "emails"
    end

    test "returns 404 SVG for unknown token", %{conn: conn} do
      conn = get(conn, "/badge/queue/bt_nonexistent000000000000/status.svg")

      assert response(conn, 404) =~ "<svg"
    end
  end

  describe "GET /badge/queue/:token/uptime.svg" do
    test "returns uptime bars SVG", %{conn: conn, org: org, status_page: sp} do
      queue = Prikke.Queues.get_or_create_queue!(org, "emails")
      item = add_status_page_item(sp, "queue", queue.id)

      conn = get(conn, "/badge/queue/#{item.badge_token}/uptime.svg")

      assert response(conn, 200) =~ "<svg"
    end
  end

  describe "badge token lifecycle" do
    test "task badge not accessible after removing item", %{conn: conn, org: org, status_page: sp} do
      task = task_fixture(org)
      item = add_status_page_item(sp, "task", task.id)
      token = item.badge_token

      # Badge works
      assert get(conn, "/badge/task/#{token}/status.svg") |> response(200) =~ "<svg"

      # Remove item
      {:ok, _} = StatusPages.remove_item(sp, "task", task.id)

      # Badge no longer works
      assert get(conn, "/badge/task/#{token}/status.svg") |> response(404) =~ "<svg"
    end

    test "monitor badge not accessible after removing item", %{
      conn: conn,
      org: org,
      status_page: sp
    } do
      monitor = monitor_fixture(org)
      item = add_status_page_item(sp, "monitor", monitor.id)
      token = item.badge_token

      assert get(conn, "/badge/monitor/#{token}/status.svg") |> response(200) =~ "<svg"

      {:ok, _} = StatusPages.remove_item(sp, "monitor", monitor.id)

      assert get(conn, "/badge/monitor/#{token}/status.svg") |> response(404) =~ "<svg"
    end

    test "endpoint badge not accessible after removing item", %{
      conn: conn,
      org: org,
      status_page: sp
    } do
      endpoint = endpoint_fixture(org)
      item = add_status_page_item(sp, "endpoint", endpoint.id)
      token = item.badge_token

      assert get(conn, "/badge/endpoint/#{token}/status.svg") |> response(200) =~ "<svg"

      {:ok, _} = StatusPages.remove_item(sp, "endpoint", endpoint.id)

      assert get(conn, "/badge/endpoint/#{token}/status.svg") |> response(404) =~ "<svg"
    end

    test "wrong resource type returns 404", %{conn: conn, org: org, status_page: sp} do
      task = task_fixture(org)
      item = add_status_page_item(sp, "task", task.id)

      # Use task token on monitor badge route
      assert get(conn, "/badge/monitor/#{item.badge_token}/status.svg") |> response(404) =~ "<svg"
    end
  end
end
