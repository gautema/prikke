defmodule PrikkeWeb.Api.JobControllerTest do
  use PrikkeWeb.ConnCase, async: true

  import Prikke.AccountsFixtures
  import Prikke.JobsFixtures

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

  describe "GET /api/v1/jobs" do
    test "lists all jobs for the organization", %{conn: conn, org: org} do
      _job1 = job_fixture(org, %{name: "Job 1"})
      _job2 = job_fixture(org, %{name: "Job 2"})

      conn = get(conn, ~p"/api/v1/jobs")
      response = json_response(conn, 200)

      assert length(response["data"]) == 2
      names = Enum.map(response["data"], & &1["name"])
      assert "Job 1" in names
      assert "Job 2" in names
    end

    test "returns empty list when no jobs", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/jobs")
      assert json_response(conn, 200)["data"] == []
    end

    test "returns 401 without auth", %{org: _org} do
      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/v1/jobs")

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end
  end

  describe "GET /api/v1/jobs/:id" do
    test "returns the job", %{conn: conn, org: org} do
      job = job_fixture(org, %{name: "Test Job"})

      conn = get(conn, ~p"/api/v1/jobs/#{job.id}")
      response = json_response(conn, 200)

      assert response["data"]["id"] == job.id
      assert response["data"]["name"] == "Test Job"
    end

    test "returns 404 for non-existent job", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/jobs/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end

    test "returns 404 for job from another org", %{conn: conn} do
      other_org = organization_fixture()
      other_job = job_fixture(other_org)

      conn = get(conn, ~p"/api/v1/jobs/#{other_job.id}")
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  describe "POST /api/v1/jobs" do
    test "creates a cron job", %{conn: conn} do
      params = %{
        "name" => "New Cron Job",
        "url" => "https://example.com/webhook",
        "method" => "POST",
        "schedule_type" => "cron",
        "cron_expression" => "0 * * * *"
      }

      conn = post(conn, ~p"/api/v1/jobs", params)
      response = json_response(conn, 201)

      assert response["data"]["name"] == "New Cron Job"
      assert response["data"]["cron_expression"] == "0 * * * *"
      assert response["data"]["id"]
    end

    test "creates a one-time job", %{conn: conn} do
      scheduled_at = DateTime.utc_now() |> DateTime.add(1, :hour) |> DateTime.truncate(:second)

      params = %{
        "name" => "One-time Job",
        "url" => "https://example.com/webhook",
        "schedule_type" => "once",
        "scheduled_at" => DateTime.to_iso8601(scheduled_at)
      }

      conn = post(conn, ~p"/api/v1/jobs", params)
      response = json_response(conn, 201)

      assert response["data"]["name"] == "One-time Job"
      assert response["data"]["schedule_type"] == "once"
    end

    test "returns validation errors", %{conn: conn} do
      params = %{"name" => "", "url" => "not-a-url"}

      conn = post(conn, ~p"/api/v1/jobs", params)
      response = json_response(conn, 422)

      assert response["error"]["code"] == "validation_error"
      assert response["error"]["details"]["name"]
    end
  end

  describe "PUT /api/v1/jobs/:id" do
    test "updates the job", %{conn: conn, org: org} do
      job = job_fixture(org, %{name: "Original Name"})

      conn = put(conn, ~p"/api/v1/jobs/#{job.id}", %{"name" => "Updated Name"})
      response = json_response(conn, 200)

      assert response["data"]["name"] == "Updated Name"
    end

    test "returns 404 for non-existent job", %{conn: conn} do
      conn = put(conn, ~p"/api/v1/jobs/#{Ecto.UUID.generate()}", %{"name" => "New Name"})
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  describe "DELETE /api/v1/jobs/:id" do
    test "deletes the job", %{conn: conn, org: org} do
      job = job_fixture(org)

      conn = delete(conn, ~p"/api/v1/jobs/#{job.id}")
      assert response(conn, 204)

      # Verify it's deleted
      assert Prikke.Jobs.get_job(org, job.id) == nil
    end

    test "returns 404 for non-existent job", %{conn: conn} do
      conn = delete(conn, ~p"/api/v1/jobs/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  describe "POST /api/v1/jobs/:id/trigger" do
    test "creates an execution for the job", %{conn: conn, org: org} do
      job = job_fixture(org)

      conn = post(conn, ~p"/api/v1/jobs/#{job.id}/trigger")
      response = json_response(conn, 202)

      assert response["data"]["execution_id"]
      assert response["data"]["status"] == "pending"
      assert response["message"] == "Job triggered successfully"
    end

    test "returns 404 for non-existent job", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/jobs/#{Ecto.UUID.generate()}/trigger")
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  describe "GET /api/v1/jobs/:id/executions" do
    test "returns execution history", %{conn: conn, org: org} do
      job = job_fixture(org)

      # Create some executions
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, _} = Prikke.Executions.create_execution(%{job_id: job.id, scheduled_for: now})

      {:ok, _} =
        Prikke.Executions.create_execution(%{
          job_id: job.id,
          scheduled_for: DateTime.add(now, -1, :hour)
        })

      conn = get(conn, ~p"/api/v1/jobs/#{job.id}/executions")
      response = json_response(conn, 200)

      assert length(response["data"]) == 2
    end

    test "respects limit parameter", %{conn: conn, org: org} do
      job = job_fixture(org)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      for i <- 1..5 do
        {:ok, _} =
          Prikke.Executions.create_execution(%{
            job_id: job.id,
            scheduled_for: DateTime.add(now, -i, :hour)
          })
      end

      conn = get(conn, ~p"/api/v1/jobs/#{job.id}/executions?limit=2")
      response = json_response(conn, 200)

      assert length(response["data"]) == 2
    end
  end
end
