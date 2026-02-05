defmodule PrikkeWeb.Api.QueueControllerTest do
  use PrikkeWeb.ConnCase, async: true

  import Prikke.AccountsFixtures

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

  describe "POST /api/v1/queue" do
    test "queues a request for immediate execution", %{conn: conn} do
      params = %{
        "url" => "https://example.com/webhook",
        "method" => "POST",
        "body" => ~s({"event": "test"})
      }

      conn = post(conn, ~p"/api/v1/queue", params)
      response = json_response(conn, 202)

      assert response["message"] == "Request queued for immediate execution"
      assert response["data"]["status"] == "pending"
      assert response["data"]["job_id"]
      assert response["data"]["execution_id"]
      assert response["data"]["scheduled_for"]
    end

    test "uses defaults for optional fields", %{conn: conn} do
      params = %{"url" => "https://example.com/webhook"}

      conn = post(conn, ~p"/api/v1/queue", params)
      response = json_response(conn, 202)

      assert response["data"]["status"] == "pending"
    end

    test "accepts custom name", %{conn: conn} do
      params = %{
        "url" => "https://example.com/webhook",
        "name" => "My Custom Job"
      }

      conn = post(conn, ~p"/api/v1/queue", params)
      response = json_response(conn, 202)

      assert response["data"]["job_id"]

      # Verify the job was created with the custom name
      job = Prikke.Jobs.get_job!(conn.assigns.current_organization, response["data"]["job_id"])
      assert job.name == "My Custom Job"
    end

    test "returns 401 without auth" do
      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> post(~p"/api/v1/queue", %{"url" => "https://example.com"})

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end

    test "accepts callback_url and stores on job", %{conn: conn} do
      params = %{
        "url" => "https://example.com/webhook",
        "method" => "POST",
        "callback_url" => "https://example.com/callback"
      }

      conn = post(conn, ~p"/api/v1/queue", params)
      response = json_response(conn, 202)

      assert response["data"]["job_id"]

      job = Prikke.Jobs.get_job!(conn.assigns.current_organization, response["data"]["job_id"])
      assert job.callback_url == "https://example.com/callback"

      execution = Prikke.Executions.get_execution(response["data"]["execution_id"])
      assert execution.callback_url == "https://example.com/callback"
    end

    test "returns error for invalid URL", %{conn: conn} do
      params = %{"url" => "not-a-valid-url"}

      conn = post(conn, ~p"/api/v1/queue", params)
      assert json_response(conn, 422)
    end

    test "idempotency key returns same response on duplicate", %{conn: conn} do
      params = %{
        "url" => "https://example.com/webhook",
        "method" => "POST"
      }

      # First request with idempotency key
      conn1 =
        conn
        |> put_req_header("idempotency-key", "unique-key-123")
        |> post(~p"/api/v1/queue", params)

      response1 = json_response(conn1, 202)
      job_id_1 = response1["data"]["job_id"]
      execution_id_1 = response1["data"]["execution_id"]

      assert job_id_1
      assert execution_id_1

      # Second request with same idempotency key returns cached response
      conn2 =
        conn
        |> put_req_header("idempotency-key", "unique-key-123")
        |> post(~p"/api/v1/queue", params)

      response2 = json_response(conn2, 202)
      assert response2["data"]["job_id"] == job_id_1
      assert response2["data"]["execution_id"] == execution_id_1
    end

    test "different idempotency keys create different jobs", %{conn: conn} do
      params = %{
        "url" => "https://example.com/webhook",
        "method" => "POST"
      }

      conn1 =
        conn
        |> put_req_header("idempotency-key", "key-a")
        |> post(~p"/api/v1/queue", params)

      conn2 =
        conn
        |> put_req_header("idempotency-key", "key-b")
        |> post(~p"/api/v1/queue", params)

      response1 = json_response(conn1, 202)
      response2 = json_response(conn2, 202)

      refute response1["data"]["job_id"] == response2["data"]["job_id"]
    end

    test "no idempotency key creates new job each time", %{conn: conn} do
      params = %{
        "url" => "https://example.com/webhook",
        "method" => "POST"
      }

      conn1 = post(conn, ~p"/api/v1/queue", params)
      conn2 = post(conn, ~p"/api/v1/queue", params)

      response1 = json_response(conn1, 202)
      response2 = json_response(conn2, 202)

      refute response1["data"]["job_id"] == response2["data"]["job_id"]
    end
  end
end
