defmodule Prikke.NotificationsTest do
  use Prikke.DataCase, async: false

  import Prikke.AccountsFixtures

  alias Prikke.Notifications
  alias Prikke.Tasks
  alias Prikke.Executions
  alias Prikke.Accounts

  describe "send_failure_email/2" do
    setup do
      user = user_fixture()
      # Clear welcome email
      flush_emails()

      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})

      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Test Task",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      {:ok, execution} =
        Executions.create_execution(%{
          task_id: task.id,
          organization_id: task.organization_id,
          scheduled_for: DateTime.utc_now()
        })

      {:ok, execution} =
        Executions.fail_execution(execution, %{
          status_code: 500,
          error_message: "Internal Server Error"
        })

      execution = Executions.get_execution_with_task(execution.id)

      %{org: org, task: task, execution: execution}
    end

    test "sends email with task failure details", %{execution: execution} do
      to_email = "alerts@example.com"
      assert :ok = Notifications.send_failure_email(execution, to_email)

      # Find the failure email
      emails = collect_emails()

      failure_email =
        Enum.find(emails, fn email ->
          String.contains?(email.subject, "Task failed")
        end)

      assert failure_email != nil, "Expected failure email to be sent"
      assert failure_email.to == [{"", to_email}]
      assert failure_email.subject =~ "Test Task"
      assert failure_email.text_body =~ "500"
      assert failure_email.text_body =~ "Internal Server Error"
    end
  end

  describe "send_failure_webhook/2" do
    setup do
      user = user_fixture()
      flush_emails()

      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})

      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Test Task",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      {:ok, execution} =
        Executions.create_execution(%{
          task_id: task.id,
          organization_id: task.organization_id,
          scheduled_for: DateTime.utc_now()
        })

      {:ok, execution} =
        Executions.fail_execution(execution, %{
          status_code: 500,
          error_message: "Internal Server Error"
        })

      execution = Executions.get_execution_with_task(execution.id)

      %{org: org, task: task, execution: execution}
    end

    test "sends webhook with generic JSON payload", %{execution: execution} do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/webhook", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        assert payload["event"] == "task.failed"
        assert payload["task"]["name"] == "Test Task"
        assert payload["execution"]["status"] == "failed"
        assert payload["execution"]["status_code"] == 500

        Plug.Conn.resp(conn, 200, "OK")
      end)

      webhook_url = "http://localhost:#{bypass.port}/webhook"
      assert :ok = Notifications.send_failure_webhook(execution, webhook_url)
    end

    test "handles webhook failure gracefully", %{execution: execution} do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/webhook", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      webhook_url = "http://localhost:#{bypass.port}/webhook"
      assert :error = Notifications.send_failure_webhook(execution, webhook_url)
    end
  end

  describe "notify_failure/1" do
    setup do
      if !Process.whereis(Prikke.TaskSupervisor) do
        start_supervised!({Task.Supervisor, name: Prikke.TaskSupervisor})
      end

      user = user_fixture()
      flush_emails()

      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})

      {:ok, org} =
        Accounts.update_notification_settings(org, %{
          notify_on_failure: true,
          notification_email: "alerts@example.com"
        })

      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Notified Task",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      {:ok, execution} =
        Executions.create_execution(%{
          task_id: task.id,
          organization_id: task.organization_id,
          scheduled_for: DateTime.utc_now()
        })

      {:ok, execution} =
        Executions.fail_execution(execution, %{
          status_code: 503,
          error_message: "Service Unavailable"
        })

      execution = Executions.get_execution_with_task(execution.id)

      %{org: org, task: task, execution: execution}
    end

    test "sends notification asynchronously", %{execution: execution} do
      {:ok, _pid} = Notifications.notify_failure(execution)
      Process.sleep(100)

      emails = collect_emails()

      failure_email =
        Enum.find(emails, fn email ->
          String.contains?(email.subject, "Task failed")
        end)

      assert failure_email != nil, "Expected failure email to be sent"
      assert failure_email.to == [{"", "alerts@example.com"}]
      assert failure_email.subject =~ "Notified Task"
    end

    test "does not send notification for one-time task with retries remaining", %{org: org} do
      {:ok, once_task} =
        Tasks.create_task(org, %{
          name: "Retryable Task",
          url: "https://example.com/webhook",
          schedule_type: "once",
          scheduled_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          retry_attempts: 5
        })

      {:ok, execution} =
        Executions.create_execution(%{
          task_id: once_task.id,
          organization_id: once_task.organization_id,
          scheduled_for: DateTime.utc_now(),
          attempt: 1
        })

      {:ok, execution} =
        Executions.fail_execution(execution, %{
          status_code: 500,
          error_message: "Server Error"
        })

      execution = Executions.get_execution_with_task(execution.id)
      flush_emails()

      {:ok, _pid} = Notifications.notify_failure(execution)
      Process.sleep(100)

      emails = collect_emails()

      failure_emails =
        Enum.filter(emails, fn email ->
          String.contains?(email.subject, "Task failed")
        end)

      assert failure_emails == [],
             "Expected no failure emails when retries remain (attempt 1/5)"
    end

    test "sends notification for one-time task on final attempt", %{org: org} do
      {:ok, once_task} =
        Tasks.create_task(org, %{
          name: "Final Retry Task",
          url: "https://example.com/webhook",
          schedule_type: "once",
          scheduled_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          retry_attempts: 3
        })

      {:ok, execution} =
        Executions.create_execution(%{
          task_id: once_task.id,
          organization_id: once_task.organization_id,
          scheduled_for: DateTime.utc_now(),
          attempt: 3
        })

      {:ok, execution} =
        Executions.fail_execution(execution, %{
          status_code: 500,
          error_message: "Server Error"
        })

      execution = Executions.get_execution_with_task(execution.id)
      flush_emails()

      {:ok, _pid} = Notifications.notify_failure(execution)
      Process.sleep(100)

      emails = collect_emails()

      failure_email =
        Enum.find(emails, fn email ->
          String.contains?(email.subject, "Task failed")
        end)

      assert failure_email != nil,
             "Expected failure email on final attempt (attempt 3/3)"
    end

    test "does not send notification when disabled", %{org: org, task: task} do
      {:ok, _org} =
        Accounts.update_notification_settings(org, %{
          notify_on_failure: false
        })

      {:ok, execution} =
        Executions.create_execution(%{
          task_id: task.id,
          organization_id: task.organization_id,
          scheduled_for: DateTime.utc_now()
        })

      {:ok, execution} =
        Executions.fail_execution(execution, %{
          status_code: 500,
          error_message: "Error"
        })

      execution = Executions.get_execution_with_task(execution.id)

      {:ok, _pid} = Notifications.notify_failure(execution)
      Process.sleep(100)

      emails = collect_emails()

      failure_emails =
        Enum.filter(emails, fn email ->
          String.contains?(email.subject, "Task failed")
        end)

      assert failure_emails == [],
             "Expected no failure emails, but got: #{length(failure_emails)}"
    end
  end

  describe "send_recovery_email/2" do
    setup do
      user = user_fixture()
      flush_emails()

      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})

      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Recovery Task",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      # Create a failed execution first
      {:ok, failed_execution} =
        Executions.create_execution(%{
          task_id: task.id,
          organization_id: task.organization_id,
          scheduled_for: DateTime.add(DateTime.utc_now(), -120, :second)
        })

      {:ok, _failed_execution} =
        Executions.fail_execution(failed_execution, %{
          status_code: 500,
          error_message: "Internal Server Error"
        })

      # Create a successful execution after the failure
      {:ok, success_execution} =
        Executions.create_execution(%{
          task_id: task.id,
          organization_id: task.organization_id,
          scheduled_for: DateTime.utc_now()
        })

      {:ok, success_execution} =
        Executions.complete_execution(success_execution, %{
          status_code: 200,
          response_body: "OK",
          duration_ms: 150
        })

      execution = Executions.get_execution_with_task(success_execution.id)

      %{org: org, task: task, execution: execution}
    end

    test "sends email with recovery details", %{execution: execution} do
      to_email = "alerts@example.com"
      assert :ok = Notifications.send_recovery_email(execution, to_email)

      emails = collect_emails()

      recovery_email =
        Enum.find(emails, fn email ->
          String.contains?(email.subject, "Task recovered")
        end)

      assert recovery_email != nil, "Expected recovery email to be sent"
      assert recovery_email.to == [{"", to_email}]
      assert recovery_email.subject =~ "Recovery Task"
      assert recovery_email.text_body =~ "succeeding again"
    end
  end

  describe "send_recovery_webhook/2" do
    setup do
      user = user_fixture()
      flush_emails()

      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})

      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Recovery Task",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      {:ok, success_execution} =
        Executions.create_execution(%{
          task_id: task.id,
          organization_id: task.organization_id,
          scheduled_for: DateTime.utc_now()
        })

      {:ok, success_execution} =
        Executions.complete_execution(success_execution, %{
          status_code: 200,
          response_body: "OK",
          duration_ms: 150
        })

      execution = Executions.get_execution_with_task(success_execution.id)

      %{org: org, task: task, execution: execution}
    end

    test "sends webhook with generic JSON payload", %{execution: execution} do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/webhook", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        assert payload["event"] == "task.recovered"
        assert payload["task"]["name"] == "Recovery Task"
        assert payload["execution"]["status"] == "success"
        assert payload["execution"]["status_code"] == 200

        Plug.Conn.resp(conn, 200, "OK")
      end)

      webhook_url = "http://localhost:#{bypass.port}/webhook"
      assert :ok = Notifications.send_recovery_webhook(execution, webhook_url)
    end
  end

  describe "notify_recovery/1" do
    setup do
      if !Process.whereis(Prikke.TaskSupervisor) do
        start_supervised!({Task.Supervisor, name: Prikke.TaskSupervisor})
      end

      user = user_fixture()
      flush_emails()

      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})

      {:ok, org} =
        Accounts.update_notification_settings(org, %{
          notify_on_failure: true,
          notify_on_recovery: true,
          notification_email: "alerts@example.com"
        })

      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Recovery Notified Task",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      %{org: org, task: task}
    end

    test "sends recovery notification when previous execution failed", %{task: task} do
      # Create a failed execution
      {:ok, failed_exec} =
        Executions.create_execution(%{
          task_id: task.id,
          organization_id: task.organization_id,
          scheduled_for: DateTime.add(DateTime.utc_now(), -120, :second)
        })

      {:ok, _failed_exec} =
        Executions.fail_execution(failed_exec, %{
          status_code: 500,
          error_message: "Server Error"
        })

      # Create a successful execution
      {:ok, success_exec} =
        Executions.create_execution(%{
          task_id: task.id,
          organization_id: task.organization_id,
          scheduled_for: DateTime.utc_now()
        })

      {:ok, success_exec} =
        Executions.complete_execution(success_exec, %{
          status_code: 200,
          response_body: "OK",
          duration_ms: 100
        })

      execution = Executions.get_execution_with_task(success_exec.id)
      flush_emails()

      {:ok, _pid} = Notifications.notify_recovery(execution)
      Process.sleep(100)

      emails = collect_emails()

      recovery_email =
        Enum.find(emails, fn email ->
          String.contains?(email.subject, "Task recovered")
        end)

      assert recovery_email != nil, "Expected recovery email to be sent"
      assert recovery_email.to == [{"", "alerts@example.com"}]
      assert recovery_email.subject =~ "Recovery Notified Task"
    end

    test "does not send recovery notification when previous execution succeeded", %{task: task} do
      # Create a successful execution (no prior failure)
      {:ok, success_exec} =
        Executions.create_execution(%{
          task_id: task.id,
          organization_id: task.organization_id,
          scheduled_for: DateTime.utc_now()
        })

      {:ok, success_exec} =
        Executions.complete_execution(success_exec, %{
          status_code: 200,
          response_body: "OK",
          duration_ms: 100
        })

      execution = Executions.get_execution_with_task(success_exec.id)
      flush_emails()

      {:ok, _pid} = Notifications.notify_recovery(execution)
      Process.sleep(100)

      emails = collect_emails()

      recovery_emails =
        Enum.filter(emails, fn email ->
          String.contains?(email.subject, "Task recovered")
        end)

      assert recovery_emails == [],
             "Expected no recovery emails when previous execution was successful"
    end

    test "does not send recovery notification when disabled", %{org: org, task: task} do
      {:ok, _org} =
        Accounts.update_notification_settings(org, %{
          notify_on_recovery: false
        })

      # Create a failed then successful execution
      {:ok, failed_exec} =
        Executions.create_execution(%{
          task_id: task.id,
          organization_id: task.organization_id,
          scheduled_for: DateTime.add(DateTime.utc_now(), -120, :second)
        })

      {:ok, _} =
        Executions.fail_execution(failed_exec, %{
          status_code: 500,
          error_message: "Error"
        })

      {:ok, success_exec} =
        Executions.create_execution(%{
          task_id: task.id,
          organization_id: task.organization_id,
          scheduled_for: DateTime.utc_now()
        })

      {:ok, success_exec} =
        Executions.complete_execution(success_exec, %{
          status_code: 200,
          response_body: "OK",
          duration_ms: 100
        })

      execution = Executions.get_execution_with_task(success_exec.id)
      flush_emails()

      {:ok, _pid} = Notifications.notify_recovery(execution)
      Process.sleep(100)

      emails = collect_emails()

      recovery_emails =
        Enum.filter(emails, fn email ->
          String.contains?(email.subject, "Task recovered")
        end)

      assert recovery_emails == [],
             "Expected no recovery emails when notifications are disabled"
    end
  end

  describe "failure email throttling" do
    setup do
      if !Process.whereis(Prikke.TaskSupervisor) do
        start_supervised!({Task.Supervisor, name: Prikke.TaskSupervisor})
      end

      user = user_fixture()
      flush_emails()

      {:ok, org} = Accounts.create_organization(user, %{name: "Throttle Test Org"})

      {:ok, org} =
        Accounts.update_notification_settings(org, %{
          notify_on_failure: true,
          notification_email: "alerts@example.com"
        })

      %{org: org, user: user}
    end

    defp create_failing_task(org, name) do
      {:ok, task} =
        Tasks.create_task(org, %{
          name: name,
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      task
    end

    defp create_failed_execution(task) do
      {:ok, execution} =
        Executions.create_execution(%{
          task_id: task.id,
          organization_id: task.organization_id,
          scheduled_for: DateTime.utc_now()
        })

      {:ok, execution} =
        Executions.fail_execution(execution, %{
          status_code: 500,
          error_message: "Server Error"
        })

      Executions.get_execution_with_task(execution.id)
    end

    test "sends individual failure emails when under threshold", %{org: org} do
      task1 = create_failing_task(org, "Task 1")
      task2 = create_failing_task(org, "Task 2")

      exec1 = create_failed_execution(task1)
      exec2 = create_failed_execution(task2)

      flush_emails()

      {:ok, _} = Notifications.notify_failure(exec1)
      Process.sleep(100)

      {:ok, _} = Notifications.notify_failure(exec2)
      Process.sleep(100)

      emails = collect_emails()

      failure_emails =
        Enum.filter(emails, fn email ->
          String.contains?(email.subject, "Task failed")
        end)

      assert length(failure_emails) == 2
    end

    test "sends throttle notice on the 4th failure", %{org: org} do
      # Pre-seed 3 failure emails in the email_logs to simulate 3 already sent
      for i <- 1..3 do
        Prikke.Emails.log_email(%{
          to: "alerts@example.com",
          subject: "[Runlater] Task failed: Task #{i}",
          email_type: "task_failure",
          status: "sent",
          organization_id: org.id
        })
      end

      task = create_failing_task(org, "Task 4")
      exec = create_failed_execution(task)
      flush_emails()

      {:ok, _} = Notifications.notify_failure(exec)
      Process.sleep(100)

      emails = collect_emails()

      # Should get a throttle notice, not an individual failure email
      throttle_email =
        Enum.find(emails, fn email ->
          String.contains?(email.subject, "Multiple tasks failing")
        end)

      failure_email =
        Enum.find(emails, fn email ->
          String.contains?(email.subject, "Task failed")
        end)

      assert throttle_email != nil, "Expected throttle notice email"
      assert failure_email == nil, "Expected no individual failure email"
      assert throttle_email.text_body =~ "Task 4"
      assert throttle_email.text_body =~ "paused"
    end

    test "suppresses emails entirely after throttle notice is sent", %{org: org} do
      # Pre-seed 3 failure emails + 1 throttle notice = 4 emails in window
      for i <- 1..3 do
        Prikke.Emails.log_email(%{
          to: "alerts@example.com",
          subject: "[Runlater] Task failed: Task #{i}",
          email_type: "task_failure",
          status: "sent",
          organization_id: org.id
        })
      end

      Prikke.Emails.log_email(%{
        to: "alerts@example.com",
        subject: "[Runlater] Multiple tasks failing",
        email_type: "task_failure_throttled",
        status: "sent",
        organization_id: org.id
      })

      task = create_failing_task(org, "Task 5")
      exec = create_failed_execution(task)
      flush_emails()

      {:ok, _} = Notifications.notify_failure(exec)
      Process.sleep(100)

      emails = collect_emails()
      assert emails == [], "Expected no emails when over throttle threshold"
    end

    test "still sends webhook when email is throttled", %{org: org} do
      # Pre-seed enough emails to trigger suppression
      for i <- 1..4 do
        Prikke.Emails.log_email(%{
          to: "alerts@example.com",
          subject: "[Runlater] Task failed: Task #{i}",
          email_type: "task_failure",
          status: "sent",
          organization_id: org.id
        })
      end

      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/webhook", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        assert payload["event"] == "task.failed"
        Plug.Conn.resp(conn, 200, "OK")
      end)

      {:ok, org} =
        org
        |> Ecto.Changeset.change(notification_webhook_url: "http://localhost:#{bypass.port}/webhook")
        |> Prikke.Repo.update()

      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Throttled But Webhooks Work",
          url: "https://example.com/api",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      exec = create_failed_execution(task)
      flush_emails()

      {:ok, _} = Notifications.notify_failure(exec)
      Process.sleep(200)

      # No emails sent (throttled)
      emails = collect_emails()
      assert emails == []

      # But bypass assertion passes, meaning webhook was sent
    end
  end

  describe "recovery email throttling" do
    setup do
      if !Process.whereis(Prikke.TaskSupervisor) do
        start_supervised!({Task.Supervisor, name: Prikke.TaskSupervisor})
      end

      user = user_fixture()
      flush_emails()

      {:ok, org} = Accounts.create_organization(user, %{name: "Recovery Throttle Org"})

      {:ok, org} =
        Accounts.update_notification_settings(org, %{
          notify_on_failure: true,
          notify_on_recovery: true,
          notification_email: "alerts@example.com"
        })

      %{org: org}
    end

    defp create_recovered_execution(org, task_name) do
      {:ok, task} =
        Tasks.create_task(org, %{
          name: task_name,
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      # Create a failed execution first
      {:ok, failed_exec} =
        Executions.create_execution(%{
          task_id: task.id,
          organization_id: task.organization_id,
          scheduled_for: DateTime.add(DateTime.utc_now(), -120, :second)
        })

      {:ok, _} =
        Executions.fail_execution(failed_exec, %{
          status_code: 500,
          error_message: "Server Error"
        })

      # Then a successful one
      {:ok, success_exec} =
        Executions.create_execution(%{
          task_id: task.id,
          organization_id: task.organization_id,
          scheduled_for: DateTime.utc_now()
        })

      {:ok, success_exec} =
        Executions.complete_execution(success_exec, %{
          status_code: 200,
          response_body: "OK",
          duration_ms: 100
        })

      Executions.get_execution_with_task(success_exec.id)
    end

    test "sends throttle notice on 4th recovery", %{org: org} do
      # Pre-seed 3 recovery emails
      for i <- 1..3 do
        Prikke.Emails.log_email(%{
          to: "alerts@example.com",
          subject: "[Runlater] Task recovered: Task #{i}",
          email_type: "task_recovery",
          status: "sent",
          organization_id: org.id
        })
      end

      exec = create_recovered_execution(org, "Task 4 Recovery")
      flush_emails()

      {:ok, _} = Notifications.notify_recovery(exec)
      Process.sleep(100)

      emails = collect_emails()

      throttle_email =
        Enum.find(emails, fn email ->
          String.contains?(email.subject, "Multiple tasks recovered")
        end)

      recovery_email =
        Enum.find(emails, fn email ->
          String.contains?(email.subject, "Task recovered")
        end)

      assert throttle_email != nil, "Expected recovery throttle notice"
      assert recovery_email == nil, "Expected no individual recovery email"
      assert throttle_email.text_body =~ "paused"
    end

    test "suppresses recovery emails after throttle notice", %{org: org} do
      # Pre-seed 3 recovery + 1 throttle = 4 emails
      for i <- 1..3 do
        Prikke.Emails.log_email(%{
          to: "alerts@example.com",
          subject: "[Runlater] Task recovered: Task #{i}",
          email_type: "task_recovery",
          status: "sent",
          organization_id: org.id
        })
      end

      Prikke.Emails.log_email(%{
        to: "alerts@example.com",
        subject: "[Runlater] Multiple tasks recovered",
        email_type: "task_recovery_throttled",
        status: "sent",
        organization_id: org.id
      })

      exec = create_recovered_execution(org, "Task 5 Recovery")
      flush_emails()

      {:ok, _} = Notifications.notify_recovery(exec)
      Process.sleep(100)

      emails = collect_emails()
      assert emails == [], "Expected no emails when over recovery throttle threshold"
    end
  end

  describe "silenced task notifications (both overrides disabled)" do
    setup do
      if !Process.whereis(Prikke.TaskSupervisor) do
        start_supervised!({Task.Supervisor, name: Prikke.TaskSupervisor})
      end

      user = user_fixture()
      flush_emails()

      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})

      {:ok, org} =
        Accounts.update_notification_settings(org, %{
          notify_on_failure: true,
          notify_on_recovery: true,
          notification_email: "alerts@example.com"
        })

      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Silenced Task",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *",
          notify_on_failure: false,
          notify_on_recovery: false
        })

      %{org: org, task: task}
    end

    test "does not send failure notification for silenced task", %{task: task} do
      {:ok, execution} =
        Executions.create_execution(%{
          task_id: task.id,
          organization_id: task.organization_id,
          scheduled_for: DateTime.utc_now()
        })

      {:ok, execution} =
        Executions.fail_execution(execution, %{
          status_code: 500,
          error_message: "Server Error"
        })

      execution = Executions.get_execution_with_task(execution.id)
      flush_emails()

      {:ok, _pid} = Notifications.notify_failure(execution)
      Process.sleep(100)

      emails = collect_emails()

      failure_emails =
        Enum.filter(emails, fn email ->
          String.contains?(email.subject, "Task failed")
        end)

      assert failure_emails == [], "Expected no failure emails for silenced task"
    end

    test "does not send recovery notification for silenced task", %{task: task} do
      # Create a failed execution first
      {:ok, failed_exec} =
        Executions.create_execution(%{
          task_id: task.id,
          organization_id: task.organization_id,
          scheduled_for: DateTime.add(DateTime.utc_now(), -120, :second)
        })

      {:ok, _failed_exec} =
        Executions.fail_execution(failed_exec, %{
          status_code: 500,
          error_message: "Server Error"
        })

      # Create a successful execution after
      {:ok, success_exec} =
        Executions.create_execution(%{
          task_id: task.id,
          organization_id: task.organization_id,
          scheduled_for: DateTime.utc_now()
        })

      {:ok, success_exec} =
        Executions.complete_execution(success_exec, %{
          status_code: 200,
          response_body: "OK",
          duration_ms: 100
        })

      execution = Executions.get_execution_with_task(success_exec.id)
      flush_emails()

      {:ok, _pid} = Notifications.notify_recovery(execution)
      Process.sleep(100)

      emails = collect_emails()

      recovery_emails =
        Enum.filter(emails, fn email ->
          String.contains?(email.subject, "Task recovered")
        end)

      assert recovery_emails == [], "Expected no recovery emails for silenced task"
    end

    test "sends failure notification for task with default overrides", %{org: org} do
      {:ok, default_task} =
        Tasks.create_task(org, %{
          name: "Default Task",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      {:ok, execution} =
        Executions.create_execution(%{
          task_id: default_task.id,
          organization_id: default_task.organization_id,
          scheduled_for: DateTime.utc_now()
        })

      {:ok, execution} =
        Executions.fail_execution(execution, %{
          status_code: 500,
          error_message: "Server Error"
        })

      execution = Executions.get_execution_with_task(execution.id)
      flush_emails()

      {:ok, _pid} = Notifications.notify_failure(execution)
      Process.sleep(100)

      emails = collect_emails()

      failure_email =
        Enum.find(emails, fn email ->
          String.contains?(email.subject, "Task failed")
        end)

      assert failure_email != nil, "Expected failure email for task with default overrides"
    end
  end

  describe "silenced monitor notifications (both overrides disabled)" do
    setup do
      if !Process.whereis(Prikke.TaskSupervisor) do
        start_supervised!({Task.Supervisor, name: Prikke.TaskSupervisor})
      end

      user = user_fixture()
      flush_emails()

      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})

      {:ok, org} =
        Accounts.update_notification_settings(org, %{
          notify_on_failure: true,
          notify_on_recovery: true,
          notification_email: "alerts@example.com"
        })

      {:ok, monitor} =
        Prikke.Monitors.create_monitor(org, %{
          name: "Silenced Monitor",
          schedule_type: "interval",
          interval_seconds: 3600,
          grace_period_seconds: 300,
          notify_on_failure: false,
          notify_on_recovery: false
        })

      # Preload organization for notification logic
      monitor = Prikke.Repo.preload(monitor, :organization)

      %{org: org, monitor: monitor}
    end

    test "does not send down notification for silenced monitor", %{monitor: monitor} do
      flush_emails()

      {:ok, _pid} = Notifications.notify_monitor_down(monitor)
      Process.sleep(100)

      emails = collect_emails()

      down_emails =
        Enum.filter(emails, fn email ->
          String.contains?(email.subject, "Monitor down")
        end)

      assert down_emails == [], "Expected no down emails for silenced monitor"
    end

    test "does not send recovery notification for silenced monitor", %{monitor: monitor} do
      monitor = %{monitor | last_ping_at: DateTime.utc_now()}
      flush_emails()

      {:ok, _pid} = Notifications.notify_monitor_recovery(monitor)
      Process.sleep(100)

      emails = collect_emails()

      recovery_emails =
        Enum.filter(emails, fn email ->
          String.contains?(email.subject, "Monitor recovered")
        end)

      assert recovery_emails == [], "Expected no recovery emails for silenced monitor"
    end
  end

  describe "per-task notification overrides" do
    setup do
      if !Process.whereis(Prikke.TaskSupervisor) do
        start_supervised!({Task.Supervisor, name: Prikke.TaskSupervisor})
      end

      user = user_fixture()
      flush_emails()

      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})

      {:ok, org} =
        Accounts.update_notification_settings(org, %{
          notify_on_failure: true,
          notify_on_recovery: true,
          notification_email: "alerts@example.com"
        })

      %{org: org}
    end

    test "task with notify_on_failure: false suppresses failure notification even when org enables it",
         %{org: org} do
      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Silent Task",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *",
          notify_on_failure: false
        })

      {:ok, execution} =
        Executions.create_execution(%{
          task_id: task.id,
          organization_id: task.organization_id,
          scheduled_for: DateTime.utc_now()
        })

      {:ok, execution} =
        Executions.fail_execution(execution, %{
          status_code: 500,
          error_message: "Server Error"
        })

      execution = Executions.get_execution_with_task(execution.id)
      flush_emails()

      {:ok, _pid} = Notifications.notify_failure(execution)
      Process.sleep(100)

      emails = collect_emails()

      failure_emails =
        Enum.filter(emails, fn email ->
          String.contains?(email.subject, "Task failed")
        end)

      assert failure_emails == [],
             "Expected no failure email when task has notify_on_failure: false"
    end

    test "task with notify_on_failure: true sends failure notification even when org disables it",
         %{org: org} do
      # Disable org-level failure notifications
      {:ok, org} =
        Accounts.update_notification_settings(org, %{notify_on_failure: false})

      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Critical Task",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *",
          notify_on_failure: true
        })

      {:ok, execution} =
        Executions.create_execution(%{
          task_id: task.id,
          organization_id: task.organization_id,
          scheduled_for: DateTime.utc_now()
        })

      {:ok, execution} =
        Executions.fail_execution(execution, %{
          status_code: 500,
          error_message: "Server Error"
        })

      execution = Executions.get_execution_with_task(execution.id)
      flush_emails()

      {:ok, _pid} = Notifications.notify_failure(execution)
      Process.sleep(100)

      emails = collect_emails()

      failure_email =
        Enum.find(emails, fn email ->
          String.contains?(email.subject, "Task failed")
        end)

      assert failure_email != nil,
             "Expected failure email when task has notify_on_failure: true"
    end

    test "task with notify_on_recovery: false suppresses recovery notification", %{org: org} do
      {:ok, task} =
        Tasks.create_task(org, %{
          name: "No Recovery Task",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *",
          notify_on_recovery: false
        })

      # Create a failed execution first
      {:ok, failed_exec} =
        Executions.create_execution(%{
          task_id: task.id,
          organization_id: task.organization_id,
          scheduled_for: DateTime.add(DateTime.utc_now(), -120, :second)
        })

      {:ok, _failed_exec} =
        Executions.fail_execution(failed_exec, %{
          status_code: 500,
          error_message: "Server Error"
        })

      # Create a successful execution after
      {:ok, success_exec} =
        Executions.create_execution(%{
          task_id: task.id,
          organization_id: task.organization_id,
          scheduled_for: DateTime.utc_now()
        })

      {:ok, success_exec} =
        Executions.complete_execution(success_exec, %{
          status_code: 200,
          response_body: "OK",
          duration_ms: 100
        })

      execution = Executions.get_execution_with_task(success_exec.id)
      flush_emails()

      {:ok, _pid} = Notifications.notify_recovery(execution)
      Process.sleep(100)

      emails = collect_emails()

      recovery_emails =
        Enum.filter(emails, fn email ->
          String.contains?(email.subject, "Task recovered")
        end)

      assert recovery_emails == [],
             "Expected no recovery email when task has notify_on_recovery: false"
    end

    test "task with nil overrides falls back to org settings", %{org: org} do
      {:ok, task} =
        Tasks.create_task(org, %{
          name: "Default Task",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      # Verify notify_on_failure and notify_on_recovery are nil (using org default)
      assert is_nil(task.notify_on_failure)
      assert is_nil(task.notify_on_recovery)

      {:ok, execution} =
        Executions.create_execution(%{
          task_id: task.id,
          organization_id: task.organization_id,
          scheduled_for: DateTime.utc_now()
        })

      {:ok, execution} =
        Executions.fail_execution(execution, %{
          status_code: 500,
          error_message: "Server Error"
        })

      execution = Executions.get_execution_with_task(execution.id)
      flush_emails()

      {:ok, _pid} = Notifications.notify_failure(execution)
      Process.sleep(100)

      emails = collect_emails()

      failure_email =
        Enum.find(emails, fn email ->
          String.contains?(email.subject, "Task failed")
        end)

      assert failure_email != nil,
             "Expected failure email when task has nil override and org has notify_on_failure: true"
    end
  end

  describe "per-monitor notification overrides" do
    setup do
      if !Process.whereis(Prikke.TaskSupervisor) do
        start_supervised!({Task.Supervisor, name: Prikke.TaskSupervisor})
      end

      user = user_fixture()
      flush_emails()

      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})

      {:ok, org} =
        Accounts.update_notification_settings(org, %{
          notify_on_failure: true,
          notify_on_recovery: true,
          notification_email: "alerts@example.com"
        })

      %{org: org}
    end

    test "monitor with notify_on_failure: false suppresses down notification", %{org: org} do
      {:ok, monitor} =
        Prikke.Monitors.create_monitor(org, %{
          name: "Silent Monitor",
          schedule_type: "interval",
          interval_seconds: 3600,
          grace_period_seconds: 300,
          notify_on_failure: false
        })

      monitor = Prikke.Repo.preload(monitor, :organization)
      flush_emails()

      {:ok, _pid} = Notifications.notify_monitor_down(monitor)
      Process.sleep(100)

      emails = collect_emails()

      down_emails =
        Enum.filter(emails, fn email ->
          String.contains?(email.subject, "Monitor down")
        end)

      assert down_emails == [],
             "Expected no down email when monitor has notify_on_failure: false"
    end

    test "monitor with notify_on_failure: true sends down notification when org disables it",
         %{org: org} do
      {:ok, org} =
        Accounts.update_notification_settings(org, %{notify_on_failure: false})

      {:ok, monitor} =
        Prikke.Monitors.create_monitor(org, %{
          name: "Critical Monitor",
          schedule_type: "interval",
          interval_seconds: 3600,
          grace_period_seconds: 300,
          notify_on_failure: true
        })

      monitor = Prikke.Repo.preload(monitor, :organization)
      flush_emails()

      {:ok, _pid} = Notifications.notify_monitor_down(monitor)
      Process.sleep(100)

      emails = collect_emails()

      down_email =
        Enum.find(emails, fn email ->
          String.contains?(email.subject, "Monitor down")
        end)

      assert down_email != nil,
             "Expected down email when monitor has notify_on_failure: true"
    end

    test "monitor with notify_on_recovery: false suppresses recovery notification", %{org: org} do
      {:ok, monitor} =
        Prikke.Monitors.create_monitor(org, %{
          name: "No Recovery Monitor",
          schedule_type: "interval",
          interval_seconds: 3600,
          grace_period_seconds: 300,
          notify_on_recovery: false
        })

      monitor = Prikke.Repo.preload(monitor, :organization)
      monitor = %{monitor | last_ping_at: DateTime.utc_now()}
      flush_emails()

      {:ok, _pid} = Notifications.notify_monitor_recovery(monitor)
      Process.sleep(100)

      emails = collect_emails()

      recovery_emails =
        Enum.filter(emails, fn email ->
          String.contains?(email.subject, "Monitor recovered")
        end)

      assert recovery_emails == [],
             "Expected no recovery email when monitor has notify_on_recovery: false"
    end
  end

  # Helper to collect all emails from the mailbox
  defp collect_emails(acc \\ []) do
    receive do
      {:email, email} -> collect_emails([email | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Helper to flush all emails from the mailbox
  defp flush_emails do
    receive do
      {:email, _} -> flush_emails()
    after
      0 -> :ok
    end
  end
end
