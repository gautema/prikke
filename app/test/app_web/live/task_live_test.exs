defmodule PrikkeWeb.TaskLiveTest do
  use PrikkeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Prikke.AccountsFixtures
  import Prikke.TasksFixtures

  describe "Task Index" do
    setup :register_and_log_in_user

    test "renders task list page", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      task = task_fixture(org, %{name: "Daily Backup"})

      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ "Tasks"
      assert html =~ task.name
    end

    test "shows empty state when no tasks", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ "No tasks yet"
    end

    test "shows queue filter dropdown when tasks have queues", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      task_fixture(org, %{name: "Payment Task", queue: "payments"})
      task_fixture(org, %{name: "Email Task", queue: "emails"})

      {:ok, view, html} = live(conn, ~p"/tasks")

      assert has_element?(view, "#queue-filter-select")
      assert html =~ "All queues"
      assert html =~ "payments"
      assert html =~ "emails"
    end

    test "does not show queue filter when no tasks have queues", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      task_fixture(org, %{name: "No Queue Task"})

      {:ok, view, _html} = live(conn, ~p"/tasks")

      refute has_element?(view, "#queue-filter")
    end

    test "filtering by queue shows only matching tasks", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      task_fixture(org, %{name: "Payment Task", queue: "payments"})
      task_fixture(org, %{name: "Email Task", queue: "emails"})

      {:ok, view, _html} = live(conn, ~p"/tasks")

      html =
        view
        |> element("#queue-filter form")
        |> render_change(%{queue: "payments"})

      assert html =~ "Payment Task"
      refute html =~ "Email Task"
    end

    test "shows queue badge on task row", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      task_fixture(org, %{name: "Payment Task", queue: "payments"})

      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ "payments"
    end
  end

  describe "Task Show" do
    setup :register_and_log_in_user

    test "renders task details", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})

      task =
        task_fixture(org, %{
          name: "My Cron Task",
          url: "https://example.com/webhook",
          cron_expression: "0 9 * * *"
        })

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ task.name
      assert html =~ task.url
      assert html =~ "daily at 9:00"
    end

    test "shows actions menu with edit and delete", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      task = task_fixture(org)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      html = view |> element("#task-actions-menu button") |> render_click()

      assert html =~ "Edit"
      assert html =~ "Delete"
      assert html =~ "Clone"
    end

    test "shows execution history section", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      task = task_fixture(org)

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "Execution History"
    end
  end

  describe "Task Clone" do
    setup :register_and_log_in_user

    test "shows clone in actions menu", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      task = task_fixture(org)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      html = view |> element("#task-actions-menu button") |> render_click()

      assert html =~ "Clone"
    end

    test "clicking clone creates a copy and redirects", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      task = task_fixture(org, %{name: "Original Task"})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#task-actions-menu button") |> render_click()
      view |> element("button", "Clone") |> render_click()

      {_path, flash} = assert_redirect(view)
      assert flash["info"] =~ "cloned"
    end
  end

  describe "Task New" do
    setup :register_and_log_in_user

    test "renders new task form", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, _view, html} = live(conn, ~p"/tasks/new")

      assert html =~ "Create New Task"
      assert html =~ "task_name" or html =~ "task[name]"
      assert html =~ "Create Task"
    end

    test "validates task form on change", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, view, _html} = live(conn, ~p"/tasks/new")

      html =
        view
        |> form("#task-form",
          task: %{
            name: "",
            url: ""
          }
        )
        |> render_change()

      assert html =~ "can't be blank" or html =~ "can&#39;t be blank"
    end

    test "defaults to immediate mode", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, _view, html} = live(conn, ~p"/tasks/new")

      assert html =~ "Immediate"
      assert html =~ "immediately after creation"
    end

    test "switching to cron shows cron builder", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, view, _html} = live(conn, ~p"/tasks/new")

      html =
        view
        |> form("#task-form", timing_mode: "cron")
        |> render_change()

      assert html =~ "Simple"
      assert html =~ "Advanced"
      assert html =~ "Every hour"
    end

    test "switching to delay shows delay buttons", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, view, _html} = live(conn, ~p"/tasks/new")

      html =
        view
        |> form("#task-form", timing_mode: "delay")
        |> render_change()

      assert html =~ "5 min"
      assert html =~ "1 hour"
      assert html =~ "30 days"
    end

    test "switching to schedule shows datetime picker", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, view, _html} = live(conn, ~p"/tasks/new")

      html =
        view
        |> form("#task-form", timing_mode: "schedule")
        |> render_change()

      assert html =~ "Scheduled Time (UTC)"
    end

    test "switching cron preset updates the preview", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, view, _html} = live(conn, ~p"/tasks/new")

      # First switch to cron mode
      view
      |> form("#task-form", timing_mode: "cron")
      |> render_change()

      html = view |> element("button", "Daily") |> render_click()

      assert html =~ "Time (UTC)"
      assert html =~ "daily at 9:00"
    end

    test "creating immediate task produces a pending execution", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})

      {:ok, view, _html} = live(conn, ~p"/tasks/new")

      view
      |> form("#task-form",
        task: %{
          name: "Immediate Test Task",
          url: "https://example.com/webhook"
        },
        timing_mode: "immediate"
      )
      |> render_submit()

      {path, flash} = assert_redirect(view)
      assert flash["info"] =~ "created"

      # Extract task ID from redirect path
      task_id = path |> String.split("/") |> List.last()
      task = Prikke.Tasks.get_task!(org, task_id)

      # Verify an execution was created for this task
      assert Prikke.Executions.count_task_executions(task) == 1

      executions = Prikke.Executions.list_task_executions(task)
      assert length(executions) == 1
      assert hd(executions).status == "pending"
    end
  end

  describe "Task Edit" do
    setup :register_and_log_in_user

    test "renders edit task form", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      task = task_fixture(org, %{name: "Original Name"})

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}/edit")

      assert html =~ "Edit Task"
      assert html =~ "Original Name"
      assert html =~ "Save Changes"
    end

    test "shows enabled toggle", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      task = task_fixture(org)

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}/edit")

      assert html =~ "Enabled"
    end

    test "initializes cron builder from existing hourly task", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      task = task_fixture(org, %{cron_expression: "0 * * * *"})

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}/edit")

      assert html =~ "Simple"
      assert html =~ "every hour"
    end

    test "initializes cron builder in advanced mode for complex expressions", %{
      conn: conn,
      user: user
    } do
      org = organization_fixture(%{user: user})
      task = task_fixture(org, %{cron_expression: "0 9 1-15 * 1-5"})

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}/edit")

      assert html =~ "Advanced"
      assert html =~ "minute hour day month weekday"
    end
  end
end
