defmodule PrikkeWeb.DashboardLiveTest do
  use PrikkeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Prikke.AccountsFixtures
  import Prikke.JobsFixtures

  describe "Dashboard" do
    setup :register_and_log_in_user

    test "renders dashboard with organization", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # Check page title and structure
      assert html =~ "Dashboard"
      assert html =~ org.name

      # Check stats cards are present
      assert html =~ "Active Jobs"
      assert html =~ "Executions Today"
      assert html =~ "Success Rate"
    end

    test "shows empty state when no jobs", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "No jobs yet"
      assert html =~ "Create a job"
    end

    test "shows jobs list when jobs exist", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      job = job_fixture(org, %{name: "My Test Job", cron_expression: "0 * * * *"})

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ job.name
      # Human-readable cron
      assert html =~ "every hour"
    end

    test "shows new job button", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "New Job"
    end
  end
end
