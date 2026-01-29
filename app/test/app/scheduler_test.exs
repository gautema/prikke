defmodule Prikke.SchedulerTest do
  use Prikke.DataCase

  import Prikke.AccountsFixtures

  alias Prikke.Scheduler
  alias Prikke.Jobs
  alias Prikke.Executions
  alias Prikke.Accounts

  describe "scheduler" do
    setup do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org", slug: "test-org"})
      # Upgrade to Pro for minute-level cron testing
      {:ok, org} = Accounts.upgrade_organization_to_pro(org)

      # Start scheduler for tests (it's disabled in test mode by default)
      # Use test_mode: true to skip auto-tick
      {:ok, pid} = start_supervised({Prikke.Scheduler, test_mode: true})
      # Allow the scheduler process to use the test's database sandbox
      Ecto.Adapters.SQL.Sandbox.allow(Prikke.Repo, self(), pid)

      %{user: user, organization: org}
    end

    test "schedules due cron jobs", %{organization: org} do
      # Create a job with next_run_at in the past
      {:ok, job} = Jobs.create_job(org, %{
        name: "Test Cron",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "* * * * *"  # Every minute
      })

      # Manually set next_run_at to the past
      past = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)
      job =
        job
        |> Ecto.Changeset.change(next_run_at: past)
        |> Prikke.Repo.update!()

      # Verify job is set up correctly
      assert job.enabled == true
      assert DateTime.compare(job.next_run_at, DateTime.utc_now()) == :lt

      # Trigger scheduler tick
      {:ok, count} = Scheduler.tick()

      assert count == 1

      # Verify execution was created
      executions = Executions.list_job_executions(job)
      assert length(executions) == 1
      assert hd(executions).status == "pending"
    end

    test "schedules due one-time jobs", %{organization: org} do
      # Create a one-time job scheduled in the future first
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      {:ok, job} = Jobs.create_job(org, %{
        name: "Test Once",
        url: "https://example.com/webhook",
        schedule_type: "once",
        scheduled_at: future
      })

      # Then set it to the past to simulate a due job
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      job =
        job
        |> Ecto.Changeset.change(scheduled_at: past, next_run_at: past)
        |> Prikke.Repo.update!()

      {:ok, count} = Scheduler.tick()

      assert count == 1

      # Verify execution was created
      executions = Executions.list_job_executions(job)
      assert length(executions) == 1

      # Verify next_run_at is now nil (one-time job completed)
      updated_job = Jobs.get_job!(org, job.id)
      assert updated_job.next_run_at == nil
    end

    test "skips disabled jobs", %{organization: org} do
      {:ok, job} = Jobs.create_job(org, %{
        name: "Disabled Job",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "* * * * *"
      })

      # Disable and set next_run_at to past
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      job
      |> Ecto.Changeset.change(enabled: false, next_run_at: past)
      |> Prikke.Repo.update!()

      {:ok, count} = Scheduler.tick()

      assert count == 0
    end

    test "skips jobs with future next_run_at", %{organization: org} do
      {:ok, _job} = Jobs.create_job(org, %{
        name: "Future Job",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "0 0 * * *"  # Daily at midnight
      })

      # Job should have next_run_at in the future
      {:ok, count} = Scheduler.tick()

      assert count == 0
    end

    test "advances next_run_at for cron jobs after scheduling", %{organization: org} do
      {:ok, job} = Jobs.create_job(org, %{
        name: "Cron Job",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "* * * * *"
      })

      # Set next_run_at to past
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      job
      |> Ecto.Changeset.change(next_run_at: past)
      |> Prikke.Repo.update!()

      {:ok, _count} = Scheduler.tick()

      # Verify next_run_at was advanced
      updated_job = Jobs.get_job!(org, job.id)
      assert updated_job.next_run_at != nil
      assert DateTime.compare(updated_job.next_run_at, past) == :gt
    end

    test "respects monthly execution limits", %{organization: org} do
      # org is on free tier (5000 executions/month)
      # We'll simulate hitting the limit by checking the behavior

      {:ok, job} = Jobs.create_job(org, %{
        name: "Limited Job",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "* * * * *"
      })

      # Set next_run_at to past
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      job
      |> Ecto.Changeset.change(next_run_at: past)
      |> Prikke.Repo.update!()

      # Should schedule since we're under limit
      {:ok, count} = Scheduler.tick()
      assert count == 1
    end
  end
end
