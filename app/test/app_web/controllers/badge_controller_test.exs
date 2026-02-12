defmodule PrikkeWeb.BadgeControllerTest do
  use PrikkeWeb.ConnCase, async: true

  import Prikke.AccountsFixtures
  import Prikke.TasksFixtures
  import Prikke.MonitorsFixtures
  import Prikke.EndpointsFixtures

  alias Prikke.Tasks
  alias Prikke.Monitors
  alias Prikke.Endpoints
  alias Prikke.Executions

  setup do
    user = user_fixture()
    {:ok, org} = Prikke.Accounts.create_organization(user, %{name: "Test Org"})
    %{org: org}
  end

  describe "GET /badge/task/:token/status.svg" do
    test "returns SVG for task with badge token", %{conn: conn, org: org} do
      task = task_fixture(org)
      {:ok, task} = Tasks.enable_badge(org, task)

      conn = get(conn, "/badge/task/#{task.badge_token}/status.svg")

      assert response(conn, 200) =~ "<svg"
      assert response_content_type(conn, :xml) =~ "image/svg+xml"
      assert get_resp_header(conn, "cache-control") |> List.first() =~ "public"
    end

    test "returns 404 SVG for unknown token", %{conn: conn} do
      conn = get(conn, "/badge/task/bt_nonexistent000000000000/status.svg")

      assert response(conn, 404) =~ "<svg"
      assert response(conn, 404) =~ "not found"
    end

    test "shows task name and status in badge", %{conn: conn, org: org} do
      task = task_fixture(org, %{name: "my-cron-job"})
      {:ok, task} = Tasks.enable_badge(org, task)

      conn = get(conn, "/badge/task/#{task.badge_token}/status.svg")

      body = response(conn, 200)
      assert body =~ "my-cron-job"
    end
  end

  describe "GET /badge/task/:token/uptime.svg" do
    test "returns uptime bars SVG", %{conn: conn, org: org} do
      task = task_fixture(org)
      {:ok, task} = Tasks.enable_badge(org, task)

      # Create some executions
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, exec} = Executions.create_execution_for_task(task, now)
      Executions.complete_execution(exec, %{status_code: 200, response_body: "ok"})

      conn = get(conn, "/badge/task/#{task.badge_token}/uptime.svg")

      assert response(conn, 200) =~ "<svg"
    end

    test "returns 'no data' badge when no executions", %{conn: conn, org: org} do
      task = task_fixture(org)
      {:ok, task} = Tasks.enable_badge(org, task)

      conn = get(conn, "/badge/task/#{task.badge_token}/uptime.svg")

      assert response(conn, 200) =~ "no data"
    end
  end

  describe "GET /badge/monitor/:token/status.svg" do
    test "returns SVG for monitor with badge token", %{conn: conn, org: org} do
      monitor = monitor_fixture(org)
      {:ok, monitor} = Monitors.enable_badge(org, monitor)

      conn = get(conn, "/badge/monitor/#{monitor.badge_token}/status.svg")

      assert response(conn, 200) =~ "<svg"
      assert response_content_type(conn, :xml) =~ "image/svg+xml"
    end

    test "returns 404 SVG for unknown token", %{conn: conn} do
      conn = get(conn, "/badge/monitor/bt_nonexistent000000000000/status.svg")

      assert response(conn, 404) =~ "not found"
    end
  end

  describe "GET /badge/monitor/:token/uptime.svg" do
    test "returns uptime bars SVG", %{conn: conn, org: org} do
      monitor = monitor_fixture(org)
      {:ok, monitor} = Monitors.enable_badge(org, monitor)

      conn = get(conn, "/badge/monitor/#{monitor.badge_token}/uptime.svg")

      assert response(conn, 200) =~ "<svg"
    end
  end

  describe "GET /badge/endpoint/:token/status.svg" do
    test "returns SVG for endpoint with badge token", %{conn: conn, org: org} do
      endpoint = endpoint_fixture(org)
      {:ok, endpoint} = Endpoints.enable_badge(org, endpoint)

      conn = get(conn, "/badge/endpoint/#{endpoint.badge_token}/status.svg")

      assert response(conn, 200) =~ "<svg"
      assert response(conn, 200) =~ "no data"
    end

    test "shows passing when last event succeeded", %{conn: conn, org: org} do
      endpoint = endpoint_fixture(org)
      {:ok, endpoint} = Endpoints.enable_badge(org, endpoint)

      # Create an inbound event with a successful execution
      Endpoints.receive_event(endpoint, %{
        headers: %{},
        body: "test",
        method: "POST",
        source_ip: "127.0.0.1"
      })

      # Get the event and complete its execution
      [event] = Endpoints.list_inbound_events(endpoint, limit: 1)

      if event.execution do
        Prikke.Executions.complete_execution(event.execution, %{
          status_code: 200,
          response_body: "ok",
          duration_ms: 50
        })
      end

      conn = get(conn, "/badge/endpoint/#{endpoint.badge_token}/status.svg")

      assert response(conn, 200) =~ "passing"
    end

    test "returns 404 SVG for unknown token", %{conn: conn} do
      conn = get(conn, "/badge/endpoint/bt_nonexistent000000000000/status.svg")

      assert response(conn, 404) =~ "not found"
    end
  end

  describe "GET /badge/endpoint/:token/uptime.svg" do
    test "returns uptime bars SVG", %{conn: conn, org: org} do
      endpoint = endpoint_fixture(org)
      {:ok, endpoint} = Endpoints.enable_badge(org, endpoint)

      conn = get(conn, "/badge/endpoint/#{endpoint.badge_token}/uptime.svg")

      assert response(conn, 200) =~ "<svg"
    end

    test "returns 404 SVG for unknown token", %{conn: conn} do
      conn = get(conn, "/badge/endpoint/bt_nonexistent000000000000/uptime.svg")

      assert response(conn, 404) =~ "not found"
    end
  end

  describe "badge token lifecycle" do
    test "task badge not accessible after disabling", %{conn: conn, org: org} do
      task = task_fixture(org)
      {:ok, task} = Tasks.enable_badge(org, task)
      token = task.badge_token

      # Badge works
      assert get(conn, "/badge/task/#{token}/status.svg") |> response(200) =~ "<svg"

      # Disable badge
      {:ok, _task} = Tasks.disable_badge(org, task)

      # Badge no longer works
      assert get(conn, "/badge/task/#{token}/status.svg") |> response(404) =~ "not found"
    end

    test "monitor badge not accessible after disabling", %{conn: conn, org: org} do
      monitor = monitor_fixture(org)
      {:ok, monitor} = Monitors.enable_badge(org, monitor)
      token = monitor.badge_token

      assert get(conn, "/badge/monitor/#{token}/status.svg") |> response(200) =~ "<svg"

      {:ok, _monitor} = Monitors.disable_badge(org, monitor)

      assert get(conn, "/badge/monitor/#{token}/status.svg") |> response(404) =~ "not found"
    end

    test "endpoint badge not accessible after disabling", %{conn: conn, org: org} do
      endpoint = endpoint_fixture(org)
      {:ok, endpoint} = Endpoints.enable_badge(org, endpoint)
      token = endpoint.badge_token

      assert get(conn, "/badge/endpoint/#{token}/status.svg") |> response(200) =~ "<svg"

      {:ok, _endpoint} = Endpoints.disable_badge(org, endpoint)

      assert get(conn, "/badge/endpoint/#{token}/status.svg") |> response(404) =~ "not found"
    end
  end
end
