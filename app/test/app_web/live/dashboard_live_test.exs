defmodule PrikkeWeb.DashboardLiveTest do
  use PrikkeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Prikke.AccountsFixtures
  import Prikke.TasksFixtures

  describe "Dashboard" do
    setup :register_and_log_in_user

    test "renders dashboard with organization", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # Check page title and structure
      assert html =~ "Dashboard"
      assert html =~ org.name

      # Check stats cards are present
      assert html =~ "Active Tasks"
      assert html =~ "Executions Today"
      assert html =~ "Success Rate"
      assert html =~ "Avg Duration"
    end

    test "shows empty state when no tasks", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "No tasks yet"
      assert html =~ "Create your first task"
    end

    test "shows tasks list when tasks exist", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      task = task_fixture(org, %{name: "My Test Task", cron_expression: "0 * * * *"})

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ task.name
      # Human-readable cron
      assert html =~ "every hour"
    end

    test "shows new task button", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "New Task"
    end
  end
end
