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

  describe "muted task notifications" do
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
          name: "Muted Task",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *",
          muted: true
        })

      %{org: org, task: task}
    end

    test "does not send failure notification for muted task", %{task: task} do
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

      assert failure_emails == [], "Expected no failure emails for muted task"
    end

    test "does not send recovery notification for muted task", %{task: task} do
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

      assert recovery_emails == [], "Expected no recovery emails for muted task"
    end

    test "sends failure notification for unmuted task", %{org: org} do
      {:ok, unmuted_task} =
        Tasks.create_task(org, %{
          name: "Unmuted Task",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *",
          muted: false
        })

      {:ok, execution} =
        Executions.create_execution(%{
          task_id: unmuted_task.id,
          organization_id: unmuted_task.organization_id,
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

      assert failure_email != nil, "Expected failure email for unmuted task"
    end
  end

  describe "muted monitor notifications" do
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
          name: "Muted Monitor",
          schedule_type: "interval",
          interval_seconds: 3600,
          grace_period_seconds: 300,
          muted: true
        })

      # Preload organization for notification logic
      monitor = Prikke.Repo.preload(monitor, :organization)

      %{org: org, monitor: monitor}
    end

    test "does not send down notification for muted monitor", %{monitor: monitor} do
      flush_emails()

      {:ok, _pid} = Notifications.notify_monitor_down(monitor)
      Process.sleep(100)

      emails = collect_emails()

      down_emails =
        Enum.filter(emails, fn email ->
          String.contains?(email.subject, "Monitor down")
        end)

      assert down_emails == [], "Expected no down emails for muted monitor"
    end

    test "does not send recovery notification for muted monitor", %{monitor: monitor} do
      monitor = %{monitor | last_ping_at: DateTime.utc_now()}
      flush_emails()

      {:ok, _pid} = Notifications.notify_monitor_recovery(monitor)
      Process.sleep(100)

      emails = collect_emails()

      recovery_emails =
        Enum.filter(emails, fn email ->
          String.contains?(email.subject, "Monitor recovered")
        end)

      assert recovery_emails == [], "Expected no recovery emails for muted monitor"
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
