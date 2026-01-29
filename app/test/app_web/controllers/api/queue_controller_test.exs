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

  describe "POST /api/queue" do
    test "queues a request for immediate execution", %{conn: conn} do
      params = %{
        "url" => "https://example.com/webhook",
        "method" => "POST",
        "body" => ~s({"event": "test"})
      }

      conn = post(conn, ~p"/api/queue", params)
      response = json_response(conn, 202)

      assert response["message"] == "Request queued for immediate execution"
      assert response["data"]["status"] == "pending"
      assert response["data"]["job_id"]
      assert response["data"]["execution_id"]
      assert response["data"]["scheduled_for"]
    end

    test "uses defaults for optional fields", %{conn: conn} do
      params = %{"url" => "https://example.com/webhook"}

      conn = post(conn, ~p"/api/queue", params)
      response = json_response(conn, 202)

      assert response["data"]["status"] == "pending"
    end

    test "accepts custom name", %{conn: conn} do
      params = %{
        "url" => "https://example.com/webhook",
        "name" => "My Custom Job"
      }

      conn = post(conn, ~p"/api/queue", params)
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
        |> post(~p"/api/queue", %{"url" => "https://example.com"})

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end

    test "returns error for invalid URL", %{conn: conn} do
      params = %{"url" => "not-a-valid-url"}

      conn = post(conn, ~p"/api/queue", params)
      assert json_response(conn, 422)
    end
  end
end
