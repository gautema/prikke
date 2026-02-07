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
            url: "https://example.com",
            schedule_type: "cron",
            cron_expression: "0 * * * *"
          }
        )
        |> render_change()

      assert html =~ "can't be blank" or html =~ "can&#39;t be blank"
    end

    test "renders cron builder in simple mode by default", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, _view, html} = live(conn, ~p"/tasks/new")

      assert html =~ "Simple"
      assert html =~ "Advanced"
      assert html =~ "Every hour"
      assert html =~ "Daily"
      assert html =~ "Weekly"
      assert html =~ "Monthly"
    end

    test "switching cron preset updates the preview", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, view, _html} = live(conn, ~p"/tasks/new")

      html = view |> element("button", "Daily") |> render_click()

      assert html =~ "Time (UTC)"
      assert html =~ "daily at 9:00"
    end

    test "switching to weekly shows day pills", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, view, _html} = live(conn, ~p"/tasks/new")

      html = view |> element("button", "Weekly") |> render_click()

      assert html =~ "Days"
      assert html =~ "Mon"
      assert html =~ "Tue"
      assert html =~ "Sun"
    end

    test "switching to advanced mode shows text input", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, view, _html} = live(conn, ~p"/tasks/new")

      html = view |> element("button", "Advanced") |> render_click()

      assert html =~ "minute hour day month weekday"
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
