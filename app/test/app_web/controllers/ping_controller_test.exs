defmodule PrikkeWeb.PingControllerTest do
  use PrikkeWeb.ConnCase, async: true

  import Prikke.AccountsFixtures
  import Prikke.MonitorsFixtures

  alias Prikke.Monitors

  setup do
    user = user_fixture()
    {:ok, org} = Prikke.Accounts.create_organization(user, %{name: "Test Org"})
    monitor = monitor_fixture(org)
    %{org: org, monitor: monitor}
  end

  describe "GET /ping/:token" do
    test "returns 200 for valid token", %{conn: conn, monitor: monitor} do
      conn = get(conn, "/ping/#{monitor.ping_token}")

      assert json_response(conn, 200) == %{
               "status" => "ok",
               "monitor" => monitor.name
             }
    end

    test "returns 404 for unknown token", %{conn: conn} do
      conn = get(conn, "/ping/pm_nonexistent")

      assert json_response(conn, 404) == %{"error" => "Monitor not found"}
    end

    test "returns 410 for disabled monitor", %{conn: conn, org: org, monitor: monitor} do
      {:ok, _} = Monitors.toggle_monitor(org, monitor)

      conn = get(conn, "/ping/#{monitor.ping_token}")

      assert json_response(conn, 410) == %{"error" => "Monitor is disabled"}
    end

    test "updates monitor status to up", %{conn: conn, monitor: monitor} do
      get(conn, "/ping/#{monitor.ping_token}")

      updated = Monitors.get_monitor_by_token(monitor.ping_token)
      assert updated.status == "up"
      assert updated.last_ping_at != nil
    end
  end

  describe "POST /ping/:token" do
    test "returns 200 for valid token", %{conn: conn, monitor: monitor} do
      conn = post(conn, "/ping/#{monitor.ping_token}")

      assert json_response(conn, 200)["status"] == "ok"
    end

    test "transitions down monitor back to up", %{conn: conn, org: org, monitor: monitor} do
      # First ping to set up
      get(conn, "/ping/#{monitor.ping_token}")

      # Mark as down
      updated = Monitors.get_monitor_by_token(monitor.ping_token)
      {:ok, _} = Monitors.mark_down!(updated)

      # Verify it's down
      downed = Monitors.get_monitor!(org, monitor.id)
      assert downed.status == "down"

      # Ping again
      post(conn, "/ping/#{monitor.ping_token}")

      # Should be back up
      recovered = Monitors.get_monitor_by_token(monitor.ping_token)
      assert recovered.status == "up"
    end

    test "creates ping record", %{conn: conn, monitor: monitor} do
      post(conn, "/ping/#{monitor.ping_token}")

      pings = Monitors.list_recent_pings(monitor)
      assert length(pings) == 1
    end
  end
end
