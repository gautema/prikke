defmodule PrikkeWeb.StatusControllerTest do
  use PrikkeWeb.ConnCase

  alias Prikke.Status

  describe "GET /status" do
    test "renders status page", %{conn: conn} do
      # Set up some status checks
      Status.upsert_check("scheduler", "up", "Running")
      Status.upsert_check("workers", "up", "Workers OK")
      Status.upsert_check("api", "up", "API OK")

      conn = get(conn, ~p"/status")

      assert html_response(conn, 200) =~ "System Status"
      assert html_response(conn, 200) =~ "All Systems Operational"
      assert html_response(conn, 200) =~ "Job Scheduler"
      assert html_response(conn, 200) =~ "Job Workers"
      assert html_response(conn, 200) =~ "API &amp; Dashboard"
    end

    test "shows degraded status when component is degraded", %{conn: conn} do
      Status.upsert_check("scheduler", "up", "Running")
      Status.upsert_check("workers", "degraded", "High load")
      Status.upsert_check("api", "up", "API OK")

      conn = get(conn, ~p"/status")

      assert html_response(conn, 200) =~ "Degraded Performance"
    end

    test "shows open incidents", %{conn: conn} do
      Status.upsert_check("scheduler", "down", "Crashed")
      Status.create_incident("scheduler", "down", "Scheduler process crashed")

      conn = get(conn, ~p"/status")

      assert html_response(conn, 200) =~ "Active Incidents"
      assert html_response(conn, 200) =~ "Scheduler process crashed"
    end

    test "shows past incidents", %{conn: conn} do
      Status.upsert_check("scheduler", "up", "Running")
      {:ok, incident} = Status.create_incident("scheduler", "down", "Was down")
      Status.resolve_incident(incident)

      conn = get(conn, ~p"/status")

      assert html_response(conn, 200) =~ "Past Incidents"
      assert html_response(conn, 200) =~ "Resolved"
    end

    test "works with no status checks", %{conn: conn} do
      conn = get(conn, ~p"/status")

      assert html_response(conn, 200) =~ "System Status"
    end
  end
end
