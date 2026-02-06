defmodule Prikke.JobsTest do
  use Prikke.DataCase

  alias Prikke.Jobs
  alias Prikke.Jobs.Job

  import Prikke.AccountsFixtures, only: [organization_fixture: 0, organization_fixture: 1]
  import Prikke.JobsFixtures

  describe "list_jobs/1" do
    test "returns all jobs for an organization" do
      org = organization_fixture()
      other_org = organization_fixture()

      job = job_fixture(org)
      _other_job = job_fixture(other_org)

      assert Jobs.list_jobs(org) == [job]
    end

    test "returns all jobs for an organization (multiple)" do
      org = organization_fixture()
      job1 = job_fixture(org, %{name: "First"})
      job2 = job_fixture(org, %{name: "Second"})

      jobs = Jobs.list_jobs(org)
      assert length(jobs) == 2
      assert Enum.any?(jobs, &(&1.id == job1.id))
      assert Enum.any?(jobs, &(&1.id == job2.id))
    end
  end

  describe "list_enabled_jobs/1" do
    test "returns only enabled jobs" do
      org = organization_fixture()
      enabled_job = job_fixture(org, %{enabled: true})
      _disabled_job = job_fixture(org, %{enabled: false})

      assert Jobs.list_enabled_jobs(org) == [enabled_job]
    end
  end

  describe "get_job!/2" do
    test "returns the job with given id" do
      org = organization_fixture()
      job = job_fixture(org)
      assert Jobs.get_job!(org, job.id) == job
    end

    test "raises for job from different organization" do
      org = organization_fixture()
      other_org = organization_fixture()
      job = job_fixture(org)

      assert_raise Ecto.NoResultsError, fn ->
        Jobs.get_job!(other_org, job.id)
      end
    end
  end

  describe "get_job/2" do
    test "returns the job with given id" do
      org = organization_fixture()
      job = job_fixture(org)
      assert Jobs.get_job(org, job.id) == job
    end

    test "returns nil for job from different organization" do
      org = organization_fixture()
      other_org = organization_fixture()
      job = job_fixture(org)

      assert Jobs.get_job(other_org, job.id) == nil
    end
  end

  describe "create_job/2" do
    test "with valid cron data creates a job (free tier, hourly)" do
      org = organization_fixture()

      valid_attrs = %{
        name: "My Cron Job",
        url: "https://example.com/webhook",
        method: "POST",
        headers: %{"Authorization" => "Bearer token"},
        body: ~s({"key": "value"}),
        schedule_type: "cron",
        cron_expression: "0 * * * *",
        timezone: "UTC"
      }

      assert {:ok, %Job{} = job} = Jobs.create_job(org, valid_attrs)
      assert job.name == "My Cron Job"
      assert job.url == "https://example.com/webhook"
      assert job.method == "POST"
      assert job.headers == %{"Authorization" => "Bearer token"}
      assert job.schedule_type == "cron"
      assert job.cron_expression == "0 * * * *"
      assert job.organization_id == org.id
      assert job.enabled == true
      assert job.interval_minutes == 60
    end

    test "with valid cron data creates a job (pro tier, per-minute)" do
      org = organization_fixture(tier: "pro")

      valid_attrs = %{
        name: "My Cron Job",
        url: "https://example.com/webhook",
        method: "POST",
        schedule_type: "cron",
        cron_expression: "*/5 * * * *"
      }

      assert {:ok, %Job{} = job} = Jobs.create_job(org, valid_attrs)
      assert job.cron_expression == "*/5 * * * *"
      assert job.interval_minutes == 5
    end

    test "with valid once data creates a job" do
      org = organization_fixture()
      scheduled_at = DateTime.add(DateTime.utc_now(), 3600, :second)

      valid_attrs = %{
        name: "One-time Job",
        url: "https://example.com/run-once",
        schedule_type: "once",
        scheduled_at: scheduled_at
      }

      assert {:ok, %Job{} = job} = Jobs.create_job(org, valid_attrs)
      assert job.name == "One-time Job"
      assert job.schedule_type == "once"
      assert job.scheduled_at == DateTime.truncate(scheduled_at, :second)
      assert job.interval_minutes == nil
    end

    test "with valid callback_url creates a job" do
      org = organization_fixture()

      attrs = %{
        name: "Callback Job",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "0 * * * *",
        callback_url: "https://example.com/callback"
      }

      assert {:ok, %Job{} = job} = Jobs.create_job(org, attrs)
      assert job.callback_url == "https://example.com/callback"
    end

    test "with invalid callback_url returns error" do
      org = organization_fixture()

      attrs = %{
        name: "Bad Callback Job",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "0 * * * *",
        callback_url: "not-a-url"
      }

      assert {:error, changeset} = Jobs.create_job(org, attrs)
      assert "must be a valid HTTP or HTTPS URL" in errors_on(changeset).callback_url
    end

    test "with nil callback_url creates a job without callback" do
      org = organization_fixture()

      attrs = %{
        name: "No Callback Job",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "0 * * * *"
      }

      assert {:ok, %Job{} = job} = Jobs.create_job(org, attrs)
      assert job.callback_url == nil
    end

    test "with invalid URL returns error" do
      org = organization_fixture()

      invalid_attrs = %{
        name: "Bad URL Job",
        url: "not-a-url",
        schedule_type: "cron",
        cron_expression: "0 * * * *"
      }

      assert {:error, changeset} = Jobs.create_job(org, invalid_attrs)
      assert "must be a valid HTTP or HTTPS URL" in errors_on(changeset).url
    end

    test "with invalid cron expression returns error" do
      org = organization_fixture()

      invalid_attrs = %{
        name: "Bad Cron Job",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "not valid cron"
      }

      assert {:error, changeset} = Jobs.create_job(org, invalid_attrs)
      assert "is not a valid cron expression" in errors_on(changeset).cron_expression
    end

    test "with past scheduled_at returns error" do
      org = organization_fixture()
      past_time = DateTime.add(DateTime.utc_now(), -3600, :second)

      invalid_attrs = %{
        name: "Past Job",
        url: "https://example.com/webhook",
        schedule_type: "once",
        scheduled_at: past_time
      }

      assert {:error, changeset} = Jobs.create_job(org, invalid_attrs)
      assert "must be in the future" in errors_on(changeset).scheduled_at
    end

    test "cron job without cron_expression returns error" do
      org = organization_fixture()

      invalid_attrs = %{
        name: "No Cron Expression",
        url: "https://example.com/webhook",
        schedule_type: "cron"
      }

      assert {:error, changeset} = Jobs.create_job(org, invalid_attrs)
      assert "can't be blank" in errors_on(changeset).cron_expression
    end

    test "once job without scheduled_at returns error" do
      org = organization_fixture()

      invalid_attrs = %{
        name: "No Scheduled Time",
        url: "https://example.com/webhook",
        schedule_type: "once"
      }

      assert {:error, changeset} = Jobs.create_job(org, invalid_attrs)
      assert "can't be blank" in errors_on(changeset).scheduled_at
    end

    test "with missing required fields returns error" do
      org = organization_fixture()

      assert {:error, changeset} = Jobs.create_job(org, %{})
      assert "can't be blank" in errors_on(changeset).name
      assert "can't be blank" in errors_on(changeset).url
      assert "can't be blank" in errors_on(changeset).schedule_type
    end

    test "free tier rejects per-minute cron jobs" do
      org = organization_fixture(tier: "free")

      attrs = %{
        name: "Minute Job",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "* * * * *"
      }

      assert {:error, changeset} = Jobs.create_job(org, attrs)

      assert "Free plan only allows hourly or less frequent schedules" <> _ =
               hd(errors_on(changeset).cron_expression)
    end

    test "free tier allows hourly cron jobs" do
      org = organization_fixture(tier: "free")

      attrs = %{
        name: "Hourly Job",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "0 * * * *"
      }

      assert {:ok, job} = Jobs.create_job(org, attrs)
      assert job.interval_minutes == 60
    end

    test "free tier enforces max job limit" do
      org = organization_fixture(tier: "free")
      limits = Jobs.get_tier_limits("free")

      # Create max number of jobs
      for i <- 1..limits.max_jobs do
        {:ok, _} =
          Jobs.create_job(org, %{
            name: "Job #{i}",
            url: "https://example.com/webhook",
            schedule_type: "cron",
            cron_expression: "0 * * * *"
          })
      end

      # Next job should fail
      attrs = %{
        name: "One Too Many",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "0 * * * *"
      }

      assert {:error, changeset} = Jobs.create_job(org, attrs)
      assert "You've reached the maximum number of jobs" <> _ = hd(errors_on(changeset).base)
    end

    test "pro tier allows per-minute cron jobs" do
      org = organization_fixture(tier: "pro")

      attrs = %{
        name: "Minute Job",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "* * * * *"
      }

      assert {:ok, job} = Jobs.create_job(org, attrs)
      assert job.interval_minutes == 1
    end

    test "pro tier has no job limit" do
      org = organization_fixture(tier: "pro")

      # Create more than free tier limit
      for i <- 1..7 do
        {:ok, _} =
          Jobs.create_job(org, %{
            name: "Job #{i}",
            url: "https://example.com/webhook",
            schedule_type: "cron",
            cron_expression: "* * * * *"
          })
      end

      assert Jobs.count_jobs(org) == 7
    end
  end

  describe "update_job/3" do
    test "with valid data updates the job" do
      org = organization_fixture()
      job = job_fixture(org)

      update_attrs = %{
        name: "Updated Name",
        enabled: false
      }

      assert {:ok, %Job{} = updated} = Jobs.update_job(org, job, update_attrs)
      assert updated.name == "Updated Name"
      assert updated.enabled == false
    end

    test "with invalid data returns error changeset" do
      org = organization_fixture()
      job = job_fixture(org)

      assert {:error, changeset} = Jobs.update_job(org, job, %{url: "bad-url"})
      assert "must be a valid HTTP or HTTPS URL" in errors_on(changeset).url

      # Job should be unchanged
      assert Jobs.get_job!(org, job.id) == job
    end

    test "with wrong organization raises" do
      org = organization_fixture()
      other_org = organization_fixture()
      job = job_fixture(org)

      assert_raise ArgumentError, "job does not belong to organization", fn ->
        Jobs.update_job(other_org, job, %{name: "Hacked"})
      end
    end

    test "free tier rejects updating to per-minute cron" do
      org = organization_fixture(tier: "free")
      job = job_fixture(org, %{cron_expression: "0 * * * *"})

      # Try to update to per-minute cron
      assert {:error, changeset} = Jobs.update_job(org, job, %{cron_expression: "* * * * *"})

      assert "Free plan only allows hourly or less frequent schedules" <> _ =
               hd(errors_on(changeset).cron_expression)

      # Job should be unchanged
      unchanged_job = Jobs.get_job!(org, job.id)
      assert unchanged_job.cron_expression == "0 * * * *"
    end
  end

  describe "delete_job/2" do
    test "deletes the job" do
      org = organization_fixture()
      job = job_fixture(org)

      assert {:ok, %Job{}} = Jobs.delete_job(org, job)
      assert_raise Ecto.NoResultsError, fn -> Jobs.get_job!(org, job.id) end
    end

    test "with wrong organization raises" do
      org = organization_fixture()
      other_org = organization_fixture()
      job = job_fixture(org)

      assert_raise ArgumentError, "job does not belong to organization", fn ->
        Jobs.delete_job(other_org, job)
      end
    end
  end

  describe "toggle_job/2" do
    test "toggles enabled to disabled" do
      org = organization_fixture()
      job = job_fixture(org, %{enabled: true})

      assert {:ok, %Job{enabled: false}} = Jobs.toggle_job(org, job)
    end

    test "toggles disabled to enabled" do
      org = organization_fixture()
      job = job_fixture(org, %{enabled: false})

      assert {:ok, %Job{enabled: true}} = Jobs.toggle_job(org, job)
    end

    test "re-enabling a cron job resets next_run_at to future time (skips missed executions)" do
      org = organization_fixture()
      # Create a cron job that runs every hour
      {:ok, job} =
        Jobs.create_job(org, %{
          name: "Hourly Job",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      # Disable the job
      {:ok, disabled_job} = Jobs.toggle_job(org, job)
      assert disabled_job.enabled == false

      # Manually set next_run_at to a past time (simulating missed executions)
      past_time =
        DateTime.utc_now()
        |> DateTime.add(-7200, :second)
        |> DateTime.truncate(:second)

      {:ok, job_with_past_next_run} =
        disabled_job
        |> Ecto.Changeset.change(next_run_at: past_time)
        |> Prikke.Repo.update()

      assert DateTime.compare(job_with_past_next_run.next_run_at, DateTime.utc_now()) == :lt

      # Re-enable the job
      {:ok, re_enabled_job} = Jobs.toggle_job(org, job_with_past_next_run)
      assert re_enabled_job.enabled == true

      # next_run_at should now be in the future (not the past time)
      assert re_enabled_job.next_run_at != nil
      assert DateTime.compare(re_enabled_job.next_run_at, DateTime.utc_now()) == :gt
    end

    test "re-enabling a one-time job with future scheduled_at keeps it scheduled" do
      org = organization_fixture()
      future_time = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, job} =
        Jobs.create_job(org, %{
          name: "Future One-time Job",
          url: "https://example.com/webhook",
          schedule_type: "once",
          scheduled_at: future_time
        })

      # Disable and re-enable
      {:ok, disabled_job} = Jobs.toggle_job(org, job)
      {:ok, re_enabled_job} = Jobs.toggle_job(org, disabled_job)

      assert re_enabled_job.enabled == true
      assert re_enabled_job.next_run_at != nil
      # Should be the original scheduled_at time
      assert DateTime.compare(re_enabled_job.next_run_at, DateTime.utc_now()) == :gt
    end

    test "re-enabling a one-time job with past scheduled_at does not schedule it" do
      org = organization_fixture()

      future_time =
        DateTime.utc_now()
        |> DateTime.add(3600, :second)
        |> DateTime.truncate(:second)

      {:ok, job} =
        Jobs.create_job(org, %{
          name: "One-time Job",
          url: "https://example.com/webhook",
          schedule_type: "once",
          scheduled_at: future_time
        })

      # Disable the job
      {:ok, disabled_job} = Jobs.toggle_job(org, job)

      # Manually set scheduled_at to a past time (simulating time passing)
      past_time =
        DateTime.utc_now()
        |> DateTime.add(-3600, :second)
        |> DateTime.truncate(:second)

      {:ok, job_with_past_scheduled_at} =
        disabled_job
        |> Ecto.Changeset.change(scheduled_at: past_time, next_run_at: nil)
        |> Prikke.Repo.update()

      # Re-enable the job
      {:ok, re_enabled_job} = Jobs.toggle_job(org, job_with_past_scheduled_at)
      assert re_enabled_job.enabled == true

      # next_run_at should be nil since scheduled_at is in the past
      assert re_enabled_job.next_run_at == nil
    end
  end

  describe "change_job/2" do
    test "returns a job changeset" do
      job = job_fixture()
      assert %Ecto.Changeset{} = Jobs.change_job(job)
    end
  end

  describe "count_jobs/1" do
    test "counts all jobs for organization" do
      org = organization_fixture()
      assert Jobs.count_jobs(org) == 0

      job_fixture(org)
      job_fixture(org)
      assert Jobs.count_jobs(org) == 2
    end
  end

  describe "count_enabled_jobs/1" do
    test "counts only enabled jobs" do
      org = organization_fixture()
      job_fixture(org, %{enabled: true})
      job_fixture(org, %{enabled: false})

      assert Jobs.count_enabled_jobs(org) == 1
    end
  end

  describe "clone_job/3" do
    test "clones a cron job with (copy) suffix" do
      org = organization_fixture()
      job = job_fixture(org, %{name: "My Cron Job", url: "https://example.com/webhook", method: "POST"})

      assert {:ok, %Job{} = cloned} = Jobs.clone_job(org, job)
      assert cloned.name == "My Cron Job (copy)"
      assert cloned.url == job.url
      assert cloned.method == job.method
      assert cloned.headers == job.headers
      assert cloned.body == job.body
      assert cloned.schedule_type == job.schedule_type
      assert cloned.cron_expression == job.cron_expression
      assert cloned.timezone == job.timezone
      assert cloned.timeout_ms == job.timeout_ms
      assert cloned.retry_attempts == job.retry_attempts
      assert cloned.enabled == true
      assert cloned.id != job.id
    end

    test "clones a one-time job with future scheduled_at" do
      org = organization_fixture()
      future_time = DateTime.add(DateTime.utc_now(), 7200, :second)

      {:ok, job} =
        Jobs.create_job(org, %{
          name: "Future One-time",
          url: "https://example.com/webhook",
          schedule_type: "once",
          scheduled_at: future_time
        })

      assert {:ok, %Job{} = cloned} = Jobs.clone_job(org, job)
      assert cloned.name == "Future One-time (copy)"
      assert cloned.schedule_type == "once"
      # Should keep the original future time
      assert DateTime.compare(cloned.scheduled_at, DateTime.utc_now()) == :gt
    end

    test "clones a one-time job with past scheduled_at adjusts to 1 hour from now" do
      org = organization_fixture()
      future_time = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, job} =
        Jobs.create_job(org, %{
          name: "Past One-time",
          url: "https://example.com/webhook",
          schedule_type: "once",
          scheduled_at: future_time
        })

      # Manually set scheduled_at to the past
      past_time = DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)

      {:ok, job} =
        job
        |> Ecto.Changeset.change(scheduled_at: past_time, next_run_at: nil)
        |> Prikke.Repo.update()

      assert {:ok, %Job{} = cloned} = Jobs.clone_job(org, job)
      assert cloned.name == "Past One-time (copy)"
      # Should be adjusted to ~1 hour from now
      assert DateTime.compare(cloned.scheduled_at, DateTime.utc_now()) == :gt
    end

    test "respects free tier job limit" do
      org = organization_fixture(tier: "free")
      limits = Jobs.get_tier_limits("free")

      # Create max number of jobs
      for i <- 1..limits.max_jobs do
        {:ok, _} =
          Jobs.create_job(org, %{
            name: "Job #{i}",
            url: "https://example.com/webhook",
            schedule_type: "cron",
            cron_expression: "0 * * * *"
          })
      end

      # Get the last job to clone
      [job | _] = Jobs.list_jobs(org)

      # Clone should fail due to job limit
      assert {:error, changeset} = Jobs.clone_job(org, job)
      assert "You've reached the maximum number of jobs" <> _ = hd(errors_on(changeset).base)
    end
  end

  describe "interval_minutes calculation" do
    test "every minute cron (pro tier)" do
      org = organization_fixture(tier: "pro")

      {:ok, job} =
        Jobs.create_job(org, %{
          name: "Every Minute",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "* * * * *"
        })

      assert job.interval_minutes == 1
    end

    test "hourly cron" do
      org = organization_fixture()

      {:ok, job} =
        Jobs.create_job(org, %{
          name: "Hourly",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      assert job.interval_minutes == 60
    end

    test "daily cron" do
      org = organization_fixture()

      {:ok, job} =
        Jobs.create_job(org, %{
          name: "Daily",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 9 * * *"
        })

      assert job.interval_minutes == 24 * 60
    end
  end
end
