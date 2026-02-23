defmodule PrikkeWeb.Api.SyncControllerTest do
  use PrikkeWeb.ConnCase, async: true

  import Prikke.AccountsFixtures
  import Prikke.TasksFixtures
  import Prikke.MonitorsFixtures
  import Prikke.EndpointsFixtures

  alias Prikke.Accounts
  alias Prikke.Tasks
  alias Prikke.Monitors
  alias Prikke.Endpoints

  setup %{conn: conn} do
    org = organization_fixture()
    user = user_fixture()
    {:ok, api_key, raw_secret} = Accounts.create_api_key(org, user, %{name: "Test Key"})

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{api_key.key_id}.#{raw_secret}")

    %{conn: conn, org: org}
  end

  describe "PUT /api/v1/sync - tasks" do
    test "creates new tasks", %{conn: conn, org: org} do
      params = %{
        "tasks" => [
          %{
            "name" => "Task A",
            "url" => "https://example.com/a",
            "schedule_type" => "cron",
            "cron_expression" => "0 * * * *"
          },
          %{
            "name" => "Task B",
            "url" => "https://example.com/b",
            "schedule_type" => "cron",
            "cron_expression" => "0 0 * * *"
          }
        ]
      }

      conn = put(conn, ~p"/api/v1/sync", params)
      response = json_response(conn, 200)

      assert response["data"]["created_count"] == 2
      assert response["data"]["updated_count"] == 0
      assert "Task A" in response["data"]["created"]
      assert "Task B" in response["data"]["created"]

      # Verify tasks exist
      tasks = Tasks.list_tasks(org)
      assert length(tasks) == 2
    end

    test "updates existing tasks", %{conn: conn, org: org} do
      # Create an existing task
      task_fixture(org, %{name: "Existing Task", url: "https://old-url.com"})

      params = %{
        "tasks" => [
          %{
            "name" => "Existing Task",
            "url" => "https://new-url.com",
            "schedule_type" => "cron",
            "cron_expression" => "0 * * * *"
          }
        ]
      }

      conn = put(conn, ~p"/api/v1/sync", params)
      response = json_response(conn, 200)

      assert response["data"]["created_count"] == 0
      assert response["data"]["updated_count"] == 1
      assert "Existing Task" in response["data"]["updated"]

      # Verify URL was updated
      [task] = Tasks.list_tasks(org)
      assert task.url == "https://new-url.com"
    end

    test "creates and updates in same request", %{conn: conn, org: org} do
      task_fixture(org, %{name: "Existing Task"})

      params = %{
        "tasks" => [
          %{
            "name" => "Existing Task",
            "url" => "https://updated.com",
            "schedule_type" => "cron",
            "cron_expression" => "0 * * * *"
          },
          %{
            "name" => "New Task",
            "url" => "https://new.com",
            "schedule_type" => "cron",
            "cron_expression" => "0 0 * * *"
          }
        ]
      }

      conn = put(conn, ~p"/api/v1/sync", params)
      response = json_response(conn, 200)

      assert response["data"]["created_count"] == 1
      assert response["data"]["updated_count"] == 1
    end

    test "deletes removed tasks when delete_removed is true", %{conn: conn, org: org} do
      task_fixture(org, %{name: "Keep This"})
      task_fixture(org, %{name: "Delete This"})

      params = %{
        "tasks" => [
          %{
            "name" => "Keep This",
            "url" => "https://example.com",
            "schedule_type" => "cron",
            "cron_expression" => "0 * * * *"
          }
        ],
        "delete_removed" => true
      }

      conn = put(conn, ~p"/api/v1/sync", params)
      response = json_response(conn, 200)

      assert response["data"]["deleted_count"] == 1
      assert "Delete This" in response["data"]["deleted"]

      # Verify only one task remains
      tasks = Tasks.list_tasks(org)
      assert length(tasks) == 1
      assert hd(tasks).name == "Keep This"
    end

    test "does not delete removed tasks by default", %{conn: conn, org: org} do
      task_fixture(org, %{name: "Existing Task"})

      params = %{
        "tasks" => [
          %{
            "name" => "New Task",
            "url" => "https://example.com",
            "schedule_type" => "cron",
            "cron_expression" => "0 * * * *"
          }
        ]
      }

      conn = put(conn, ~p"/api/v1/sync", params)
      response = json_response(conn, 200)

      assert response["data"]["deleted_count"] == 0

      # Verify both tasks exist
      tasks = Tasks.list_tasks(org)
      assert length(tasks) == 2
    end

    test "returns error for invalid tasks", %{conn: conn} do
      params = %{
        "tasks" => [
          %{
            "name" => "",
            "url" => "not-a-url"
          }
        ]
      }

      conn = put(conn, ~p"/api/v1/sync", params)
      response = json_response(conn, 422)

      assert response["error"]["code"] == "validation_error"
    end

    test "handles empty tasks array", %{conn: conn, org: org} do
      task_fixture(org, %{name: "Existing Task"})

      params = %{"tasks" => []}

      conn = put(conn, ~p"/api/v1/sync", params)
      response = json_response(conn, 200)

      assert response["data"]["created_count"] == 0
      assert response["data"]["updated_count"] == 0
      assert response["message"] == "No changes"
    end
  end

  describe "PUT /api/v1/sync - monitors" do
    test "creates new monitors", %{conn: conn, org: org} do
      params = %{
        "monitors" => [
          %{
            "name" => "Heartbeat A",
            "schedule_type" => "interval",
            "interval_seconds" => 300
          },
          %{
            "name" => "Heartbeat B",
            "schedule_type" => "cron",
            "cron_expression" => "*/5 * * * *"
          }
        ]
      }

      conn = put(conn, ~p"/api/v1/sync", params)
      response = json_response(conn, 200)

      assert response["data"]["monitors"]["created_count"] == 2
      assert "Heartbeat A" in response["data"]["monitors"]["created"]
      assert "Heartbeat B" in response["data"]["monitors"]["created"]

      monitors = Monitors.list_monitors(org)
      assert length(monitors) == 2
    end

    test "updates existing monitors", %{conn: conn, org: org} do
      monitor_fixture(org, %{name: "Existing Monitor", interval_seconds: 300})

      params = %{
        "monitors" => [
          %{
            "name" => "Existing Monitor",
            "schedule_type" => "interval",
            "interval_seconds" => 600
          }
        ]
      }

      conn = put(conn, ~p"/api/v1/sync", params)
      response = json_response(conn, 200)

      assert response["data"]["monitors"]["updated_count"] == 1
      assert "Existing Monitor" in response["data"]["monitors"]["updated"]

      [monitor] = Monitors.list_monitors(org)
      assert monitor.interval_seconds == 600
    end

    test "deletes removed monitors when delete_removed is true", %{conn: conn, org: org} do
      monitor_fixture(org, %{name: "Keep This"})
      monitor_fixture(org, %{name: "Delete This"})

      params = %{
        "monitors" => [
          %{
            "name" => "Keep This",
            "schedule_type" => "interval",
            "interval_seconds" => 300
          }
        ],
        "delete_removed" => true
      }

      conn = put(conn, ~p"/api/v1/sync", params)
      response = json_response(conn, 200)

      assert response["data"]["monitors"]["deleted_count"] == 1
      assert "Delete This" in response["data"]["monitors"]["deleted"]

      monitors = Monitors.list_monitors(org)
      assert length(monitors) == 1
      assert hd(monitors).name == "Keep This"
    end

    test "does not delete removed monitors by default", %{conn: conn, org: org} do
      monitor_fixture(org, %{name: "Existing Monitor"})

      params = %{
        "monitors" => [
          %{
            "name" => "New Monitor",
            "schedule_type" => "interval",
            "interval_seconds" => 300
          }
        ]
      }

      conn = put(conn, ~p"/api/v1/sync", params)
      response = json_response(conn, 200)

      assert response["data"]["monitors"]["deleted_count"] == 0

      monitors = Monitors.list_monitors(org)
      assert length(monitors) == 2
    end

    test "returns error for invalid monitors", %{conn: conn} do
      params = %{
        "monitors" => [
          %{
            "name" => "",
            "schedule_type" => "interval"
          }
        ]
      }

      conn = put(conn, ~p"/api/v1/sync", params)
      response = json_response(conn, 422)

      assert response["error"]["code"] == "validation_error"
    end
  end

  describe "PUT /api/v1/sync - combined" do
    test "syncs tasks and monitors together", %{conn: conn, org: org} do
      params = %{
        "tasks" => [
          %{
            "name" => "My Task",
            "url" => "https://example.com/task",
            "schedule_type" => "cron",
            "cron_expression" => "0 * * * *"
          }
        ],
        "monitors" => [
          %{
            "name" => "My Monitor",
            "schedule_type" => "interval",
            "interval_seconds" => 300
          }
        ]
      }

      conn = put(conn, ~p"/api/v1/sync", params)
      response = json_response(conn, 200)

      # Task-level backwards compat fields
      assert response["data"]["created_count"] == 1
      assert "My Task" in response["data"]["created"]

      # Nested structure
      assert response["data"]["tasks"]["created_count"] == 1
      assert response["data"]["monitors"]["created_count"] == 1

      assert response["message"] == "Sync complete: 2 created"

      assert length(Tasks.list_tasks(org)) == 1
      assert length(Monitors.list_monitors(org)) == 1
    end

    test "delete_removed applies to both tasks and monitors", %{conn: conn, org: org} do
      task_fixture(org, %{name: "Old Task"})
      monitor_fixture(org, %{name: "Old Monitor"})

      params = %{
        "tasks" => [],
        "monitors" => [],
        "delete_removed" => true
      }

      conn = put(conn, ~p"/api/v1/sync", params)
      response = json_response(conn, 200)

      assert response["data"]["tasks"]["deleted_count"] == 1
      assert response["data"]["monitors"]["deleted_count"] == 1

      assert Tasks.list_tasks(org) == []
      assert Monitors.list_monitors(org) == []
    end

    test "returns error without tasks or monitors array", %{conn: conn} do
      conn = put(conn, ~p"/api/v1/sync", %{})
      response = json_response(conn, 400)

      assert response["error"]["code"] == "bad_request"
    end

    test "can sync only monitors without tasks", %{conn: conn, org: org} do
      params = %{
        "monitors" => [
          %{
            "name" => "Solo Monitor",
            "schedule_type" => "interval",
            "interval_seconds" => 600
          }
        ]
      }

      conn = put(conn, ~p"/api/v1/sync", params)
      response = json_response(conn, 200)

      assert response["data"]["monitors"]["created_count"] == 1
      # Tasks should be empty/zero since not provided
      assert response["data"]["tasks"]["created_count"] == 0

      assert length(Monitors.list_monitors(org)) == 1
    end

    test "can sync only endpoints", %{conn: conn, org: org} do
      params = %{
        "endpoints" => [
          %{
            "name" => "Stripe webhooks",
            "forward_url" => "https://myapp.com/webhooks/stripe"
          }
        ]
      }

      conn = put(conn, ~p"/api/v1/sync", params)
      response = json_response(conn, 200)

      assert response["data"]["endpoints"]["created_count"] == 1
      assert "Stripe webhooks" in response["data"]["endpoints"]["created"]
      assert response["data"]["tasks"]["created_count"] == 0
      assert response["data"]["monitors"]["created_count"] == 0

      assert length(Endpoints.list_endpoints(org)) == 1
    end

    test "syncs tasks, monitors, and endpoints together", %{conn: conn} do
      params = %{
        "tasks" => [
          %{
            "name" => "My Task",
            "url" => "https://example.com/task",
            "schedule_type" => "cron",
            "cron_expression" => "0 * * * *"
          }
        ],
        "monitors" => [
          %{
            "name" => "My Monitor",
            "schedule_type" => "interval",
            "interval_seconds" => 300
          }
        ],
        "endpoints" => [
          %{
            "name" => "My Endpoint",
            "forward_url" => "https://myapp.com/hooks"
          }
        ]
      }

      conn = put(conn, ~p"/api/v1/sync", params)
      response = json_response(conn, 200)

      assert response["data"]["tasks"]["created_count"] == 1
      assert response["data"]["monitors"]["created_count"] == 1
      assert response["data"]["endpoints"]["created_count"] == 1
      assert response["message"] == "Sync complete: 3 created"
    end
  end

  describe "PUT /api/v1/sync - endpoints" do
    test "creates new endpoints", %{conn: conn, org: org} do
      params = %{
        "endpoints" => [
          %{
            "name" => "Stripe webhooks",
            "forward_url" => "https://myapp.com/webhooks/stripe"
          },
          %{
            "name" => "GitHub webhooks",
            "forward_url" => "https://myapp.com/webhooks/github"
          }
        ]
      }

      conn = put(conn, ~p"/api/v1/sync", params)
      response = json_response(conn, 200)

      assert response["data"]["endpoints"]["created_count"] == 2
      assert "Stripe webhooks" in response["data"]["endpoints"]["created"]
      assert "GitHub webhooks" in response["data"]["endpoints"]["created"]

      endpoints = Endpoints.list_endpoints(org)
      assert length(endpoints) == 2
    end

    test "updates existing endpoints", %{conn: conn, org: org} do
      endpoint_fixture(org, %{name: "Existing Endpoint"})

      params = %{
        "endpoints" => [
          %{
            "name" => "Existing Endpoint",
            "forward_url" => "https://new-url.com/hooks"
          }
        ]
      }

      conn = put(conn, ~p"/api/v1/sync", params)
      response = json_response(conn, 200)

      assert response["data"]["endpoints"]["created_count"] == 0
      assert response["data"]["endpoints"]["updated_count"] == 1
      assert "Existing Endpoint" in response["data"]["endpoints"]["updated"]

      [endpoint] = Endpoints.list_endpoints(org)
      assert endpoint.forward_urls == ["https://new-url.com/hooks"]
    end

    test "deletes removed endpoints when delete_removed is true", %{conn: conn, org: org} do
      endpoint_fixture(org, %{name: "Keep This"})
      endpoint_fixture(org, %{name: "Delete This"})

      params = %{
        "endpoints" => [
          %{
            "name" => "Keep This",
            "forward_url" => "https://example.com/hooks"
          }
        ],
        "delete_removed" => true
      }

      conn = put(conn, ~p"/api/v1/sync", params)
      response = json_response(conn, 200)

      assert response["data"]["endpoints"]["deleted_count"] == 1
      assert "Delete This" in response["data"]["endpoints"]["deleted"]

      endpoints = Endpoints.list_endpoints(org)
      assert length(endpoints) == 1
      assert hd(endpoints).name == "Keep This"
    end

    test "does not delete removed endpoints by default", %{conn: conn, org: org} do
      endpoint_fixture(org, %{name: "Existing Endpoint"})

      params = %{
        "endpoints" => [
          %{
            "name" => "New Endpoint",
            "forward_url" => "https://example.com/hooks"
          }
        ]
      }

      conn = put(conn, ~p"/api/v1/sync", params)
      response = json_response(conn, 200)

      assert response["data"]["endpoints"]["deleted_count"] == 0

      endpoints = Endpoints.list_endpoints(org)
      assert length(endpoints) == 2
    end

    test "returns error for invalid endpoints", %{conn: conn} do
      params = %{
        "endpoints" => [
          %{
            "name" => "",
            "forward_url" => "not-a-url"
          }
        ]
      }

      conn = put(conn, ~p"/api/v1/sync", params)
      response = json_response(conn, 422)

      assert response["error"]["code"] == "validation_error"
    end
  end
end
