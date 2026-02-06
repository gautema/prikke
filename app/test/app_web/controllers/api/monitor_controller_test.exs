defmodule PrikkeWeb.Api.MonitorControllerTest do
  use PrikkeWeb.ConnCase, async: true

  import Prikke.AccountsFixtures
  import Prikke.MonitorsFixtures

  alias Prikke.Accounts
  alias Prikke.Monitors

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

  describe "GET /api/v1/monitors" do
    test "lists all monitors for the organization", %{conn: conn, org: org} do
      _m1 = monitor_fixture(org, %{name: "Monitor 1"})
      _m2 = monitor_fixture(org, %{name: "Monitor 2"})

      conn = get(conn, ~p"/api/v1/monitors")
      response = json_response(conn, 200)

      assert length(response["data"]) == 2
      names = Enum.map(response["data"], & &1["name"])
      assert "Monitor 1" in names
      assert "Monitor 2" in names
    end

    test "returns empty list when no monitors", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/monitors")
      assert json_response(conn, 200)["data"] == []
    end

    test "returns 401 without auth" do
      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/v1/monitors")

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end

    test "does not list monitors from other orgs", %{conn: conn} do
      other_org = organization_fixture()
      _other_monitor = monitor_fixture(other_org, %{name: "Other Monitor"})

      conn = get(conn, ~p"/api/v1/monitors")
      assert json_response(conn, 200)["data"] == []
    end
  end

  describe "GET /api/v1/monitors/:id" do
    test "returns the monitor with ping_url", %{conn: conn, org: org} do
      monitor = monitor_fixture(org, %{name: "Test Monitor"})

      conn = get(conn, ~p"/api/v1/monitors/#{monitor.id}")
      response = json_response(conn, 200)

      assert response["data"]["id"] == monitor.id
      assert response["data"]["name"] == "Test Monitor"
      assert response["data"]["ping_token"] == monitor.ping_token
      assert response["data"]["ping_url"] =~ "/ping/#{monitor.ping_token}"
      assert response["data"]["schedule_type"] == "interval"
      assert response["data"]["interval_seconds"] == 3600
    end

    test "returns 404 for non-existent monitor", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/monitors/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end

    test "returns 404 for monitor from another org", %{conn: conn} do
      other_org = organization_fixture()
      other_monitor = monitor_fixture(other_org)

      conn = get(conn, ~p"/api/v1/monitors/#{other_monitor.id}")
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  describe "POST /api/v1/monitors" do
    test "creates an interval monitor", %{conn: conn} do
      params = %{
        "name" => "New Monitor",
        "schedule_type" => "interval",
        "interval_seconds" => 3600,
        "grace_period_seconds" => 300
      }

      conn = post(conn, ~p"/api/v1/monitors", params)
      response = json_response(conn, 201)

      assert response["data"]["name"] == "New Monitor"
      assert response["data"]["schedule_type"] == "interval"
      assert response["data"]["interval_seconds"] == 3600
      assert response["data"]["ping_token"]
      assert response["data"]["ping_url"]
      assert response["data"]["status"] == "new"
    end

    test "creates a cron monitor", %{conn: conn} do
      params = %{
        "name" => "Cron Monitor",
        "schedule_type" => "cron",
        "cron_expression" => "0 * * * *",
        "grace_period_seconds" => 600
      }

      conn = post(conn, ~p"/api/v1/monitors", params)
      response = json_response(conn, 201)

      assert response["data"]["name"] == "Cron Monitor"
      assert response["data"]["schedule_type"] == "cron"
      assert response["data"]["cron_expression"] == "0 * * * *"
    end

    test "returns validation errors for missing fields", %{conn: conn} do
      params = %{"name" => ""}

      conn = post(conn, ~p"/api/v1/monitors", params)
      response = json_response(conn, 422)

      assert response["error"]["code"] == "validation_error"
    end

    test "returns validation error for invalid cron expression", %{conn: conn} do
      params = %{
        "name" => "Bad Cron",
        "schedule_type" => "cron",
        "cron_expression" => "not valid"
      }

      conn = post(conn, ~p"/api/v1/monitors", params)
      assert json_response(conn, 422)["error"]["code"] == "validation_error"
    end

    test "enforces tier limit", %{conn: conn, org: org} do
      # Free tier allows 3 monitors
      _m1 = monitor_fixture(org, %{name: "M1"})
      _m2 = monitor_fixture(org, %{name: "M2"})
      _m3 = monitor_fixture(org, %{name: "M3"})

      params = %{
        "name" => "M4 Over Limit",
        "schedule_type" => "interval",
        "interval_seconds" => 3600
      }

      conn = post(conn, ~p"/api/v1/monitors", params)
      assert json_response(conn, 422)["error"]["code"] == "validation_error"
    end
  end

  describe "PUT /api/v1/monitors/:id" do
    test "updates the monitor", %{conn: conn, org: org} do
      monitor = monitor_fixture(org, %{name: "Original Name"})

      conn = put(conn, ~p"/api/v1/monitors/#{monitor.id}", %{"name" => "Updated Name"})
      response = json_response(conn, 200)

      assert response["data"]["name"] == "Updated Name"
    end

    test "returns 404 for non-existent monitor", %{conn: conn} do
      conn = put(conn, ~p"/api/v1/monitors/#{Ecto.UUID.generate()}", %{"name" => "New Name"})
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end

    test "returns validation errors for invalid params", %{conn: conn, org: org} do
      monitor = monitor_fixture(org)

      conn =
        put(conn, ~p"/api/v1/monitors/#{monitor.id}", %{
          "schedule_type" => "cron",
          "cron_expression" => "invalid"
        })

      assert json_response(conn, 422)["error"]["code"] == "validation_error"
    end
  end

  describe "DELETE /api/v1/monitors/:id" do
    test "deletes the monitor", %{conn: conn, org: org} do
      monitor = monitor_fixture(org)

      conn = delete(conn, ~p"/api/v1/monitors/#{monitor.id}")
      assert response(conn, 204)

      assert Monitors.get_monitor(org, monitor.id) == nil
    end

    test "returns 404 for non-existent monitor", %{conn: conn} do
      conn = delete(conn, ~p"/api/v1/monitors/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  describe "GET /api/v1/monitors/:id/pings" do
    test "returns recent pings", %{conn: conn, org: org} do
      monitor = monitor_fixture(org)

      # Record a ping
      {:ok, _} = Monitors.record_ping!(monitor.ping_token)

      conn = get(conn, ~p"/api/v1/monitors/#{monitor.id}/pings")
      response = json_response(conn, 200)

      assert length(response["data"]) == 1
      assert response["data"] |> hd() |> Map.has_key?("id")
      assert response["data"] |> hd() |> Map.has_key?("received_at")
    end

    test "returns empty list when no pings", %{conn: conn, org: org} do
      monitor = monitor_fixture(org)

      conn = get(conn, ~p"/api/v1/monitors/#{monitor.id}/pings")
      assert json_response(conn, 200)["data"] == []
    end

    test "returns 404 for non-existent monitor", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/monitors/#{Ecto.UUID.generate()}/pings")
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end
end
