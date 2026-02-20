defmodule PrikkeWeb.Api.BatchControllerTest do
  use PrikkeWeb.ConnCase, async: true

  import Prikke.AccountsFixtures

  alias Prikke.Accounts
  alias Prikke.Tasks

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

  describe "POST /api/v1/tasks/batch" do
    test "creates batch and returns count and queue", %{conn: conn} do
      params = %{
        "url" => "https://example.com/api/send-email",
        "method" => "POST",
        "queue" => "newsletter",
        "items" => [
          %{"to" => "user1@example.com"},
          %{"to" => "user2@example.com"},
          %{"to" => "user3@example.com"}
        ]
      }

      conn = post(conn, ~p"/api/v1/tasks/batch", params)
      response = json_response(conn, 201)

      assert response["data"]["created"] == 3
      assert response["data"]["queue"] == "newsletter"
      assert response["data"]["scheduled_for"] != nil
      assert response["message"] == "3 tasks created"
    end

    test "with run_at schedules for future", %{conn: conn} do
      future =
        DateTime.utc_now()
        |> DateTime.add(3600, :second)
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()

      params = %{
        "url" => "https://example.com/api",
        "queue" => "scheduled",
        "run_at" => future,
        "items" => [%{"data" => "value"}]
      }

      conn = post(conn, ~p"/api/v1/tasks/batch", params)
      response = json_response(conn, 201)

      assert response["data"]["created"] == 1
      scheduled_for = response["data"]["scheduled_for"]
      {:ok, dt, _} = DateTime.from_iso8601(scheduled_for)
      assert DateTime.compare(dt, DateTime.utc_now()) == :gt
    end

    test "with delay schedules relative", %{conn: conn} do
      params = %{
        "url" => "https://example.com/api",
        "queue" => "delayed",
        "delay" => "10m",
        "items" => [%{"data" => "value"}]
      }

      conn = post(conn, ~p"/api/v1/tasks/batch", params)
      response = json_response(conn, 201)

      assert response["data"]["created"] == 1
      {:ok, dt, _} = DateTime.from_iso8601(response["data"]["scheduled_for"])
      diff = DateTime.diff(dt, DateTime.utc_now())
      assert diff >= 590 and diff <= 610
    end

    test "without timing creates immediate", %{conn: conn} do
      params = %{
        "url" => "https://example.com/api",
        "queue" => "immediate",
        "items" => [%{"data" => "value"}]
      }

      conn = post(conn, ~p"/api/v1/tasks/batch", params)
      response = json_response(conn, 201)

      assert response["data"]["created"] == 1
      {:ok, dt, _} = DateTime.from_iso8601(response["data"]["scheduled_for"])
      # Should be within a few seconds of now
      diff = abs(DateTime.diff(dt, DateTime.utc_now()))
      assert diff < 10
    end

    test "validates required url", %{conn: conn} do
      params = %{
        "queue" => "test",
        "items" => [%{"data" => "value"}]
      }

      conn = post(conn, ~p"/api/v1/tasks/batch", params)
      response = json_response(conn, 400)

      assert response["error"]["message"] =~ "url"
    end

    test "validates required queue", %{conn: conn} do
      params = %{
        "url" => "https://example.com/api",
        "items" => [%{"data" => "value"}]
      }

      conn = post(conn, ~p"/api/v1/tasks/batch", params)
      response = json_response(conn, 400)

      assert response["error"]["message"] =~ "queue"
    end

    test "validates required items", %{conn: conn} do
      params = %{
        "url" => "https://example.com/api",
        "queue" => "test"
      }

      conn = post(conn, ~p"/api/v1/tasks/batch", params)
      response = json_response(conn, 400)

      assert response["error"]["message"] =~ "items"
    end

    test "rejects empty items", %{conn: conn} do
      params = %{
        "url" => "https://example.com/api",
        "queue" => "test",
        "items" => []
      }

      conn = post(conn, ~p"/api/v1/tasks/batch", params)
      assert json_response(conn, 400)
    end

    test "rejects more than 1000 items", %{conn: conn} do
      items = for i <- 1..1001, do: %{"id" => i}

      params = %{
        "url" => "https://example.com/api",
        "queue" => "test",
        "items" => items
      }

      conn = post(conn, ~p"/api/v1/tasks/batch", params)
      response = json_response(conn, 400)

      assert response["error"]["message"] =~ "1000"
    end

    test "validates URL format", %{conn: conn} do
      params = %{
        "url" => "not-a-url",
        "queue" => "test",
        "items" => [%{"data" => "value"}]
      }

      conn = post(conn, ~p"/api/v1/tasks/batch", params)
      response = json_response(conn, 400)

      assert response["error"]["message"] =~ "url"
    end
  end

  describe "DELETE /api/v1/tasks?queue=name" do
    test "cancels matching tasks", %{conn: conn, org: org} do
      # Create a batch first
      {:ok, _} =
        Tasks.create_batch(
          org,
          %{"url" => "https://example.com/api", "queue" => "cancel-me"},
          [%{"a" => 1}, %{"b" => 2}]
        )

      assert length(Tasks.list_tasks(org, queue: "cancel-me")) == 2

      conn = delete(conn, ~p"/api/v1/tasks?queue=cancel-me")
      response = json_response(conn, 200)

      assert response["data"]["cancelled"] == 2
      assert response["message"] == "2 tasks cancelled"

      # Verify tasks are gone
      assert Tasks.list_tasks(org, queue: "cancel-me") == []
    end

    test "returns zero for nonexistent queue", %{conn: conn} do
      conn = delete(conn, ~p"/api/v1/tasks?queue=nonexistent")
      response = json_response(conn, 200)

      assert response["data"]["cancelled"] == 0
    end

    test "requires queue parameter", %{conn: conn} do
      conn = delete(conn, ~p"/api/v1/tasks")
      response = json_response(conn, 400)

      assert response["error"]["message"] =~ "queue"
    end
  end
end
