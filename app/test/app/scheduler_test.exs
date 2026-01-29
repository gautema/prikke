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
      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})
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
      {:ok, job} =
        Jobs.create_job(org, %{
          name: "Test Cron",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          # Every minute
          cron_expression: "* * * * *"
        })

      # Manually set next_run_at to just past (within grace period of 30s)
      # and inserted_at to earlier (simulates existing job)
      past = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:second)
      created_at = DateTime.utc_now() |> DateTime.add(-300, :second) |> DateTime.truncate(:second)

      job =
        job
        |> Ecto.Changeset.change(next_run_at: past, inserted_at: created_at)
        |> Prikke.Repo.update!()

      # Verify job is set up correctly
      assert job.enabled == true
      assert DateTime.compare(job.next_run_at, DateTime.utc_now()) == :lt

      # Trigger scheduler tick
      {:ok, count} = Scheduler.tick()

      assert count == 1

      # Verify execution was created
      executions = Executions.list_job_executions(job)
      assert length(executions) >= 1
      # Should be pending since within grace period
      assert hd(executions).status == "pending"
    end

    test "schedules due one-time jobs", %{organization: org} do
      # Create a one-time job scheduled in the future first
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      {:ok, job} =
        Jobs.create_job(org, %{
          name: "Test Once",
          url: "https://example.com/webhook",
          schedule_type: "once",
          scheduled_at: future
        })

      # Then set it to the past to simulate a due job
      # Also backdate inserted_at to simulate job that existed before
      past = DateTime.utc_now() |> DateTime.add(-30, :second) |> DateTime.truncate(:second)
      created_at = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

      job =
        job
        |> Ecto.Changeset.change(scheduled_at: past, next_run_at: past, inserted_at: created_at)
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
      {:ok, job} =
        Jobs.create_job(org, %{
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
      {:ok, _job} =
        Jobs.create_job(org, %{
          name: "Future Job",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          # Daily at midnight
          cron_expression: "0 0 * * *"
        })

      # Job should have next_run_at in the future
      {:ok, count} = Scheduler.tick()

      assert count == 0
    end

    test "advances next_run_at for cron jobs after scheduling", %{organization: org} do
      {:ok, job} =
        Jobs.create_job(org, %{
          name: "Cron Job",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "* * * * *"
        })

      # Set next_run_at and inserted_at to past (simulate existing job)
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      created_at = DateTime.utc_now() |> DateTime.add(-300, :second) |> DateTime.truncate(:second)

      job
      |> Ecto.Changeset.change(next_run_at: past, inserted_at: created_at)
      |> Prikke.Repo.update!()

      {:ok, _count} = Scheduler.tick()

      # Verify next_run_at was advanced
      updated_job = Jobs.get_job!(org, job.id)
      assert updated_job.next_run_at != nil
      assert DateTime.compare(updated_job.next_run_at, past) == :gt
    end

    test "respects monthly execution limits", %{organization: org} do
      # org is on Pro tier (upgraded in setup)
      # We'll verify the job schedules since we're under limit

      {:ok, job} =
        Jobs.create_job(org, %{
          name: "Limited Job",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "* * * * *"
        })

      # Set next_run_at and inserted_at to past (simulate existing job)
      past = DateTime.utc_now() |> DateTime.add(-20, :second) |> DateTime.truncate(:second)
      created_at = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

      job
      |> Ecto.Changeset.change(next_run_at: past, inserted_at: created_at)
      |> Prikke.Repo.update!()

      # Should schedule since we're under limit
      {:ok, count} = Scheduler.tick()
      assert count == 1
    end

    test "creates missed executions when scheduler was down", %{organization: org} do
      {:ok, job} =
        Jobs.create_job(org, %{
          name: "Missed Job",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          # Every minute
          cron_expression: "* * * * *"
        })

      # Simulate scheduler down for 3 minutes:
      # - Job created 5 minutes ago
      # - Last next_run_at was 3 minutes ago (missed 3 runs: -3min, -2min, -1min)
      created_at = DateTime.utc_now() |> DateTime.add(-300, :second) |> DateTime.truncate(:second)
      past = DateTime.utc_now() |> DateTime.add(-180, :second) |> DateTime.truncate(:second)

      job =
        job
        |> Ecto.Changeset.change(next_run_at: past, inserted_at: created_at)
        |> Prikke.Repo.update!()

      {:ok, _count} = Scheduler.tick()

      # Count may be 0 since all runs are past grace period (30s for 1-min cron)
      # What matters is that executions were created for visibility

      executions = Executions.list_job_executions(job, limit: 10)

      # Should have multiple executions (one for each missed interval)
      assert length(executions) >= 2

      # All should be "missed" status (past grace period)
      missed_count = Enum.count(executions, &(&1.status == "missed"))
      assert missed_count >= 2

      # Verify next_run_at was advanced past now
      updated_job = Jobs.get_job!(org, job.id)
      assert DateTime.compare(updated_job.next_run_at, DateTime.utc_now()) == :gt
    end

    test "does not create missed executions for newly created jobs", %{organization: org} do
      # Create a cron job - it will have next_run_at in the future
      {:ok, job} =
        Jobs.create_job(org, %{
          name: "New Job",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "* * * * *"
        })

      # Job's next_run_at should be in the future (next minute)
      # Even if we manually set it to the past, no missed executions
      # should be created for times before inserted_at

      # Set next_run_at to before inserted_at (edge case)
      way_past = DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.truncate(:second)

      job =
        job
        |> Ecto.Changeset.change(next_run_at: way_past)
        |> Prikke.Repo.update!()

      # inserted_at is still "now", so all those past times should be filtered out
      {:ok, count} = Scheduler.tick()

      # Should not schedule anything since all times are before job creation
      assert count == 0

      executions = Executions.list_job_executions(job)
      assert length(executions) == 0
    end
  end
end
