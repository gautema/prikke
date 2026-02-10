defmodule PrikkeWeb.Api.TaskControllerTest do
  use PrikkeWeb.ConnCase, async: true

  import Prikke.AccountsFixtures
  import Prikke.TasksFixtures

  alias Prikke.Accounts

  setup %{conn: conn} do
    org = organization_fixture()
    user = user_fixture()
    {:ok, api_key, raw_secret} = Accounts.create_api_key(org, user, %{name: "Test Key"})

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{api_key.key_id}.#{raw_secret}")

    %{conn: conn, org: org, api_key: api_key}
  end

  describe "GET /api/v1/tasks" do
    test "lists all tasks for the organization with pagination metadata", %{conn: conn, org: org} do
      _task1 = task_fixture(org, %{name: "Task 1"})
      _task2 = task_fixture(org, %{name: "Task 2"})

      conn = get(conn, ~p"/api/v1/tasks")
      response = json_response(conn, 200)

      assert length(response["data"]) == 2
      names = Enum.map(response["data"], & &1["name"])
      assert "Task 1" in names
      assert "Task 2" in names
      assert response["has_more"] == false
      assert response["limit"] == 50
      assert response["offset"] == 0
    end

    test "returns empty list when no tasks", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/tasks")
      response = json_response(conn, 200)
      assert response["data"] == []
      assert response["has_more"] == false
    end

    test "respects custom limit and offset", %{conn: conn, org: org} do
      for i <- 1..5, do: task_fixture(org, %{name: "Task #{i}"})

      conn = get(conn, ~p"/api/v1/tasks?limit=2&offset=1")
      response = json_response(conn, 200)

      assert length(response["data"]) == 2
      assert response["has_more"] == true
      assert response["limit"] == 2
      assert response["offset"] == 1
    end

    test "caps limit at 100", %{conn: conn, org: org} do
      _task = task_fixture(org, %{name: "Task 1"})

      conn = get(conn, ~p"/api/v1/tasks?limit=200")
      response = json_response(conn, 200)

      assert response["limit"] == 100
    end

    test "filters tasks by queue parameter", %{conn: conn, org: org} do
      _task1 = task_fixture(org, %{name: "Payment Task", queue: "payments"})
      _task2 = task_fixture(org, %{name: "Email Task", queue: "emails"})
      _task3 = task_fixture(org, %{name: "No Queue Task"})

      conn = get(conn, ~p"/api/v1/tasks?queue=payments")
      response = json_response(conn, 200)

      assert length(response["data"]) == 1
      assert hd(response["data"])["name"] == "Payment Task"
      assert response["has_more"] == false
    end

    test "filters tasks with no queue using 'none'", %{conn: conn, org: org} do
      _task1 = task_fixture(org, %{name: "Payment Task", queue: "payments"})
      _task2 = task_fixture(org, %{name: "No Queue Task"})

      conn = get(conn, ~p"/api/v1/tasks?queue=none")
      response = json_response(conn, 200)

      assert length(response["data"]) == 1
      assert hd(response["data"])["name"] == "No Queue Task"
      assert response["has_more"] == false
    end

    test "returns 401 without auth", %{org: _org} do
      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/v1/tasks")

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end
  end

  describe "GET /api/v1/tasks/:id" do
    test "returns the task", %{conn: conn, org: org} do
      task = task_fixture(org, %{name: "Test Task"})

      conn = get(conn, ~p"/api/v1/tasks/#{task.id}")
      response = json_response(conn, 200)

      assert response["data"]["id"] == task.id
      assert response["data"]["name"] == "Test Task"
    end

    test "returns 404 for non-existent task", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/tasks/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end

    test "returns 404 for task from another org", %{conn: conn} do
      other_org = organization_fixture()
      other_task = task_fixture(other_org)

      conn = get(conn, ~p"/api/v1/tasks/#{other_task.id}")
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  describe "POST /api/v1/tasks - cron" do
    test "creates a cron task", %{conn: conn} do
      params = %{
        "url" => "https://example.com/webhook",
        "method" => "POST",
        "cron" => "0 * * * *",
        "name" => "Hourly Cron"
      }

      conn = post(conn, ~p"/api/v1/tasks", params)
      response = json_response(conn, 201)

      assert response["data"]["name"] == "Hourly Cron"
      assert response["data"]["cron_expression"] == "0 * * * *"
      assert response["data"]["schedule_type"] == "cron"
    end
  end

  describe "POST /api/v1/tasks - immediate" do
    test "queues a request for immediate execution", %{conn: conn} do
      params = %{
        "url" => "https://example.com/webhook",
        "method" => "POST",
        "body" => ~s({"event": "test"})
      }

      conn = post(conn, ~p"/api/v1/tasks", params)
      response = json_response(conn, 202)

      assert response["message"] == "Task queued for execution"
      assert response["data"]["status"] == "pending"
      assert response["data"]["task_id"]
      assert response["data"]["execution_id"]
      assert response["data"]["scheduled_for"]
    end

    test "uses defaults for optional fields", %{conn: conn} do
      params = %{"url" => "https://example.com/webhook"}

      conn = post(conn, ~p"/api/v1/tasks", params)
      response = json_response(conn, 202)

      assert response["data"]["status"] == "pending"
    end

    test "accepts custom name", %{conn: conn} do
      params = %{
        "url" => "https://example.com/webhook",
        "name" => "My Custom Task"
      }

      conn = post(conn, ~p"/api/v1/tasks", params)
      response = json_response(conn, 202)

      assert response["data"]["task_id"]

      task = Prikke.Tasks.get_task(conn.assigns.current_organization, response["data"]["task_id"])
      assert task.name == "My Custom Task"
    end

    test "accepts callback_url", %{conn: conn} do
      params = %{
        "url" => "https://example.com/webhook",
        "method" => "POST",
        "callback_url" => "https://example.com/callback"
      }

      conn = post(conn, ~p"/api/v1/tasks", params)
      response = json_response(conn, 202)

      assert response["data"]["task_id"]

      task = Prikke.Tasks.get_task(conn.assigns.current_organization, response["data"]["task_id"])
      assert task.callback_url == "https://example.com/callback"

      execution = Prikke.Executions.get_execution(response["data"]["execution_id"])
      assert execution.callback_url == "https://example.com/callback"
    end

    test "returns error for invalid URL", %{conn: conn} do
      params = %{"url" => "not-a-valid-url"}

      conn = post(conn, ~p"/api/v1/tasks", params)
      assert json_response(conn, 422)
    end
  end

  describe "POST /api/v1/tasks - delayed" do
    test "delays execution by seconds", %{conn: conn} do
      params = %{"url" => "https://example.com/webhook", "delay" => "30s"}

      conn = post(conn, ~p"/api/v1/tasks", params)
      response = json_response(conn, 202)

      scheduled_for = response["data"]["scheduled_for"]
      {:ok, scheduled_dt, _} = DateTime.from_iso8601(scheduled_for)
      diff = DateTime.diff(scheduled_dt, DateTime.utc_now())

      assert diff >= 28 and diff <= 32
    end

    test "delays execution by minutes", %{conn: conn} do
      params = %{"url" => "https://example.com/webhook", "delay" => "5m"}

      conn = post(conn, ~p"/api/v1/tasks", params)
      response = json_response(conn, 202)

      scheduled_for = response["data"]["scheduled_for"]
      {:ok, scheduled_dt, _} = DateTime.from_iso8601(scheduled_for)
      diff = DateTime.diff(scheduled_dt, DateTime.utc_now())

      assert diff >= 298 and diff <= 302
    end

    test "delays execution by hours", %{conn: conn} do
      params = %{"url" => "https://example.com/webhook", "delay" => "2h"}

      conn = post(conn, ~p"/api/v1/tasks", params)
      response = json_response(conn, 202)

      scheduled_for = response["data"]["scheduled_for"]
      {:ok, scheduled_dt, _} = DateTime.from_iso8601(scheduled_for)
      diff = DateTime.diff(scheduled_dt, DateTime.utc_now())

      assert diff >= 7198 and diff <= 7202
    end

    test "delays execution by days", %{conn: conn} do
      params = %{"url" => "https://example.com/webhook", "delay" => "1d"}

      conn = post(conn, ~p"/api/v1/tasks", params)
      response = json_response(conn, 202)

      scheduled_for = response["data"]["scheduled_for"]
      {:ok, scheduled_dt, _} = DateTime.from_iso8601(scheduled_for)
      diff = DateTime.diff(scheduled_dt, DateTime.utc_now())

      assert diff >= 86398 and diff <= 86402
    end

    test "returns error for invalid delay format", %{conn: conn} do
      params = %{"url" => "https://example.com/webhook", "delay" => "abc"}

      conn = post(conn, ~p"/api/v1/tasks", params)
      response = json_response(conn, 400)

      assert response["error"]["code"] == "invalid_delay"
    end

    test "returns error for delay without unit", %{conn: conn} do
      params = %{"url" => "https://example.com/webhook", "delay" => "30"}

      conn = post(conn, ~p"/api/v1/tasks", params)
      response = json_response(conn, 400)

      assert response["error"]["code"] == "invalid_delay"
    end

    test "returns error for zero delay", %{conn: conn} do
      params = %{"url" => "https://example.com/webhook", "delay" => "0s"}

      conn = post(conn, ~p"/api/v1/tasks", params)
      response = json_response(conn, 400)

      assert response["error"]["code"] == "invalid_delay"
    end
  end

  describe "POST /api/v1/tasks - idempotency" do
    test "idempotency key returns same response on duplicate", %{conn: conn} do
      params = %{
        "url" => "https://example.com/webhook",
        "method" => "POST"
      }

      conn1 =
        conn
        |> put_req_header("idempotency-key", "unique-key-123")
        |> post(~p"/api/v1/tasks", params)

      response1 = json_response(conn1, 202)
      task_id_1 = response1["data"]["task_id"]
      execution_id_1 = response1["data"]["execution_id"]

      assert task_id_1
      assert execution_id_1

      conn2 =
        conn
        |> put_req_header("idempotency-key", "unique-key-123")
        |> post(~p"/api/v1/tasks", params)

      response2 = json_response(conn2, 202)
      assert response2["data"]["task_id"] == task_id_1
      assert response2["data"]["execution_id"] == execution_id_1
    end

    test "different idempotency keys create different tasks", %{conn: conn} do
      params = %{
        "url" => "https://example.com/webhook",
        "method" => "POST"
      }

      conn1 =
        conn
        |> put_req_header("idempotency-key", "key-a")
        |> post(~p"/api/v1/tasks", params)

      conn2 =
        conn
        |> put_req_header("idempotency-key", "key-b")
        |> post(~p"/api/v1/tasks", params)

      response1 = json_response(conn1, 202)
      response2 = json_response(conn2, 202)

      refute response1["data"]["task_id"] == response2["data"]["task_id"]
    end

    test "no idempotency key creates new task each time", %{conn: conn} do
      params = %{
        "url" => "https://example.com/webhook",
        "method" => "POST"
      }

      conn1 = post(conn, ~p"/api/v1/tasks", params)
      conn2 = post(conn, ~p"/api/v1/tasks", params)

      response1 = json_response(conn1, 202)
      response2 = json_response(conn2, 202)

      refute response1["data"]["task_id"] == response2["data"]["task_id"]
    end
  end

  describe "PUT /api/v1/tasks/:id" do
    test "updates the task", %{conn: conn, org: org} do
      task = task_fixture(org, %{name: "Original Name"})

      conn = put(conn, ~p"/api/v1/tasks/#{task.id}", %{"name" => "Updated Name"})
      response = json_response(conn, 200)

      assert response["data"]["name"] == "Updated Name"
    end

    test "returns 404 for non-existent task", %{conn: conn} do
      conn = put(conn, ~p"/api/v1/tasks/#{Ecto.UUID.generate()}", %{"name" => "New Name"})
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  describe "DELETE /api/v1/tasks/:id" do
    test "deletes the task", %{conn: conn, org: org} do
      task = task_fixture(org)

      conn = delete(conn, ~p"/api/v1/tasks/#{task.id}")
      assert response(conn, 204)

      assert Prikke.Tasks.get_task(org, task.id) == nil
    end

    test "returns 404 for non-existent task", %{conn: conn} do
      conn = delete(conn, ~p"/api/v1/tasks/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  describe "POST /api/v1/tasks/:id/trigger" do
    test "creates an execution for the task", %{conn: conn, org: org} do
      task = task_fixture(org)

      conn = post(conn, ~p"/api/v1/tasks/#{task.id}/trigger")
      response = json_response(conn, 202)

      assert response["data"]["execution_id"]
      assert response["data"]["status"] == "pending"
      assert response["message"] == "Task triggered successfully"
    end

    test "returns 404 for non-existent task", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/tasks/#{Ecto.UUID.generate()}/trigger")
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  describe "GET /api/v1/tasks/:id/executions" do
    test "returns execution history", %{conn: conn, org: org} do
      task = task_fixture(org)

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, _} = Prikke.Executions.create_execution(%{task_id: task.id, scheduled_for: now})

      {:ok, _} =
        Prikke.Executions.create_execution(%{
          task_id: task.id,
          scheduled_for: DateTime.add(now, -1, :hour)
        })

      conn = get(conn, ~p"/api/v1/tasks/#{task.id}/executions")
      response = json_response(conn, 200)

      assert length(response["data"]) == 2
    end

    test "respects limit parameter", %{conn: conn, org: org} do
      task = task_fixture(org)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      for i <- 1..5 do
        {:ok, _} =
          Prikke.Executions.create_execution(%{
            task_id: task.id,
            scheduled_for: DateTime.add(now, -i, :hour)
          })
      end

      conn = get(conn, ~p"/api/v1/tasks/#{task.id}/executions?limit=2")
      response = json_response(conn, 200)

      assert length(response["data"]) == 2
    end
  end
end
