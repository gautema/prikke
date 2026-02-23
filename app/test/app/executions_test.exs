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
                 organization_id: task.organization_id,
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

    test "claim_next_execution/0 does not block queue for future-scheduled retries", %{
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

      # Create execution for task1 scheduled in the future (simulates a retry with backoff)
      {:ok, _retry_exec} = Executions.create_execution_for_task(task1, future)

      # Create execution for task2 scheduled in the past (ready to run)
      {:ok, _exec2} = Executions.create_execution_for_task(task2, past)

      # task2's execution should be claimable — a future-scheduled retry
      # for task1 should not block the entire queue
      assert {:ok, claimed} = Executions.claim_next_execution()
      assert claimed.task_id == task2.id
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

    test "claim_next_execution/0 skips many queue-blocked executions to find claimable work", %{
      organization: org_a
    } do
      # Simulate the real scenario: org A has a named queue with one running execution
      # and 50+ blocked pending executions. Org B has a simple non-queued task.
      # Workers must skip all of org A's blocked items and claim org B's task.

      user_b = user_fixture(%{email: "orgb-#{System.unique_integer()}@example.com"})
      {:ok, org_b} = Accounts.create_organization(user_b, %{name: "Org B"})

      # Org A: create a task in a named queue
      {:ok, queue_task} =
        Tasks.create_task(org_a, %{
          name: "Queued Task",
          url: "https://example.com/queue",
          schedule_type: "once",
          scheduled_at: DateTime.utc_now(),
          queue: "slow-queue"
        })

      past = DateTime.add(DateTime.utc_now(), -120, :second)

      # Create one execution and claim it (now running, blocks the queue)
      {:ok, _first} = Executions.create_execution_for_task(queue_task, past)
      assert {:ok, running} = Executions.claim_next_execution()
      assert running.task_id == queue_task.id

      # Create 50 more pending executions in the same queue (all blocked)
      for i <- 1..50 do
        scheduled = DateTime.add(past, i, :second)
        {:ok, _} = Executions.create_execution_for_task(queue_task, scheduled)
      end

      # Org B: create a simple non-queued task with a pending execution
      {:ok, org_b_task} =
        Tasks.create_task(org_b, %{
          name: "Org B Task",
          url: "https://example.com/orgb",
          schedule_type: "once",
          scheduled_at: DateTime.utc_now()
        })

      org_b_scheduled = DateTime.add(DateTime.utc_now(), -10, :second)
      {:ok, _org_b_exec} = Executions.create_execution_for_task(org_b_task, org_b_scheduled)

      # The critical assertion: workers must skip all 50 blocked executions
      # and claim org B's task
      assert {:ok, claimed} = Executions.claim_next_execution()
      assert claimed != nil
      assert claimed.task_id == org_b_task.id
    end

    test "claim_next_execution/0 skips blocked queue from one org and claims from another org's queue",
         %{organization: org_a} do
      # Both orgs use named queues. Org A's queue is blocked, org B's is not.
      user_b = user_fixture(%{email: "orgb2-#{System.unique_integer()}@example.com"})
      {:ok, org_b} = Accounts.create_organization(user_b, %{name: "Org B Queued"})

      {:ok, task_a} =
        Tasks.create_task(org_a, %{
          name: "Org A Queued",
          url: "https://example.com/a",
          schedule_type: "once",
          scheduled_at: DateTime.utc_now(),
          queue: "org-a-queue"
        })

      {:ok, task_b} =
        Tasks.create_task(org_b, %{
          name: "Org B Queued",
          url: "https://example.com/b",
          schedule_type: "once",
          scheduled_at: DateTime.utc_now(),
          queue: "org-b-queue"
        })

      past = DateTime.add(DateTime.utc_now(), -60, :second)

      # Org A: claim one (running), create another (blocked)
      {:ok, _} = Executions.create_execution_for_task(task_a, past)
      assert {:ok, running} = Executions.claim_next_execution()
      assert running.task_id == task_a.id

      {:ok, _} = Executions.create_execution_for_task(task_a, past)

      # Org B: one pending execution in its own queue (not blocked)
      {:ok, _} = Executions.create_execution_for_task(task_b, past)

      # Should claim org B's execution, not return nil
      assert {:ok, claimed} = Executions.claim_next_execution()
      assert claimed.task_id == task_b.id
    end

    test "claim_next_execution/0 enforces per-org concurrency limit", %{
      organization: org_a
    } do
      # Org A has many tasks
      tasks_a =
        for i <- 1..7 do
          {:ok, task} =
            Tasks.create_task(org_a, %{
              name: "Org A Task #{i}",
              url: "https://example.com/a/#{i}",
              schedule_type: "once",
              scheduled_at: DateTime.utc_now()
            })

          task
        end

      # Org B has one task
      user_b = user_fixture(%{email: "orgb-fair-#{System.unique_integer()}@example.com"})
      {:ok, org_b} = Accounts.create_organization(user_b, %{name: "Org B Fair"})

      {:ok, task_b} =
        Tasks.create_task(org_b, %{
          name: "Org B Task",
          url: "https://example.com/b",
          schedule_type: "once",
          scheduled_at: DateTime.utc_now()
        })

      past = DateTime.add(DateTime.utc_now(), -60, :second)

      # Create executions for all tasks
      for task <- tasks_a do
        {:ok, _} = Executions.create_execution_for_task(task, past)
      end

      {:ok, _} = Executions.create_execution_for_task(task_b, past)

      # Claim 5 executions for org A (hitting the concurrency limit)
      running_a =
        for _ <- 1..5 do
          {:ok, claimed} = Executions.claim_next_execution()
          assert claimed.task.organization_id == org_a.id
          claimed
        end

      # Next claim should skip org A (at limit) and pick org B
      assert {:ok, claimed} = Executions.claim_next_execution()
      assert claimed.task.organization_id == org_b.id

      # Complete one org A execution, then org A should be claimable again
      {:ok, _} = Executions.complete_execution(hd(running_a), %{status_code: 200})
      assert {:ok, claimed} = Executions.claim_next_execution()
      assert claimed.task.organization_id == org_a.id
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

  describe "paused queue filter" do
    setup do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Pause Test Org"})

      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Queued Task",
          url: "https://example.com/webhook",
          schedule_type: "once",
          scheduled_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          queue: "my-queue"
        })

      %{organization: org, task: task}
    end

    test "claim_next_execution skips paused queue executions", %{
      organization: org,
      task: task
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, _exec} = Executions.create_execution_for_task(task, now)

      # Pause the queue
      Prikke.Queues.pause_queue(org, "my-queue")

      # Should NOT claim the execution (queue is paused)
      assert {:ok, nil} = Executions.claim_next_execution()

      # Resume the queue
      Prikke.Queues.resume_queue(org, "my-queue")

      # Should NOW claim the execution
      assert {:ok, execution} = Executions.claim_next_execution()
      assert execution != nil
      assert execution.queue == "my-queue"
    end

    test "claim_next_execution still claims executions without a queue when queues are paused", %{
      organization: org
    } do
      {:ok, no_queue_task} =
        Tasks.create_task(org, %{
          name: "No Queue Task",
          url: "https://example.com/webhook",
          schedule_type: "once",
          scheduled_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, _exec} = Executions.create_execution_for_task(no_queue_task, now)

      # Pause some queue
      Prikke.Queues.pause_queue(org, "some-other-queue")

      # Should still claim the queueless execution
      assert {:ok, execution} = Executions.claim_next_execution()
      assert execution != nil
    end
  end

  describe "list_failed_executions/2" do
    setup do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Failures Org"})

      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Failure Task",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      %{organization: org, task: task}
    end

    test "returns failed and timeout executions", %{organization: org, task: task} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # Create executions with different statuses
      {:ok, exec1} = Executions.create_execution_for_task(task, now)
      {:ok, _} = Executions.fail_execution(exec1, %{error_message: "Connection refused"})

      {:ok, exec2} = Executions.create_execution_for_task(task, DateTime.add(now, 60, :second))
      {:ok, _} = Executions.timeout_execution(exec2)

      {:ok, exec3} = Executions.create_execution_for_task(task, DateTime.add(now, 120, :second))
      {:ok, _} = Executions.complete_execution(exec3, %{status_code: 200})

      failed = Executions.list_failed_executions(org)
      assert length(failed) == 2
      statuses = Enum.map(failed, & &1.status)
      assert "failed" in statuses
      assert "timeout" in statuses
    end

    test "filters by queue", %{organization: org} do
      {:ok, queued_task} =
        Tasks.create_task(org, %{
          name: "Queued Failure",
          url: "https://example.com/webhook",
          schedule_type: "once",
          scheduled_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          queue: "email-queue"
        })

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, exec} = Executions.create_execution_for_task(queued_task, now)
      {:ok, _} = Executions.fail_execution(exec, %{error_message: "Failed"})

      assert length(Executions.list_failed_executions(org, queue: "email-queue")) == 1
      assert length(Executions.list_failed_executions(org, queue: "other-queue")) == 0
    end

    test "preloads task", %{organization: org, task: task} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, exec} = Executions.create_execution_for_task(task, now)
      {:ok, _} = Executions.fail_execution(exec, %{error_message: "Error"})

      [failed] = Executions.list_failed_executions(org)
      assert failed.task.name == "Failure Task"
    end
  end

  describe "retry_execution/1" do
    setup do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Retry Org"})

      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Retry Task",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      %{organization: org, task: task}
    end

    test "creates a new pending execution for the same task", %{task: task} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, exec} = Executions.create_execution_for_task(task, now)
      {:ok, failed} = Executions.fail_execution(exec, %{error_message: "Error"})

      assert {:ok, new_exec} = Executions.retry_execution(failed)
      assert new_exec.task_id == task.id
      assert new_exec.status == "pending"
      assert new_exec.attempt == 1
    end
  end

  describe "bulk_retry_executions/2" do
    setup do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Bulk Retry Org"})

      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Bulk Task",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      %{organization: org, task: task}
    end

    test "retries multiple failed executions", %{organization: org, task: task} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, exec1} = Executions.create_execution_for_task(task, now)
      {:ok, failed1} = Executions.fail_execution(exec1, %{error_message: "Error 1"})

      {:ok, exec2} = Executions.create_execution_for_task(task, DateTime.add(now, 60, :second))
      {:ok, failed2} = Executions.fail_execution(exec2, %{error_message: "Error 2"})

      assert {:ok, 2} = Executions.bulk_retry_executions(org, [failed1.id, failed2.id])
    end

    test "ignores non-failed executions", %{organization: org, task: task} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, exec} = Executions.create_execution_for_task(task, now)
      {:ok, success} = Executions.complete_execution(exec, %{status_code: 200})

      assert {:ok, 0} = Executions.bulk_retry_executions(org, [success.id])
    end

    test "ignores IDs from other orgs", %{task: task} do
      other_org = organization_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, exec} = Executions.create_execution_for_task(task, now)
      {:ok, failed} = Executions.fail_execution(exec, %{error_message: "Error"})

      assert {:ok, 0} = Executions.bulk_retry_executions(other_org, [failed.id])
    end
  end
end
