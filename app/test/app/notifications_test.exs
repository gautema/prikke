defmodule Prikke.NotificationsTest do
  use Prikke.DataCase, async: false

  import Prikke.AccountsFixtures

  alias Prikke.Notifications
  alias Prikke.Jobs
  alias Prikke.Executions
  alias Prikke.Accounts

  describe "send_failure_email/2" do
    setup do
      user = user_fixture()
      # Clear welcome email
      flush_emails()

      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})

      {:ok, job} =
        Jobs.create_job(org, %{
          name: "Test Job",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      {:ok, execution} =
        Executions.create_execution(%{
          job_id: job.id,
          scheduled_for: DateTime.utc_now()
        })

      {:ok, execution} =
        Executions.fail_execution(execution, %{
          status_code: 500,
          error_message: "Internal Server Error"
        })

      execution = Executions.get_execution_with_job(execution.id)

      %{org: org, job: job, execution: execution}
    end

    test "sends email with job failure details", %{execution: execution} do
      to_email = "alerts@example.com"
      assert :ok = Notifications.send_failure_email(execution, to_email)

      # Find the failure email
      emails = collect_emails()

      failure_email =
        Enum.find(emails, fn email ->
          String.contains?(email.subject, "Job failed")
        end)

      assert failure_email != nil, "Expected failure email to be sent"
      assert failure_email.to == [{"", to_email}]
      assert failure_email.subject =~ "Test Job"
      assert failure_email.text_body =~ "500"
      assert failure_email.text_body =~ "Internal Server Error"
    end
  end

  describe "send_failure_webhook/2" do
    setup do
      user = user_fixture()
      flush_emails()

      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})

      {:ok, job} =
        Jobs.create_job(org, %{
          name: "Test Job",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      {:ok, execution} =
        Executions.create_execution(%{
          job_id: job.id,
          scheduled_for: DateTime.utc_now()
        })

      {:ok, execution} =
        Executions.fail_execution(execution, %{
          status_code: 500,
          error_message: "Internal Server Error"
        })

      execution = Executions.get_execution_with_job(execution.id)

      %{org: org, job: job, execution: execution}
    end

    test "sends webhook with generic JSON payload", %{execution: execution} do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/webhook", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        assert payload["event"] == "job.failed"
        assert payload["job"]["name"] == "Test Job"
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

      {:ok, job} =
        Jobs.create_job(org, %{
          name: "Notified Job",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      {:ok, execution} =
        Executions.create_execution(%{
          job_id: job.id,
          scheduled_for: DateTime.utc_now()
        })

      {:ok, execution} =
        Executions.fail_execution(execution, %{
          status_code: 503,
          error_message: "Service Unavailable"
        })

      execution = Executions.get_execution_with_job(execution.id)

      %{org: org, job: job, execution: execution}
    end

    test "sends notification asynchronously", %{execution: execution} do
      {:ok, _pid} = Notifications.notify_failure(execution)
      Process.sleep(100)

      emails = collect_emails()

      failure_email =
        Enum.find(emails, fn email ->
          String.contains?(email.subject, "Job failed")
        end)

      assert failure_email != nil, "Expected failure email to be sent"
      assert failure_email.to == [{"", "alerts@example.com"}]
      assert failure_email.subject =~ "Notified Job"
    end

    test "does not send notification when disabled", %{org: org, job: job} do
      {:ok, _org} =
        Accounts.update_notification_settings(org, %{
          notify_on_failure: false
        })

      {:ok, execution} =
        Executions.create_execution(%{
          job_id: job.id,
          scheduled_for: DateTime.utc_now()
        })

      {:ok, execution} =
        Executions.fail_execution(execution, %{
          status_code: 500,
          error_message: "Error"
        })

      execution = Executions.get_execution_with_job(execution.id)

      {:ok, _pid} = Notifications.notify_failure(execution)
      Process.sleep(100)

      emails = collect_emails()

      failure_emails =
        Enum.filter(emails, fn email ->
          String.contains?(email.subject, "Job failed")
        end)

      assert failure_emails == [],
             "Expected no failure emails, but got: #{length(failure_emails)}"
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
