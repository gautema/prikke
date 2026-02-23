defmodule PrikkeWeb.Api.QueueControllerTest do
  use PrikkeWeb.ConnCase, async: true

  import Prikke.AccountsFixtures
  import Prikke.TasksFixtures

  alias Prikke.Accounts
  alias Prikke.Queues

  setup %{conn: conn} do
    org = organization_fixture()
    user = user_fixture()
    {:ok, api_key, raw_secret} = Accounts.create_api_key(org, user, %{name: "Test Key"})

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{api_key.key_id}.#{raw_secret}")

    %{conn: conn, org: org}
  end

  describe "GET /api/v1/queues" do
    test "returns empty list when no queues exist", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/queues")
      assert json_response(conn, 200)["data"] == []
    end

    test "returns queues with pause status", %{conn: conn, org: org} do
      task_fixture(org, %{queue: "emails"})
      task_fixture(org, %{queue: "reports"})
      Queues.pause_queue(org, "emails")

      conn = get(conn, ~p"/api/v1/queues")
      data = json_response(conn, 200)["data"]

      assert length(data) == 2
      emails = Enum.find(data, &(&1["name"] == "emails"))
      reports = Enum.find(data, &(&1["name"] == "reports"))

      assert emails["paused"] == true
      assert reports["paused"] == false
    end
  end

  describe "POST /api/v1/queues/:name/pause" do
    test "pauses a queue", %{conn: conn, org: org} do
      task_fixture(org, %{queue: "emails"})

      conn = post(conn, ~p"/api/v1/queues/emails/pause")
      response = json_response(conn, 200)

      assert response["data"]["name"] == "emails"
      assert response["data"]["paused"] == true
      assert response["message"] =~ "paused"
    end

    test "pausing already paused queue is idempotent", %{conn: conn, org: org} do
      task_fixture(org, %{queue: "emails"})
      Queues.pause_queue(org, "emails")

      conn = post(conn, ~p"/api/v1/queues/emails/pause")
      response = json_response(conn, 200)

      assert response["data"]["paused"] == true
    end
  end

  describe "POST /api/v1/queues/:name/resume" do
    test "resumes a paused queue", %{conn: conn, org: org} do
      task_fixture(org, %{queue: "emails"})
      Queues.pause_queue(org, "emails")

      conn = post(conn, ~p"/api/v1/queues/emails/resume")
      response = json_response(conn, 200)

      assert response["data"]["name"] == "emails"
      assert response["data"]["paused"] == false
      assert response["message"] =~ "resumed"
    end

    test "resuming non-paused queue is fine", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/queues/nonexistent/resume")
      response = json_response(conn, 200)

      assert response["data"]["paused"] == false
    end
  end
end
