defmodule Prikke.TasksTest do
  use Prikke.DataCase

  alias Prikke.Tasks
  alias Prikke.Tasks.Task

  import Prikke.AccountsFixtures, only: [organization_fixture: 0, organization_fixture: 1]
  import Prikke.TasksFixtures

  describe "list_tasks/1" do
    test "returns all tasks for an organization" do
      org = organization_fixture()
      other_org = organization_fixture()

      task = task_fixture(org)
      _other_task = task_fixture(other_org)

      assert Tasks.list_tasks(org) == [task]
    end

    test "returns all tasks for an organization (multiple)" do
      org = organization_fixture()
      task1 = task_fixture(org, %{name: "First"})
      task2 = task_fixture(org, %{name: "Second"})

      tasks = Tasks.list_tasks(org)
      assert length(tasks) == 2
      assert Enum.any?(tasks, &(&1.id == task1.id))
      assert Enum.any?(tasks, &(&1.id == task2.id))
    end

    test "filters by queue name" do
      org = organization_fixture()
      task_with_queue = task_fixture(org, %{name: "Queued", queue: "payments"})
      _task_without_queue = task_fixture(org, %{name: "No Queue"})
      _task_other_queue = task_fixture(org, %{name: "Other Queue", queue: "emails"})

      tasks = Tasks.list_tasks(org, queue: "payments")
      assert length(tasks) == 1
      assert hd(tasks).id == task_with_queue.id
    end

    test "filters for tasks with no queue using 'none'" do
      org = organization_fixture()
      _task_with_queue = task_fixture(org, %{name: "Queued", queue: "payments"})
      task_without_queue = task_fixture(org, %{name: "No Queue"})

      tasks = Tasks.list_tasks(org, queue: "none")
      assert length(tasks) == 1
      assert hd(tasks).id == task_without_queue.id
    end

    test "returns all tasks when queue option is nil" do
      org = organization_fixture()
      task_fixture(org, %{name: "Queued", queue: "payments"})
      task_fixture(org, %{name: "No Queue"})

      tasks = Tasks.list_tasks(org, queue: nil)
      assert length(tasks) == 2
    end

    test "filters by type 'cron' returns only recurring tasks" do
      org = organization_fixture()
      cron_task = task_fixture(org, %{name: "Cron Task"})
      _once_task = once_task_fixture(org, %{name: "Once Task"})

      tasks = Tasks.list_tasks(org, type: "cron")
      assert length(tasks) == 1
      assert hd(tasks).id == cron_task.id
    end

    test "filters by type 'once' returns only one-time tasks" do
      org = organization_fixture()
      _cron_task = task_fixture(org, %{name: "Cron Task"})
      once_task = once_task_fixture(org, %{name: "Once Task"})

      tasks = Tasks.list_tasks(org, type: "once")
      assert length(tasks) == 1
      assert hd(tasks).id == once_task.id
    end

    test "returns all tasks when type option is nil" do
      org = organization_fixture()
      task_fixture(org, %{name: "Cron Task"})
      once_task_fixture(org, %{name: "Once Task"})

      tasks = Tasks.list_tasks(org, type: nil)
      assert length(tasks) == 2
    end

    test "combines queue and type filters" do
      org = organization_fixture()
      _cron_no_queue = task_fixture(org, %{name: "Cron No Queue"})
      cron_with_queue = task_fixture(org, %{name: "Cron Payments", queue: "payments"})
      _once_with_queue = once_task_fixture(org, %{name: "Once Payments", queue: "payments"})

      tasks = Tasks.list_tasks(org, queue: "payments", type: "cron")
      assert length(tasks) == 1
      assert hd(tasks).id == cron_with_queue.id
    end
  end

  describe "list_queues/1" do
    test "returns distinct queue names" do
      org = organization_fixture()
      task_fixture(org, %{name: "T1", queue: "payments"})
      task_fixture(org, %{name: "T2", queue: "emails"})
      task_fixture(org, %{name: "T3", queue: "payments"})
      task_fixture(org, %{name: "T4"})

      queues = Tasks.list_queues(org)
      assert queues == ["emails", "payments"]
    end

    test "returns empty list when no tasks have queues" do
      org = organization_fixture()
      task_fixture(org)

      assert Tasks.list_queues(org) == []
    end

    test "does not return queues from other organizations" do
      org = organization_fixture()
      other_org = organization_fixture()
      task_fixture(org, %{queue: "payments"})
      task_fixture(other_org, %{queue: "emails"})

      assert Tasks.list_queues(org) == ["payments"]
    end
  end

  describe "list_enabled_tasks/1" do
    test "returns only enabled tasks" do
      org = organization_fixture()
      enabled_task = task_fixture(org, %{enabled: true})
      _disabled_task = task_fixture(org, %{enabled: false})

      assert Tasks.list_enabled_tasks(org) == [enabled_task]
    end
  end

  describe "get_task!/2" do
    test "returns the task with given id" do
      org = organization_fixture()
      task = task_fixture(org)
      assert Tasks.get_task!(org, task.id) == task
    end

    test "raises for task from different organization" do
      org = organization_fixture()
      other_org = organization_fixture()
      task = task_fixture(org)

      assert_raise Ecto.NoResultsError, fn ->
        Tasks.get_task!(other_org, task.id)
      end
    end
  end

  describe "get_task/2" do
    test "returns the task with given id" do
      org = organization_fixture()
      task = task_fixture(org)
      assert Tasks.get_task(org, task.id) == task
    end

    test "returns nil for task from different organization" do
      org = organization_fixture()
      other_org = organization_fixture()
      task = task_fixture(org)

      assert Tasks.get_task(other_org, task.id) == nil
    end
  end

  describe "create_task/2" do
    test "with valid cron data creates a task (free tier, hourly)" do
      org = organization_fixture()

      valid_attrs = %{
        name: "My Cron Task",
        url: "https://example.com/webhook",
        method: "POST",
        headers: %{"Authorization" => "Bearer token"},
        body: ~s({"key": "value"}),
        schedule_type: "cron",
        cron_expression: "0 * * * *"
      }

      assert {:ok, %Task{} = task} = Tasks.create_task(org, valid_attrs)
      assert task.name == "My Cron Task"
      assert task.url == "https://example.com/webhook"
      assert task.method == "POST"
      assert task.headers == %{"Authorization" => "Bearer token"}
      assert task.schedule_type == "cron"
      assert task.cron_expression == "0 * * * *"
      assert task.organization_id == org.id
      assert task.enabled == true
      assert task.interval_minutes == 60
    end

    test "with valid cron data creates a task (pro tier, per-minute)" do
      org = organization_fixture(tier: "pro")

      valid_attrs = %{
        name: "My Cron Task",
        url: "https://example.com/webhook",
        method: "POST",
        schedule_type: "cron",
        cron_expression: "*/5 * * * *"
      }

      assert {:ok, %Task{} = task} = Tasks.create_task(org, valid_attrs)
      assert task.cron_expression == "*/5 * * * *"
      assert task.interval_minutes == 5
    end

    test "with valid once data creates a task" do
      org = organization_fixture()
      scheduled_at = DateTime.add(DateTime.utc_now(), 3600, :second)

      valid_attrs = %{
        name: "One-time Task",
        url: "https://example.com/run-once",
        schedule_type: "once",
        scheduled_at: scheduled_at
      }

      assert {:ok, %Task{} = task} = Tasks.create_task(org, valid_attrs)
      assert task.name == "One-time Task"
      assert task.schedule_type == "once"
      assert task.scheduled_at == DateTime.truncate(scheduled_at, :second)
      assert task.interval_minutes == nil
    end

    test "with valid callback_url creates a task" do
      org = organization_fixture()

      attrs = %{
        name: "Callback Task",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "0 * * * *",
        callback_url: "https://example.com/callback"
      }

      assert {:ok, %Task{} = task} = Tasks.create_task(org, attrs)
      assert task.callback_url == "https://example.com/callback"
    end

    test "with invalid callback_url returns error" do
      org = organization_fixture()

      attrs = %{
        name: "Bad Callback Task",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "0 * * * *",
        callback_url: "not-a-url"
      }

      assert {:error, changeset} = Tasks.create_task(org, attrs)
      assert "must be a valid HTTP or HTTPS URL" in errors_on(changeset).callback_url
    end

    test "with nil callback_url creates a task without callback" do
      org = organization_fixture()

      attrs = %{
        name: "No Callback Task",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "0 * * * *"
      }

      assert {:ok, %Task{} = task} = Tasks.create_task(org, attrs)
      assert task.callback_url == nil
    end

    test "with invalid URL returns error" do
      org = organization_fixture()

      invalid_attrs = %{
        name: "Bad URL Task",
        url: "not-a-url",
        schedule_type: "cron",
        cron_expression: "0 * * * *"
      }

      assert {:error, changeset} = Tasks.create_task(org, invalid_attrs)
      assert "must be a valid HTTP or HTTPS URL" in errors_on(changeset).url
    end

    test "with invalid cron expression returns error" do
      org = organization_fixture()

      invalid_attrs = %{
        name: "Bad Cron Task",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "not valid cron"
      }

      assert {:error, changeset} = Tasks.create_task(org, invalid_attrs)
      assert "is not a valid cron expression" in errors_on(changeset).cron_expression
    end

    test "with past scheduled_at returns error" do
      org = organization_fixture()
      past_time = DateTime.add(DateTime.utc_now(), -3600, :second)

      invalid_attrs = %{
        name: "Past Task",
        url: "https://example.com/webhook",
        schedule_type: "once",
        scheduled_at: past_time
      }

      assert {:error, changeset} = Tasks.create_task(org, invalid_attrs)
      assert "must be in the future" in errors_on(changeset).scheduled_at
    end

    test "cron task without cron_expression returns error" do
      org = organization_fixture()

      invalid_attrs = %{
        name: "No Cron Expression",
        url: "https://example.com/webhook",
        schedule_type: "cron"
      }

      assert {:error, changeset} = Tasks.create_task(org, invalid_attrs)
      assert "can't be blank" in errors_on(changeset).cron_expression
    end

    test "once task without scheduled_at returns error" do
      org = organization_fixture()

      invalid_attrs = %{
        name: "No Scheduled Time",
        url: "https://example.com/webhook",
        schedule_type: "once"
      }

      assert {:error, changeset} = Tasks.create_task(org, invalid_attrs)
      assert "can't be blank" in errors_on(changeset).scheduled_at
    end

    test "with missing required fields returns error" do
      org = organization_fixture()

      assert {:error, changeset} = Tasks.create_task(org, %{})
      assert "can't be blank" in errors_on(changeset).url
      assert "can't be blank" in errors_on(changeset).schedule_type
    end

    test "free tier rejects per-minute cron tasks" do
      org = organization_fixture(tier: "free")

      attrs = %{
        name: "Minute Task",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "* * * * *"
      }

      assert {:error, changeset} = Tasks.create_task(org, attrs)

      assert "Free plan only allows hourly or less frequent schedules" <> _ =
               hd(errors_on(changeset).cron_expression)
    end

    test "free tier allows hourly cron tasks" do
      org = organization_fixture(tier: "free")

      attrs = %{
        name: "Hourly Task",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "0 * * * *"
      }

      assert {:ok, task} = Tasks.create_task(org, attrs)
      assert task.interval_minutes == 60
    end

    test "pro tier allows per-minute cron tasks" do
      org = organization_fixture(tier: "pro")

      attrs = %{
        name: "Minute Task",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "* * * * *"
      }

      assert {:ok, task} = Tasks.create_task(org, attrs)
      assert task.interval_minutes == 1
    end
  end

  describe "update_task/3" do
    test "with valid data updates the task" do
      org = organization_fixture()
      task = task_fixture(org)

      update_attrs = %{
        name: "Updated Name",
        enabled: false
      }

      assert {:ok, %Task{} = updated} = Tasks.update_task(org, task, update_attrs)
      assert updated.name == "Updated Name"
      assert updated.enabled == false
    end

    test "with invalid data returns error changeset" do
      org = organization_fixture()
      task = task_fixture(org)

      assert {:error, changeset} = Tasks.update_task(org, task, %{url: "bad-url"})
      assert "must be a valid HTTP or HTTPS URL" in errors_on(changeset).url

      # Task should be unchanged
      assert Tasks.get_task!(org, task.id) == task
    end

    test "with wrong organization raises" do
      org = organization_fixture()
      other_org = organization_fixture()
      task = task_fixture(org)

      assert_raise ArgumentError, "task does not belong to organization", fn ->
        Tasks.update_task(other_org, task, %{name: "Hacked"})
      end
    end

    test "free tier rejects updating to per-minute cron" do
      org = organization_fixture(tier: "free")
      task = task_fixture(org, %{cron_expression: "0 * * * *"})

      # Try to update to per-minute cron
      assert {:error, changeset} = Tasks.update_task(org, task, %{cron_expression: "* * * * *"})

      assert "Free plan only allows hourly or less frequent schedules" <> _ =
               hd(errors_on(changeset).cron_expression)

      # Task should be unchanged
      unchanged_task = Tasks.get_task!(org, task.id)
      assert unchanged_task.cron_expression == "0 * * * *"
    end
  end

  describe "delete_task/2" do
    test "soft-deletes the task (sets deleted_at, not visible in queries)" do
      org = organization_fixture()
      task = task_fixture(org)

      assert {:ok, %Task{} = deleted} = Tasks.delete_task(org, task)
      assert deleted.deleted_at != nil
      assert deleted.enabled == false
      assert deleted.next_run_at == nil

      # Not visible in normal queries
      assert_raise Ecto.NoResultsError, fn -> Tasks.get_task!(org, task.id) end
      assert Tasks.get_task(org, task.id) == nil
      assert Tasks.list_tasks(org) == []
      assert Tasks.count_tasks(org) == 0
    end

    test "soft-deleted task still exists in database" do
      org = organization_fixture()
      task = task_fixture(org)

      {:ok, _deleted} = Tasks.delete_task(org, task)

      # Direct DB query confirms it still exists
      assert Prikke.Repo.get(Task, task.id) != nil
    end

    test "cancels pending executions on delete" do
      org = organization_fixture()
      task = task_fixture(org)

      # Create a pending execution
      {:ok, _exec} =
        Prikke.Executions.create_execution_for_task(task, DateTime.utc_now())

      assert Prikke.Executions.count_task_executions(task) == 1

      {:ok, _deleted} = Tasks.delete_task(org, task)

      # Pending execution should be removed
      assert Prikke.Executions.count_task_executions(task) == 0
    end

    test "with wrong organization raises" do
      org = organization_fixture()
      other_org = organization_fixture()
      task = task_fixture(org)

      assert_raise ArgumentError, "task does not belong to organization", fn ->
        Tasks.delete_task(other_org, task)
      end
    end

    test "soft-deleted tasks are excluded from list_queues" do
      org = organization_fixture()
      task = task_fixture(org, %{name: "Queued", queue: "payments"})

      assert Tasks.list_queues(org) == ["payments"]

      Tasks.delete_task(org, task)
      assert Tasks.list_queues(org) == []
    end

    test "soft-deleted tasks are excluded from count_tasks_summary" do
      org = organization_fixture()
      task_fixture(org)

      summary = Tasks.count_tasks_summary(org)
      assert summary.total == 1

      [task] = Tasks.list_tasks(org)
      Tasks.delete_task(org, task)

      summary = Tasks.count_tasks_summary(org)
      assert summary.total == 0
    end

    test "soft-deleted tasks are excluded from list_upcoming_tasks" do
      org = organization_fixture()
      task = task_fixture(org)

      assert Enum.any?(Tasks.list_upcoming_tasks(), &(&1.id == task.id))

      Tasks.delete_task(org, task)

      refute Enum.any?(Tasks.list_upcoming_tasks(), &(&1.id == task.id))
    end
  end

  describe "purge_deleted_tasks/2" do
    test "permanently deletes soft-deleted tasks older than retention" do
      org = organization_fixture()
      task = task_fixture(org)

      # Soft-delete the task
      {:ok, deleted} = Tasks.delete_task(org, task)

      # Set deleted_at to 10 days ago
      old_deleted_at =
        DateTime.utc_now()
        |> DateTime.add(-10, :day)
        |> DateTime.truncate(:second)

      {:ok, _} =
        deleted
        |> Ecto.Changeset.change(deleted_at: old_deleted_at)
        |> Prikke.Repo.update()

      # Purge with 7-day retention
      {purged, _} = Tasks.purge_deleted_tasks(org, 7)
      assert purged == 1

      # Task should be gone from DB
      assert Prikke.Repo.get(Task, task.id) == nil
    end

    test "does not purge recently deleted tasks" do
      org = organization_fixture()
      task = task_fixture(org)

      {:ok, _deleted} = Tasks.delete_task(org, task)

      # Purge with 7-day retention (task was just deleted)
      {purged, _} = Tasks.purge_deleted_tasks(org, 7)
      assert purged == 0

      # Task should still exist
      assert Prikke.Repo.get(Task, task.id) != nil
    end

    test "does not purge non-deleted tasks" do
      org = organization_fixture()
      _task = task_fixture(org)

      {purged, _} = Tasks.purge_deleted_tasks(org, 0)
      assert purged == 0
    end
  end

  describe "toggle_task/2" do
    test "toggles enabled to disabled" do
      org = organization_fixture()
      task = task_fixture(org, %{enabled: true})

      assert {:ok, %Task{enabled: false}} = Tasks.toggle_task(org, task)
    end

    test "toggles disabled to enabled" do
      org = organization_fixture()
      task = task_fixture(org, %{enabled: false})

      assert {:ok, %Task{enabled: true}} = Tasks.toggle_task(org, task)
    end

    test "re-enabling a cron task resets next_run_at to future time (skips missed executions)" do
      org = organization_fixture()
      # Create a cron task that runs every hour
      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Hourly Task",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      # Disable the task
      {:ok, disabled_task} = Tasks.toggle_task(org, task)
      assert disabled_task.enabled == false

      # Manually set next_run_at to a past time (simulating missed executions)
      past_time =
        DateTime.utc_now()
        |> DateTime.add(-7200, :second)
        |> DateTime.truncate(:second)

      {:ok, task_with_past_next_run} =
        disabled_task
        |> Ecto.Changeset.change(next_run_at: past_time)
        |> Prikke.Repo.update()

      assert DateTime.compare(task_with_past_next_run.next_run_at, DateTime.utc_now()) == :lt

      # Re-enable the task
      {:ok, re_enabled_task} = Tasks.toggle_task(org, task_with_past_next_run)
      assert re_enabled_task.enabled == true

      # next_run_at should now be in the future (not the past time)
      assert re_enabled_task.next_run_at != nil
      assert DateTime.compare(re_enabled_task.next_run_at, DateTime.utc_now()) == :gt
    end

    test "re-enabling a one-time task with future scheduled_at keeps it scheduled" do
      org = organization_fixture()
      future_time = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Future One-time Task",
          url: "https://example.com/webhook",
          schedule_type: "once",
          scheduled_at: future_time
        })

      # Disable and re-enable
      {:ok, disabled_task} = Tasks.toggle_task(org, task)
      {:ok, re_enabled_task} = Tasks.toggle_task(org, disabled_task)

      assert re_enabled_task.enabled == true
      assert re_enabled_task.next_run_at != nil
      # Should be the original scheduled_at time
      assert DateTime.compare(re_enabled_task.next_run_at, DateTime.utc_now()) == :gt
    end

    test "re-enabling a one-time task with past scheduled_at does not schedule it" do
      org = organization_fixture()

      future_time =
        DateTime.utc_now()
        |> DateTime.add(3600, :second)
        |> DateTime.truncate(:second)

      {:ok, task} =
        Tasks.create_task(org, %{
          name: "One-time Task",
          url: "https://example.com/webhook",
          schedule_type: "once",
          scheduled_at: future_time
        })

      # Disable the task
      {:ok, disabled_task} = Tasks.toggle_task(org, task)

      # Manually set scheduled_at to a past time (simulating time passing)
      past_time =
        DateTime.utc_now()
        |> DateTime.add(-3600, :second)
        |> DateTime.truncate(:second)

      {:ok, task_with_past_scheduled_at} =
        disabled_task
        |> Ecto.Changeset.change(scheduled_at: past_time, next_run_at: nil)
        |> Prikke.Repo.update()

      # Re-enable the task
      {:ok, re_enabled_task} = Tasks.toggle_task(org, task_with_past_scheduled_at)
      assert re_enabled_task.enabled == true

      # next_run_at should be nil since scheduled_at is in the past
      assert re_enabled_task.next_run_at == nil
    end
  end

  describe "change_task/2" do
    test "returns a task changeset" do
      task = task_fixture()
      assert %Ecto.Changeset{} = Tasks.change_task(task)
    end
  end

  describe "count_tasks/1" do
    test "counts all tasks for organization" do
      org = organization_fixture()
      assert Tasks.count_tasks(org) == 0

      task_fixture(org)
      task_fixture(org)
      assert Tasks.count_tasks(org) == 2
    end
  end

  describe "count_enabled_tasks/1" do
    test "counts only enabled tasks" do
      org = organization_fixture()
      task_fixture(org, %{enabled: true})
      task_fixture(org, %{enabled: false})

      assert Tasks.count_enabled_tasks(org) == 1
    end
  end

  describe "clone_task/3" do
    test "clones a cron task with (copy) suffix" do
      org = organization_fixture()

      task =
        task_fixture(org, %{
          name: "My Cron Task",
          url: "https://example.com/webhook",
          method: "POST"
        })

      assert {:ok, %Task{} = cloned} = Tasks.clone_task(org, task)
      assert cloned.name == "My Cron Task (copy)"
      assert cloned.url == task.url
      assert cloned.method == task.method
      assert cloned.headers == task.headers
      assert cloned.body == task.body
      assert cloned.schedule_type == task.schedule_type
      assert cloned.cron_expression == task.cron_expression
      assert cloned.timeout_ms == task.timeout_ms
      assert cloned.retry_attempts == task.retry_attempts
      assert cloned.enabled == true
      assert cloned.id != task.id
    end

    test "clones a one-time task with future scheduled_at" do
      org = organization_fixture()
      future_time = DateTime.add(DateTime.utc_now(), 7200, :second)

      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Future One-time",
          url: "https://example.com/webhook",
          schedule_type: "once",
          scheduled_at: future_time
        })

      assert {:ok, %Task{} = cloned} = Tasks.clone_task(org, task)
      assert cloned.name == "Future One-time (copy)"
      assert cloned.schedule_type == "once"
      # Should keep the original future time
      assert DateTime.compare(cloned.scheduled_at, DateTime.utc_now()) == :gt
    end

    test "clones a one-time task with past scheduled_at adjusts to 1 hour from now" do
      org = organization_fixture()
      future_time = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Past One-time",
          url: "https://example.com/webhook",
          schedule_type: "once",
          scheduled_at: future_time
        })

      # Manually set scheduled_at to the past
      past_time = DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)

      {:ok, task} =
        task
        |> Ecto.Changeset.change(scheduled_at: past_time, next_run_at: nil)
        |> Prikke.Repo.update()

      assert {:ok, %Task{} = cloned} = Tasks.clone_task(org, task)
      assert cloned.name == "Past One-time (copy)"
      # Should be adjusted to ~1 hour from now
      assert DateTime.compare(cloned.scheduled_at, DateTime.utc_now()) == :gt
    end
  end

  describe "test_webhook/1" do
    test "returns success for a valid URL" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/test", fn conn ->
        Plug.Conn.resp(conn, 200, "OK")
      end)

      assert {:ok, result} = Tasks.test_webhook(%{url: "http://localhost:#{bypass.port}/test"})
      assert result.status == 200
      assert result.body == "OK"
      assert is_integer(result.duration_ms)
      assert result.duration_ms >= 0
    end

    test "returns error for connection failure" do
      assert {:error, message} = Tasks.test_webhook(%{url: "http://localhost:1/nope"})
      assert is_binary(message)
      assert message =~ "Connection error" or message =~ "Request failed"
    end

    test "sends correct method" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/test", fn conn ->
        assert conn.method == "POST"
        Plug.Conn.resp(conn, 201, "Created")
      end)

      assert {:ok, result} =
               Tasks.test_webhook(%{
                 url: "http://localhost:#{bypass.port}/test",
                 method: "POST",
                 body: "hello"
               })

      assert result.status == 201
    end

    test "sends correct headers" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/test", fn conn ->
        auth = Enum.find_value(conn.req_headers, fn {k, v} -> if k == "x-custom", do: v end)
        assert auth == "test-value"
        Plug.Conn.resp(conn, 200, "OK")
      end)

      assert {:ok, _result} =
               Tasks.test_webhook(%{
                 url: "http://localhost:#{bypass.port}/test",
                 headers: %{"X-Custom" => "test-value"}
               })
    end

    test "sends request body for POST" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/test", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body == ~s({"key":"value"})
        Plug.Conn.resp(conn, 200, "OK")
      end)

      assert {:ok, _result} =
               Tasks.test_webhook(%{
                 url: "http://localhost:#{bypass.port}/test",
                 method: "POST",
                 body: ~s({"key":"value"})
               })
    end

    test "caps timeout at 10 seconds" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/test", fn conn ->
        Plug.Conn.resp(conn, 200, "OK")
      end)

      # Even if we pass a large timeout, it should be capped
      assert {:ok, _result} =
               Tasks.test_webhook(%{
                 url: "http://localhost:#{bypass.port}/test",
                 timeout_ms: 300_000
               })
    end

    test "truncates large response bodies" do
      bypass = Bypass.open()
      large_body = String.duplicate("x", 5_000)

      Bypass.expect_once(bypass, "GET", "/test", fn conn ->
        Plug.Conn.resp(conn, 200, large_body)
      end)

      assert {:ok, result} =
               Tasks.test_webhook(%{url: "http://localhost:#{bypass.port}/test"})

      # 4KB = 4096 bytes + "... [truncated]" suffix
      assert byte_size(result.body) < byte_size(large_body)
      assert result.body =~ "... [truncated]"
    end

    test "returns non-2xx status codes" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/test", fn conn ->
        Plug.Conn.resp(conn, 404, "Not Found")
      end)

      assert {:ok, result} = Tasks.test_webhook(%{url: "http://localhost:#{bypass.port}/test"})
      assert result.status == 404
      assert result.body == "Not Found"
    end
  end

  describe "interval_minutes calculation" do
    test "every minute cron (pro tier)" do
      org = organization_fixture(tier: "pro")

      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Every Minute",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "* * * * *"
        })

      assert task.interval_minutes == 1
    end

    test "hourly cron" do
      org = organization_fixture()

      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Hourly",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      assert task.interval_minutes == 60
    end

    test "daily cron" do
      org = organization_fixture()

      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Daily",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 9 * * *"
        })

      assert task.interval_minutes == 24 * 60
    end
  end

  describe "response assertions" do
    test "creating a task with expected_status_codes stores them" do
      org = organization_fixture()

      attrs = %{
        name: "Assertion Task",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "0 * * * *",
        expected_status_codes: "200,201"
      }

      assert {:ok, %Task{} = task} = Tasks.create_task(org, attrs)
      assert task.expected_status_codes == "200,201"
    end

    test "creating a task with expected_body_pattern stores it" do
      org = organization_fixture()

      attrs = %{
        name: "Body Assertion Task",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "0 * * * *",
        expected_body_pattern: "success"
      }

      assert {:ok, %Task{} = task} = Tasks.create_task(org, attrs)
      assert task.expected_body_pattern == "success"
    end

    test "default values are nil" do
      org = organization_fixture()

      attrs = %{
        name: "Default Assertion Task",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "0 * * * *"
      }

      assert {:ok, %Task{} = task} = Tasks.create_task(org, attrs)
      assert task.expected_status_codes == nil
      assert task.expected_body_pattern == nil
    end

    test "invalid status codes are rejected" do
      org = organization_fixture()

      attrs = %{
        name: "Bad Status Codes",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "0 * * * *",
        expected_status_codes: "abc"
      }

      assert {:error, changeset} = Tasks.create_task(org, attrs)

      assert "must be comma-separated HTTP status codes (100-599)" in errors_on(changeset).expected_status_codes
    end

    test "status code out of range is rejected" do
      org = organization_fixture()

      attrs = %{
        name: "Out of Range",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "0 * * * *",
        expected_status_codes: "200,999"
      }

      assert {:error, changeset} = Tasks.create_task(org, attrs)

      assert "must be comma-separated HTTP status codes (100-599)" in errors_on(changeset).expected_status_codes
    end

    test "valid comma-separated status codes are accepted" do
      org = organization_fixture()

      attrs = %{
        name: "Multi Codes",
        url: "https://example.com/webhook",
        schedule_type: "cron",
        cron_expression: "0 * * * *",
        expected_status_codes: "200, 201, 204"
      }

      assert {:ok, %Task{} = task} = Tasks.create_task(org, attrs)
      assert task.expected_status_codes == "200, 201, 204"
    end
  end

  describe "list_upcoming_tasks/1" do
    test "returns tasks with next_run_at in the future" do
      org = organization_fixture()
      task = task_fixture(org)

      # task_fixture creates a cron task, which should have next_run_at set in the future
      assert task.next_run_at != nil
      assert DateTime.compare(task.next_run_at, DateTime.utc_now()) == :gt

      upcoming = Tasks.list_upcoming_tasks()
      assert length(upcoming) >= 1
      assert Enum.any?(upcoming, &(&1.id == task.id))
    end

    test "does not return tasks with next_run_at in the past" do
      org = organization_fixture()
      task = task_fixture(org)

      # Set next_run_at to the past
      past = DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)

      {:ok, _} =
        task
        |> Ecto.Changeset.change(next_run_at: past)
        |> Prikke.Repo.update()

      upcoming = Tasks.list_upcoming_tasks()
      refute Enum.any?(upcoming, &(&1.id == task.id))
    end

    test "does not return tasks with nil next_run_at" do
      org = organization_fixture()
      task = task_fixture(org)

      {:ok, _} =
        task
        |> Ecto.Changeset.change(next_run_at: nil)
        |> Prikke.Repo.update()

      upcoming = Tasks.list_upcoming_tasks()
      refute Enum.any?(upcoming, &(&1.id == task.id))
    end

    test "orders by next_run_at ascending (soonest first)" do
      org = organization_fixture()
      task1 = task_fixture(org, %{name: "Later", cron_expression: "0 0 * * *"})
      task2 = task_fixture(org, %{name: "Sooner", cron_expression: "0 * * * *"})

      upcoming = Tasks.list_upcoming_tasks()
      ids = Enum.map(upcoming, & &1.id)

      idx1 = Enum.find_index(ids, &(&1 == task1.id))
      idx2 = Enum.find_index(ids, &(&1 == task2.id))

      # The task with sooner next_run_at should appear first
      if task2.next_run_at && task1.next_run_at &&
           DateTime.compare(task2.next_run_at, task1.next_run_at) == :lt do
        assert idx2 < idx1
      end
    end

    test "respects limit option" do
      org = organization_fixture()
      task_fixture(org, %{name: "Task 1"})
      task_fixture(org, %{name: "Task 2"})
      task_fixture(org, %{name: "Task 3"})

      upcoming = Tasks.list_upcoming_tasks(limit: 2)
      assert length(upcoming) <= 2
    end

    test "preloads organization" do
      org = organization_fixture()
      task_fixture(org)

      [task | _] = Tasks.list_upcoming_tasks()
      assert task.organization != nil
      assert task.organization.id == org.id
    end
  end

  describe "create_batch/3" do
    test "creates N tasks and N executions" do
      org = organization_fixture()

      shared = %{
        "url" => "https://example.com/send-email",
        "method" => "POST",
        "queue" => "newsletter",
        "headers" => %{"Authorization" => "Bearer xxx"}
      }

      items = [
        %{"to" => "user1@example.com"},
        %{"to" => "user2@example.com"},
        %{"to" => "user3@example.com"}
      ]

      assert {:ok, result} = Tasks.create_batch(org, shared, items)
      assert result.created == 3
      assert result.queue == "newsletter"
      assert result.scheduled_for != nil

      # Verify tasks were created
      tasks = Tasks.list_tasks(org, queue: "newsletter")
      assert length(tasks) == 3

      # Verify executions were created
      for task <- tasks do
        execs = Prikke.Executions.list_task_executions(task)
        assert length(execs) == 1
        assert hd(execs).status == "pending"
      end
    end

    test "each task body is the JSON-encoded item" do
      org = organization_fixture()

      shared = %{
        "url" => "https://example.com/api",
        "queue" => "batch-test"
      }

      items = [%{"email" => "alice@example.com", "name" => "Alice"}]

      assert {:ok, _result} = Tasks.create_batch(org, shared, items)

      [task] = Tasks.list_tasks(org, queue: "batch-test")
      assert Jason.decode!(task.body) == %{"email" => "alice@example.com", "name" => "Alice"}
    end

    test "rejects empty items list" do
      org = organization_fixture()

      shared = %{"url" => "https://example.com/api", "queue" => "test"}

      assert {:error, :empty_items} = Tasks.create_batch(org, shared, [])
    end

    test "rejects more than 1000 items" do
      org = organization_fixture()

      shared = %{"url" => "https://example.com/api", "queue" => "test"}
      items = for i <- 1..1001, do: %{"id" => i}

      assert {:error, :too_many_items} = Tasks.create_batch(org, shared, items)
    end

    test "requires url" do
      org = organization_fixture()

      shared = %{"queue" => "test"}
      items = [%{"data" => "value"}]

      assert {:error, :url_required} = Tasks.create_batch(org, shared, items)
    end

    test "requires queue" do
      org = organization_fixture()

      shared = %{"url" => "https://example.com/api"}
      items = [%{"data" => "value"}]

      assert {:error, :queue_required} = Tasks.create_batch(org, shared, items)
    end

    test "validates URL format" do
      org = organization_fixture()

      shared = %{"url" => "not-a-url", "queue" => "test"}
      items = [%{"data" => "value"}]

      assert {:error, :invalid_url} = Tasks.create_batch(org, shared, items)
    end

    test "respects run_at scheduling" do
      org = organization_fixture()

      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      shared = %{
        "url" => "https://example.com/api",
        "queue" => "scheduled-batch",
        "run_at" => DateTime.to_iso8601(future)
      }

      items = [%{"data" => "value"}]

      assert {:ok, result} = Tasks.create_batch(org, shared, items)
      assert DateTime.compare(result.scheduled_for, DateTime.utc_now()) == :gt
    end

    test "respects delay scheduling" do
      org = organization_fixture()

      shared = %{
        "url" => "https://example.com/api",
        "queue" => "delayed-batch",
        "delay" => "5m"
      }

      items = [%{"data" => "value"}]

      assert {:ok, result} = Tasks.create_batch(org, shared, items)

      # Should be scheduled ~5 minutes from now
      diff = DateTime.diff(result.scheduled_for, DateTime.utc_now())
      assert diff >= 290 and diff <= 310
    end

    test "respects monthly execution limit for free tier" do
      org = organization_fixture(tier: "free")

      # Set monthly count close to limit (10_000)
      Prikke.Repo.update_all(
        Ecto.Query.from(o in Prikke.Accounts.Organization, where: o.id == ^org.id),
        set: [monthly_execution_count: 9_999]
      )

      org = Prikke.Repo.reload!(org)

      shared = %{"url" => "https://example.com/api", "queue" => "test"}
      items = [%{"a" => 1}, %{"b" => 2}]

      assert {:error, :monthly_limit_exceeded} = Tasks.create_batch(org, shared, items)
    end
  end

  describe "cancel_tasks_by_queue/2" do
    test "soft-deletes all tasks in queue and cancels pending executions" do
      org = organization_fixture()

      shared = %{
        "url" => "https://example.com/api",
        "queue" => "cancel-test"
      }

      items = [%{"a" => 1}, %{"b" => 2}, %{"c" => 3}]

      {:ok, _result} = Tasks.create_batch(org, shared, items)
      assert length(Tasks.list_tasks(org, queue: "cancel-test")) == 3

      assert {:ok, result} = Tasks.cancel_tasks_by_queue(org, "cancel-test")
      assert result.cancelled == 3

      # Tasks should no longer be visible
      assert Tasks.list_tasks(org, queue: "cancel-test") == []
    end

    test "doesn't touch tasks in other queues" do
      org = organization_fixture()

      {:ok, _} =
        Tasks.create_batch(org, %{"url" => "https://example.com/api", "queue" => "keep"}, [
          %{"a" => 1}
        ])

      {:ok, _} =
        Tasks.create_batch(org, %{"url" => "https://example.com/api", "queue" => "cancel"}, [
          %{"a" => 1}
        ])

      {:ok, result} = Tasks.cancel_tasks_by_queue(org, "cancel")
      assert result.cancelled == 1

      # "keep" queue should be untouched
      assert length(Tasks.list_tasks(org, queue: "keep")) == 1
    end

    test "doesn't touch other orgs' tasks" do
      org1 = organization_fixture()
      org2 = organization_fixture()

      {:ok, _} =
        Tasks.create_batch(org1, %{"url" => "https://example.com/api", "queue" => "shared-name"}, [
          %{"a" => 1}
        ])

      {:ok, _} =
        Tasks.create_batch(org2, %{"url" => "https://example.com/api", "queue" => "shared-name"}, [
          %{"a" => 1}
        ])

      {:ok, result} = Tasks.cancel_tasks_by_queue(org1, "shared-name")
      assert result.cancelled == 1

      # org2's tasks should be untouched
      assert length(Tasks.list_tasks(org2, queue: "shared-name")) == 1
    end

    test "returns zero when no matching tasks" do
      org = organization_fixture()

      assert {:ok, result} = Tasks.cancel_tasks_by_queue(org, "nonexistent")
      assert result.cancelled == 0
    end
  end

  describe "parse_status_codes/1" do
    test "returns empty list for nil" do
      assert Tasks.parse_status_codes(nil) == []
    end

    test "returns empty list for empty string" do
      assert Tasks.parse_status_codes("") == []
    end

    test "parses single code" do
      assert Tasks.parse_status_codes("200") == [200]
    end

    test "parses comma-separated codes with spaces" do
      assert Tasks.parse_status_codes("200, 201, 204") == [200, 201, 204]
    end
  end
end
