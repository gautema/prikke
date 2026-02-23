defmodule PrikkeWeb.FailuresLiveTest do
  use PrikkeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Prikke.AccountsFixtures

  alias Prikke.Executions
  alias Prikke.Tasks

  describe "Failures page" do
    setup :register_and_log_in_user

    test "renders empty state when no failures", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, _view, html} = live(conn, ~p"/failures")

      assert html =~ "Failures"
      assert html =~ "No failures"
    end

    test "shows failed executions", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})

      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Failing Task",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, exec} = Executions.create_execution_for_task(task, now)
      {:ok, _} = Executions.fail_execution(exec, %{error_message: "Connection refused"})

      {:ok, _view, html} = live(conn, ~p"/failures")

      assert html =~ "Failing Task"
      assert html =~ "Connection refused"
      assert html =~ "failed"
    end

    test "shows timeout executions", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})

      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Timeout Task",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, exec} = Executions.create_execution_for_task(task, now)
      {:ok, _} = Executions.timeout_execution(exec, 30000)

      {:ok, _view, html} = live(conn, ~p"/failures")

      assert html =~ "Timeout Task"
      assert html =~ "timeout"
    end

    test "retry creates a new pending execution", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})

      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Retry Me",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, exec} = Executions.create_execution_for_task(task, now)
      {:ok, failed} = Executions.fail_execution(exec, %{error_message: "Error"})

      {:ok, view, _html} = live(conn, ~p"/failures")

      view
      |> element(~s(button[phx-value-id="#{failed.id}"]))
      |> render_click()

      # Should have a new pending execution for this task
      pending = Executions.list_task_executions(task, status: "pending")
      assert length(pending) >= 1
    end

    test "filters by queue", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})

      {:ok, task1} =
        Tasks.create_task(org, %{
          name: "Queue A Task",
          url: "https://example.com/webhook",
          schedule_type: "once",
          scheduled_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          queue: "queue-a"
        })

      {:ok, task2} =
        Tasks.create_task(org, %{
          name: "Queue B Task",
          url: "https://example.com/webhook",
          schedule_type: "once",
          scheduled_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          queue: "queue-b"
        })

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, exec1} = Executions.create_execution_for_task(task1, now)
      {:ok, _} = Executions.fail_execution(exec1, %{error_message: "Error A"})

      {:ok, exec2} = Executions.create_execution_for_task(task2, now)
      {:ok, _} = Executions.fail_execution(exec2, %{error_message: "Error B"})

      {:ok, view, html} = live(conn, ~p"/failures")

      # Both should be visible initially
      assert html =~ "Queue A Task"
      assert html =~ "Queue B Task"

      # Filter by queue-a
      html =
        view
        |> element("#failure-filters form")
        |> render_change(%{"queue" => "queue-a"})

      assert html =~ "Queue A Task"
      refute html =~ "Queue B Task"
    end
  end
end
