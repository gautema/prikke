defmodule Prikke.ExecutionsTest do
  use Prikke.DataCase

  import Prikke.AccountsFixtures

  alias Prikke.Executions
  alias Prikke.Tasks
  alias Prikke.Accounts

  describe "executions" do
    setup do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})

      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Test Job",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      %{user: user, organization: org, task: task}
    end

    test "create_execution/1 creates a pending execution", %{task: task} do
      scheduled_for = DateTime.utc_now()

      assert {:ok, execution} =
               Executions.create_execution(%{
                 task_id: task.id,
                 scheduled_for: scheduled_for
               })

      assert execution.task_id == task.id
      assert execution.status == "pending"
      assert execution.attempt == 1
    end

    test "create_execution_for_task/3 creates execution for task struct", %{task: task} do
      scheduled_for = DateTime.utc_now()

      assert {:ok, execution} = Executions.create_execution_for_task(task, scheduled_for)
      assert execution.task_id == task.id
      assert execution.status == "pending"
    end

    test "create_execution_for_task/3 copies task callback_url to execution", %{
      organization: org
    } do
      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Callback Job",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *",
          callback_url: "https://example.com/job-callback"
        })

      scheduled_for = DateTime.utc_now()
      assert {:ok, execution} = Executions.create_execution_for_task(task, scheduled_for)
      assert execution.callback_url == "https://example.com/job-callback"
    end

    test "create_execution_for_task/3 allows per-execution callback_url override", %{
      organization: org
    } do
      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Callback Job",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *",
          callback_url: "https://example.com/job-callback"
        })

      scheduled_for = DateTime.utc_now()

      assert {:ok, execution} =
               Executions.create_execution_for_task(task, scheduled_for,
                 callback_url: "https://example.com/override-callback"
               )

      assert execution.callback_url == "https://example.com/override-callback"
    end

    test "create_execution_for_task/3 with no callback_url leaves it nil", %{task: task} do
      scheduled_for = DateTime.utc_now()
      assert {:ok, execution} = Executions.create_execution_for_task(task, scheduled_for)
      assert execution.callback_url == nil
    end

    test "get_execution/1 returns the execution", %{task: task} do
      {:ok, execution} = Executions.create_execution_for_task(task, DateTime.utc_now())

      assert fetched = Executions.get_execution(execution.id)
      assert fetched.id == execution.id
    end

    test "get_execution_with_task/1 preloads task and organization", %{task: task} do
      {:ok, execution} = Executions.create_execution_for_task(task, DateTime.utc_now())

      assert fetched = Executions.get_execution_with_task(execution.id)
      assert fetched.task.id == task.id
      assert fetched.task.organization != nil
    end

    test "claim_next_execution/0 claims oldest pending execution", %{task: task} do
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, _exec1} = Executions.create_execution_for_task(task, past)

      assert {:ok, claimed} = Executions.claim_next_execution()
      assert claimed != nil
      assert claimed.status == "running"
      assert claimed.started_at != nil
    end

    test "claim_next_execution/0 returns nil when no pending executions", %{task: _task} do
      assert {:ok, nil} = Executions.claim_next_execution()
    end

    test "claim_next_execution/0 skips future scheduled executions", %{task: task} do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      {:ok, _exec} = Executions.create_execution_for_task(task, future)

      assert {:ok, nil} = Executions.claim_next_execution()
    end

    test "complete_execution/2 marks execution as success", %{task: task} do
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, _execution} = Executions.create_execution_for_task(task, past)
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

    test "fail_execution/2 marks execution as failed", %{task: task} do
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, _execution} = Executions.create_execution_for_task(task, past)
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

    test "timeout_execution/1 marks execution as timed out", %{task: task} do
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, _execution} = Executions.create_execution_for_task(task, past)
      {:ok, running} = Executions.claim_next_execution()

      assert {:ok, timed_out} = Executions.timeout_execution(running)

      assert timed_out.status == "timeout"
      assert timed_out.error_message == "Request timed out"
    end

    test "list_task_executions/2 returns executions for a task", %{task: task} do
      {:ok, _exec1} = Executions.create_execution_for_task(task, DateTime.utc_now())
      {:ok, _exec2} = Executions.create_execution_for_task(task, DateTime.utc_now())

      executions = Executions.list_task_executions(task)
      assert length(executions) == 2
    end

    test "list_organization_executions/2 returns executions for org", %{
      organization: org,
      task: task
    } do
      {:ok, _exec} = Executions.create_execution_for_task(task, DateTime.utc_now())

      executions = Executions.list_organization_executions(org)
      assert length(executions) == 1
      assert hd(executions).task != nil
    end

    test "count_pending_executions/0 counts pending executions", %{task: task} do
      assert Executions.count_pending_executions() == 0

      {:ok, _exec} = Executions.create_execution_for_task(task, DateTime.utc_now())
      assert Executions.count_pending_executions() == 1
    end

    test "get_task_stats/2 returns execution statistics", %{task: task} do
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, _exec1} = Executions.create_execution_for_task(task, past)
      {:ok, running} = Executions.claim_next_execution()
      {:ok, _completed} = Executions.complete_execution(running, %{status_code: 200})

      {:ok, _exec2} = Executions.create_execution_for_task(task, past)

      stats = Executions.get_task_stats(task)
      assert stats.total == 2
      assert stats.success == 1
      assert stats.pending == 1
    end

    test "get_organization_stats/2 returns org execution statistics", %{
      organization: org,
      task: task
    } do
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, _exec} = Executions.create_execution_for_task(task, past)
      {:ok, running} = Executions.claim_next_execution()
      {:ok, _completed} = Executions.complete_execution(running, %{status_code: 200})

      stats = Executions.get_organization_stats(org)
      assert stats.total == 1
      assert stats.success == 1
    end

    test "monthly execution counter increments on completion", %{
      organization: org,
      task: task
    } do
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      # Create and complete an execution
      {:ok, _exec} = Executions.create_execution_for_task(task, past)
      {:ok, running} = Executions.claim_next_execution()
      {:ok, _completed} = Executions.complete_execution(running, %{status_code: 200})

      # Flush buffered counter to DB before asserting
      Prikke.ExecutionCounter.flush_sync()
      org = Prikke.Repo.reload!(org)
      assert org.monthly_execution_count == 1
      assert Executions.count_current_month_executions(org) == 1
    end

    test "count_current_month_executions/1 reads from counter", %{organization: org, task: task} do
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      {:ok, _exec} = Executions.create_execution_for_task(task, past)
      {:ok, running} = Executions.claim_next_execution()
      {:ok, _completed} = Executions.complete_execution(running, %{status_code: 200})

      # Flush buffered counter to DB before asserting
      Prikke.ExecutionCounter.flush_sync()
      org = Prikke.Repo.reload!(org)
      count = Executions.count_current_month_executions(org)
      assert count == 1
    end

    test "counter increments on failure", %{organization: org, task: task} do
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      {:ok, _exec} = Executions.create_execution_for_task(task, past)
      {:ok, running} = Executions.claim_next_execution()
      {:ok, _failed} = Executions.fail_execution(running, %{error_message: "fail"})

      Prikke.ExecutionCounter.flush_sync()
      org = Prikke.Repo.reload!(org)
      assert org.monthly_execution_count == 1
    end

    test "counter increments on timeout", %{organization: org, task: task} do
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      {:ok, _exec} = Executions.create_execution_for_task(task, past)
      {:ok, running} = Executions.claim_next_execution()
      {:ok, _timed_out} = Executions.timeout_execution(running, 30_000)

      Prikke.ExecutionCounter.flush_sync()
      org = Prikke.Repo.reload!(org)
      assert org.monthly_execution_count == 1
    end

    test "counter does not increment for retries (attempt > 1)", %{organization: org, task: task} do
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      {:ok, exec} = Executions.create_execution_for_task(task, past)

      # Manually set attempt to 2 to simulate a retry
      exec
      |> Ecto.Changeset.change(%{
        attempt: 2,
        status: "running",
        started_at: DateTime.truncate(DateTime.utc_now(), :second)
      })
      |> Prikke.Repo.update!()

      exec = Prikke.Repo.reload!(exec)
      {:ok, _completed} = Executions.complete_execution(exec, %{status_code: 200})

      org = Prikke.Repo.reload!(org)
      assert org.monthly_execution_count == 0
    end

    test "claim_next_execution/0 blocks queue when earlier pending execution exists", %{
      organization: org
    } do
      # Create two tasks in the same queue
      {:ok, task1} =
        Tasks.create_task(org, %{
          name: "Queue Task 1",
          url: "https://example.com/1",
          schedule_type: "once",
          scheduled_at: DateTime.utc_now(),
          queue: "payments"
        })

      {:ok, task2} =
        Tasks.create_task(org, %{
          name: "Queue Task 2",
          url: "https://example.com/2",
          schedule_type: "once",
          scheduled_at: DateTime.utc_now(),
          queue: "payments"
        })

      past = DateTime.add(DateTime.utc_now(), -60, :second)
      future = DateTime.add(DateTime.utc_now(), 30, :second)

      # Create execution for task1 scheduled in the future (simulates a retry)
      {:ok, _retry_exec} = Executions.create_execution_for_task(task1, future)

      # Create execution for task2 scheduled in the past (ready to run)
      {:ok, _exec2} = Executions.create_execution_for_task(task2, past)

      # Even though task2's execution is ready, it should be blocked
      # because task1 has an earlier-created pending execution in the same queue
      assert {:ok, nil} = Executions.claim_next_execution()
    end

    test "claim_next_execution/0 allows queue execution when no earlier pending exists", %{
      organization: org
    } do
      {:ok, task1} =
        Tasks.create_task(org, %{
          name: "Queue Task 1",
          url: "https://example.com/1",
          schedule_type: "once",
          scheduled_at: DateTime.utc_now(),
          queue: "payments"
        })

      past = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, _exec} = Executions.create_execution_for_task(task1, past)

      # Single execution in queue, should be claimable
      assert {:ok, claimed} = Executions.claim_next_execution()
      assert claimed.task_id == task1.id
    end

    test "claim_next_execution/0 blocks queue when execution is running", %{
      organization: org
    } do
      {:ok, task1} =
        Tasks.create_task(org, %{
          name: "Queue Task 1",
          url: "https://example.com/1",
          schedule_type: "once",
          scheduled_at: DateTime.utc_now(),
          queue: "payments"
        })

      {:ok, task2} =
        Tasks.create_task(org, %{
          name: "Queue Task 2",
          url: "https://example.com/2",
          schedule_type: "once",
          scheduled_at: DateTime.utc_now(),
          queue: "payments"
        })

      past = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, _exec1} = Executions.create_execution_for_task(task1, past)
      {:ok, _exec2} = Executions.create_execution_for_task(task2, past)

      # Claim first execution (now running)
      assert {:ok, running} = Executions.claim_next_execution()
      assert running.task_id == task1.id

      # Second should be blocked because first is running
      assert {:ok, nil} = Executions.claim_next_execution()

      # Complete first, then second should be claimable
      {:ok, _completed} = Executions.complete_execution(running, %{status_code: 200})
      assert {:ok, claimed} = Executions.claim_next_execution()
      assert claimed.task_id == task2.id
    end

    test "reset_monthly_execution_counts/0 resets all counters" do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Counter Reset Org"})

      # Manually set a count
      Prikke.Repo.update_all(
        from(o in Prikke.Accounts.Organization, where: o.id == ^org.id),
        set: [monthly_execution_count: 42, monthly_execution_reset_at: nil]
      )

      Executions.reset_monthly_execution_counts()

      org = Prikke.Repo.reload!(org)
      assert org.monthly_execution_count == 0
      assert org.monthly_execution_reset_at != nil
    end
  end
end
