defmodule PrikkeWeb.Api.SyncControllerTest do
  use PrikkeWeb.ConnCase, async: true

  import Prikke.AccountsFixtures
  import Prikke.JobsFixtures
  import Prikke.MonitorsFixtures

  alias Prikke.Accounts
  alias Prikke.Jobs
  alias Prikke.Monitors

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

  describe "PUT /api/v1/sync - jobs" do
    test "creates new jobs", %{conn: conn, org: org} do
      params = %{
        "jobs" => [
          %{
            "name" => "Job A",
            "url" => "https://example.com/a",
            "schedule_type" => "cron",
            "cron_expression" => "0 * * * *"
          },
          %{
            "name" => "Job B",
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
      assert "Job A" in response["data"]["created"]
      assert "Job B" in response["data"]["created"]

      # Verify jobs exist
      jobs = Jobs.list_jobs(org)
      assert length(jobs) == 2
    end

    test "updates existing jobs", %{conn: conn, org: org} do
      # Create an existing job
      job_fixture(org, %{name: "Existing Job", url: "https://old-url.com"})

      params = %{
        "jobs" => [
          %{
            "name" => "Existing Job",
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
      assert "Existing Job" in response["data"]["updated"]

      # Verify URL was updated
      [job] = Jobs.list_jobs(org)
      assert job.url == "https://new-url.com"
    end

    test "creates and updates in same request", %{conn: conn, org: org} do
      job_fixture(org, %{name: "Existing Job"})

      params = %{
        "jobs" => [
          %{
            "name" => "Existing Job",
            "url" => "https://updated.com",
            "schedule_type" => "cron",
            "cron_expression" => "0 * * * *"
          },
          %{
            "name" => "New Job",
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

    test "deletes removed jobs when delete_removed is true", %{conn: conn, org: org} do
      job_fixture(org, %{name: "Keep This"})
      job_fixture(org, %{name: "Delete This"})

      params = %{
        "jobs" => [
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

      # Verify only one job remains
      jobs = Jobs.list_jobs(org)
      assert length(jobs) == 1
      assert hd(jobs).name == "Keep This"
    end

    test "does not delete removed jobs by default", %{conn: conn, org: org} do
      job_fixture(org, %{name: "Existing Job"})

      params = %{
        "jobs" => [
          %{
            "name" => "New Job",
            "url" => "https://example.com",
            "schedule_type" => "cron",
            "cron_expression" => "0 * * * *"
          }
        ]
      }

      conn = put(conn, ~p"/api/v1/sync", params)
      response = json_response(conn, 200)

      assert response["data"]["deleted_count"] == 0

      # Verify both jobs exist
      jobs = Jobs.list_jobs(org)
      assert length(jobs) == 2
    end

    test "returns error for invalid jobs", %{conn: conn} do
      params = %{
        "jobs" => [
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

    test "handles empty jobs array", %{conn: conn, org: org} do
      job_fixture(org, %{name: "Existing Job"})

      params = %{"jobs" => []}

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
    test "syncs jobs and monitors together", %{conn: conn, org: org} do
      params = %{
        "jobs" => [
          %{
            "name" => "My Job",
            "url" => "https://example.com/job",
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

      # Job-level backwards compat fields
      assert response["data"]["created_count"] == 1
      assert "My Job" in response["data"]["created"]

      # Nested structure
      assert response["data"]["jobs"]["created_count"] == 1
      assert response["data"]["monitors"]["created_count"] == 1

      assert response["message"] == "Sync complete: 2 created"

      assert length(Jobs.list_jobs(org)) == 1
      assert length(Monitors.list_monitors(org)) == 1
    end

    test "delete_removed applies to both jobs and monitors", %{conn: conn, org: org} do
      job_fixture(org, %{name: "Old Job"})
      monitor_fixture(org, %{name: "Old Monitor"})

      params = %{
        "jobs" => [],
        "monitors" => [],
        "delete_removed" => true
      }

      conn = put(conn, ~p"/api/v1/sync", params)
      response = json_response(conn, 200)

      assert response["data"]["jobs"]["deleted_count"] == 1
      assert response["data"]["monitors"]["deleted_count"] == 1

      assert Jobs.list_jobs(org) == []
      assert Monitors.list_monitors(org) == []
    end

    test "returns error without jobs or monitors array", %{conn: conn} do
      conn = put(conn, ~p"/api/v1/sync", %{})
      response = json_response(conn, 400)

      assert response["error"]["code"] == "bad_request"
    end

    test "can sync only monitors without jobs", %{conn: conn, org: org} do
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
      # Jobs should be empty/zero since not provided
      assert response["data"]["jobs"]["created_count"] == 0

      assert length(Monitors.list_monitors(org)) == 1
    end
  end
end
