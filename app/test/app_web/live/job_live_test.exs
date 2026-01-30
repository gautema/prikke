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
      job = job_fixture(org, %{
        name: "My Cron Job",
        url: "https://example.com/webhook",
        cron_expression: "0 9 * * *"
      })

      {:ok, _view, html} = live(conn, ~p"/jobs/#{job.id}")

      assert html =~ job.name
      assert html =~ job.url
      assert html =~ "daily at 9:00"  # Human-readable cron
    end

    test "shows edit and delete buttons", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      job = job_fixture(org)

      {:ok, _view, html} = live(conn, ~p"/jobs/#{job.id}")

      assert html =~ "Edit"
      assert html =~ "Delete"
    end

    test "shows execution history section", %{conn: conn, user: user} do
      org = organization_fixture(%{user: user})
      job = job_fixture(org)

      {:ok, _view, html} = live(conn, ~p"/jobs/#{job.id}")

      assert html =~ "Execution History"
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

      # Submit with empty name
      html = view
      |> form("#job-form", job: %{name: "", url: "https://example.com", schedule_type: "cron", cron_expression: "* * * * *"})
      |> render_change()

      assert html =~ "can't be blank" or html =~ "can&#39;t be blank"
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
  end
end
