defmodule PrikkeWeb.JobLiveTest do
  use PrikkeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Prikke.AccountsFixtures
  import Prikke.JobsFixtures

  describe "Job Index" do
    setup :register_and_log_in_user

    test "renders job list page", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      job = job_fixture(org, %{name: "Daily Backup"})

      {:ok, _view, html} = live(conn, ~p"/jobs")

      assert html =~ "Jobs"
      assert html =~ job.name
    end

    test "shows empty state when no jobs", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, _view, html} = live(conn, ~p"/jobs")

      assert html =~ "No jobs yet"
    end
  end

  describe "Job Show" do
    setup :register_and_log_in_user

    test "renders job details", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})

      job =
        job_fixture(org, %{
          name: "My Cron Job",
          url: "https://example.com/webhook",
          cron_expression: "0 9 * * *"
        })

      {:ok, _view, html} = live(conn, ~p"/jobs/#{job.id}")

      assert html =~ job.name
      assert html =~ job.url
      # Human-readable cron
      assert html =~ "daily at 9:00"
    end

    test "shows actions menu with edit and delete", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      job = job_fixture(org)

      {:ok, view, _html} = live(conn, ~p"/jobs/#{job.id}")

      # Open the menu
      html = view |> element("#job-actions-menu button") |> render_click()

      assert html =~ "Edit"
      assert html =~ "Delete"
      assert html =~ "Clone"
    end

    test "shows execution history section", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      job = job_fixture(org)

      {:ok, _view, html} = live(conn, ~p"/jobs/#{job.id}")

      assert html =~ "Execution History"
    end
  end

  describe "Job Clone" do
    setup :register_and_log_in_user

    test "shows clone in actions menu", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      job = job_fixture(org)

      {:ok, view, _html} = live(conn, ~p"/jobs/#{job.id}")

      # Open the menu
      html = view |> element("#job-actions-menu button") |> render_click()

      assert html =~ "Clone"
    end

    test "clicking clone creates a copy and redirects", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      job = job_fixture(org, %{name: "Original Job"})

      {:ok, view, _html} = live(conn, ~p"/jobs/#{job.id}")

      # Open the menu first, then click clone
      view |> element("#job-actions-menu button") |> render_click()
      view |> element("button", "Clone") |> render_click()

      # Should redirect to the cloned job
      {_path, flash} = assert_redirect(view)
      assert flash["info"] =~ "cloned"
    end
  end

  describe "Job New" do
    setup :register_and_log_in_user

    test "renders new job form", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, _view, html} = live(conn, ~p"/jobs/new")

      assert html =~ "Create New Job"
      assert html =~ "job_name" or html =~ "job[name]"
      assert html =~ "Create Job"
    end

    test "validates job form on change", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, view, _html} = live(conn, ~p"/jobs/new")

      # Submit with empty name - cron_expression comes from builder hidden input
      html =
        view
        |> form("#job-form",
          job: %{
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

      {:ok, _view, html} = live(conn, ~p"/jobs/new")

      # Should show simple/advanced toggle
      assert html =~ "Simple"
      assert html =~ "Advanced"
      # Should show preset buttons
      assert html =~ "Every hour"
      assert html =~ "Daily"
      assert html =~ "Weekly"
      assert html =~ "Monthly"
    end

    test "switching cron preset updates the preview", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, view, _html} = live(conn, ~p"/jobs/new")

      # Click "Daily" preset
      html = view |> element("button", "Daily") |> render_click()

      # Should show time picker and daily description
      assert html =~ "Time (UTC)"
      assert html =~ "daily at 9:00"
    end

    test "switching to weekly shows day pills", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, view, _html} = live(conn, ~p"/jobs/new")

      html = view |> element("button", "Weekly") |> render_click()

      assert html =~ "Days"
      assert html =~ "Mon"
      assert html =~ "Tue"
      assert html =~ "Sun"
    end

    test "switching to advanced mode shows text input", %{conn: conn, user: user} do
      _org = organization_fixture(%{user: user})

      {:ok, view, _html} = live(conn, ~p"/jobs/new")

      html = view |> element("button", "Advanced") |> render_click()

      assert html =~ "minute hour day month weekday"
    end
  end

  describe "Job Edit" do
    setup :register_and_log_in_user

    test "renders edit job form", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      job = job_fixture(org, %{name: "Original Name"})

      {:ok, _view, html} = live(conn, ~p"/jobs/#{job.id}/edit")

      assert html =~ "Edit Job"
      assert html =~ "Original Name"
      assert html =~ "Save Changes"
    end

    test "shows enabled toggle", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      job = job_fixture(org)

      {:ok, _view, html} = live(conn, ~p"/jobs/#{job.id}/edit")

      assert html =~ "Enabled"
    end

    test "initializes cron builder from existing hourly job", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      job = job_fixture(org, %{cron_expression: "0 * * * *"})

      {:ok, _view, html} = live(conn, ~p"/jobs/#{job.id}/edit")

      # Should be in simple mode with every_hour preset
      assert html =~ "Simple"
      assert html =~ "every hour"
    end

    test "initializes cron builder in advanced mode for complex expressions", %{
      conn: conn,
      user: user
    } do
      org = organization_fixture(%{user: user})
      job = job_fixture(org, %{cron_expression: "0 9 1-15 * 1-5"})

      {:ok, _view, html} = live(conn, ~p"/jobs/#{job.id}/edit")

      # Should fall back to advanced mode
      assert html =~ "Advanced"
      assert html =~ "minute hour day month weekday"
    end
  end
end
