defmodule Prikke.ExecutionsTest do
  use Prikke.DataCase

  import Prikke.AccountsFixtures

  alias Prikke.Executions
  alias Prikke.Jobs
  alias Prikke.Accounts

  describe "executions" do
    setup do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})

      {:ok, job} =
        Jobs.create_job(org, %{
          name: "Test Job",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      %{user: user, organization: org, job: job}
    end

    test "create_execution/1 creates a pending execution", %{job: job} do
      scheduled_for = DateTime.utc_now()

      assert {:ok, execution} =
               Executions.create_execution(%{
                 job_id: job.id,
                 scheduled_for: scheduled_for
               })

      assert execution.job_id == job.id
      assert execution.status == "pending"
      assert execution.attempt == 1
    end

    test "create_execution_for_job/3 creates execution for job struct", %{job: job} do
      scheduled_for = DateTime.utc_now()

      assert {:ok, execution} = Executions.create_execution_for_job(job, scheduled_for)
      assert execution.job_id == job.id
      assert execution.status == "pending"
    end

    test "create_execution_for_job/3 copies job callback_url to execution", %{
      organization: org
    } do
      {:ok, job} =
        Jobs.create_job(org, %{
          name: "Callback Job",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *",
          callback_url: "https://example.com/job-callback"
        })

      scheduled_for = DateTime.utc_now()
      assert {:ok, execution} = Executions.create_execution_for_job(job, scheduled_for)
      assert execution.callback_url == "https://example.com/job-callback"
    end

    test "create_execution_for_job/3 allows per-execution callback_url override", %{
      organization: org
    } do
      {:ok, job} =
        Jobs.create_job(org, %{
          name: "Callback Job",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *",
          callback_url: "https://example.com/job-callback"
        })

      scheduled_for = DateTime.utc_now()

      assert {:ok, execution} =
               Executions.create_execution_for_job(job, scheduled_for,
                 callback_url: "https://example.com/override-callback"
               )

      assert execution.callback_url == "https://example.com/override-callback"
    end

    test "create_execution_for_job/3 with no callback_url leaves it nil", %{job: job} do
      scheduled_for = DateTime.utc_now()
      assert {:ok, execution} = Executions.create_execution_for_job(job, scheduled_for)
      assert execution.callback_url == nil
    end

    test "get_execution/1 returns the execution", %{job: job} do
      {:ok, execution} = Executions.create_execution_for_job(job, DateTime.utc_now())

      assert fetched = Executions.get_execution(execution.id)
      assert fetched.id == execution.id
    end

    test "get_execution_with_job/1 preloads job and organization", %{job: job} do
      {:ok, execution} = Executions.create_execution_for_job(job, DateTime.utc_now())

      assert fetched = Executions.get_execution_with_job(execution.id)
      assert fetched.job.id == job.id
      assert fetched.job.organization != nil
    end

    test "claim_next_execution/0 claims oldest pending execution", %{job: job} do
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, _exec1} = Executions.create_execution_for_job(job, past)

      assert {:ok, claimed} = Executions.claim_next_execution()
      assert claimed != nil
      assert claimed.status == "running"
      assert claimed.started_at != nil
    end

    test "claim_next_execution/0 returns nil when no pending executions", %{job: _job} do
      assert {:ok, nil} = Executions.claim_next_execution()
    end

    test "claim_next_execution/0 skips future scheduled executions", %{job: job} do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      {:ok, _exec} = Executions.create_execution_for_job(job, future)

      assert {:ok, nil} = Executions.claim_next_execution()
    end

    test "complete_execution/2 marks execution as success", %{job: job} do
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, _execution} = Executions.create_execution_for_job(job, past)
      {:ok, running} = Executions.claim_next_execution()

      assert {:ok, completed} =
               Executions.complete_execution(running, %{
                 status_code: 200,
                 response_body: "OK",
                 duration_ms: 150
               })

      assert completed.status == "success"
      assert completed.status_code == 200
      assert completed.finished_at != nil
      assert completed.duration_ms == 150
    end

    test "fail_execution/2 marks execution as failed", %{job: job} do
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, _execution} = Executions.create_execution_for_job(job, past)
      {:ok, running} = Executions.claim_next_execution()

      assert {:ok, failed} =
               Executions.fail_execution(running, %{
                 status_code: 500,
                 error_message: "Internal Server Error"
               })

      assert failed.status == "failed"
      assert failed.status_code == 500
      assert failed.error_message == "Internal Server Error"
    end

    test "timeout_execution/1 marks execution as timed out", %{job: job} do
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, _execution} = Executions.create_execution_for_job(job, past)
      {:ok, running} = Executions.claim_next_execution()

      assert {:ok, timed_out} = Executions.timeout_execution(running)

      assert timed_out.status == "timeout"
      assert timed_out.error_message == "Request timed out"
    end

    test "list_job_executions/2 returns executions for a job", %{job: job} do
      {:ok, _exec1} = Executions.create_execution_for_job(job, DateTime.utc_now())
      {:ok, _exec2} = Executions.create_execution_for_job(job, DateTime.utc_now())

      executions = Executions.list_job_executions(job)
      assert length(executions) == 2
    end

    test "list_organization_executions/2 returns executions for org", %{
      organization: org,
      job: job
    } do
      {:ok, _exec} = Executions.create_execution_for_job(job, DateTime.utc_now())

      executions = Executions.list_organization_executions(org)
      assert length(executions) == 1
      assert hd(executions).job != nil
    end

    test "count_pending_executions/0 counts pending executions", %{job: job} do
      assert Executions.count_pending_executions() == 0

      {:ok, _exec} = Executions.create_execution_for_job(job, DateTime.utc_now())
      assert Executions.count_pending_executions() == 1
    end

    test "get_job_stats/2 returns execution statistics", %{job: job} do
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, _exec1} = Executions.create_execution_for_job(job, past)
      {:ok, running} = Executions.claim_next_execution()
      {:ok, _completed} = Executions.complete_execution(running, %{status_code: 200})

      {:ok, _exec2} = Executions.create_execution_for_job(job, past)

      stats = Executions.get_job_stats(job)
      assert stats.total == 2
      assert stats.success == 1
      assert stats.pending == 1
    end

    test "get_organization_stats/2 returns org execution statistics", %{
      organization: org,
      job: job
    } do
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, _exec} = Executions.create_execution_for_job(job, past)
      {:ok, running} = Executions.claim_next_execution()
      {:ok, _completed} = Executions.complete_execution(running, %{status_code: 200})

      stats = Executions.get_organization_stats(org)
      assert stats.total == 1
      assert stats.success == 1
    end

    test "count_monthly_executions/3 counts completed executions in a month", %{
      organization: org,
      job: job
    } do
      now = DateTime.utc_now()
      past = DateTime.add(now, -60, :second)

      # Create and complete an execution
      {:ok, _exec} = Executions.create_execution_for_job(job, past)
      {:ok, running} = Executions.claim_next_execution()
      {:ok, _completed} = Executions.complete_execution(running, %{status_code: 200})

      count = Executions.count_monthly_executions(org, now.year, now.month)
      assert count == 1
    end

    test "count_current_month_executions/1 counts current month", %{organization: org, job: job} do
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      {:ok, _exec} = Executions.create_execution_for_job(job, past)
      {:ok, running} = Executions.claim_next_execution()
      {:ok, _completed} = Executions.complete_execution(running, %{status_code: 200})

      count = Executions.count_current_month_executions(org)
      assert count == 1
    end
  end
end
