defmodule Prikke.Notifications do
  @moduledoc """
  Handles sending notifications for job execution failures.

  Supports:
  - Email notifications via Swoosh/Mailjet
  - Webhook notifications (generic JSON, Slack, Discord)

  Notifications are sent asynchronously to avoid blocking the worker.
  """

  require Logger
  import Swoosh.Email

  alias Prikke.Mailer

  @doc """
  Sends failure notifications for an execution.

  Checks the organization's notification settings and sends:
  - Email to notification_email (or org owner if not set)
  - POST to notification_webhook_url (auto-detects Slack/Discord)

  Runs asynchronously via Task.Supervisor.
  """
  def notify_failure(execution) do
    Task.Supervisor.start_child(Prikke.TaskSupervisor, fn ->
      send_failure_notifications(execution)
    end)
  end

  defp send_failure_notifications(execution) do
    job = execution.job
    org = job.organization

    # Check if notifications are enabled
    if org.notify_on_failure do
      # Only notify on status change (first failure in a sequence)
      previous_status = Prikke.Executions.get_previous_status(job, execution.id)

      if should_notify?(previous_status) do
        # Send email notification
        if email = notification_email(org) do
          send_failure_email(execution, email)
        end

        # Send webhook notification
        if webhook_url = org.notification_webhook_url do
          send_failure_webhook(execution, webhook_url)
        end
      else
        Logger.debug("[Notifications] Skipping notification - previous execution also failed")
      end
    else
      Logger.debug("[Notifications] Notifications disabled for org #{org.id}")
    end
  end

  # Notify if previous execution was successful or this is the first execution
  defp should_notify?(nil), do: true
  defp should_notify?("success"), do: true
  defp should_notify?(_failed_status), do: false

  # Get the email to notify - use notification_email if set, otherwise org owner
  defp notification_email(org) do
    cond do
      org.notification_email && org.notification_email != "" ->
        org.notification_email

      # Fall back to org owner's email
      true ->
        Prikke.Accounts.get_organization_owner_email(org)
    end
  end

  @doc """
  Sends a failure notification email.
  """
  def send_failure_email(execution, to_email) do
    job = execution.job

    config = Application.get_env(:app, Prikke.Mailer, [])
    from_name = Keyword.get(config, :from_name, "Cronly")
    from_email = Keyword.get(config, :from_email, "noreply@cronly.eu")

    subject = "[Cronly] Job failed: #{job.name}"

    body = """
    Your job "#{job.name}" has failed.

    Status: #{execution.status}
    #{if execution.status_code, do: "HTTP Status: #{execution.status_code}", else: ""}
    #{if execution.error_message, do: "Error: #{execution.error_message}", else: ""}

    Scheduled for: #{format_datetime(execution.scheduled_for)}
    #{if execution.finished_at, do: "Finished at: #{format_datetime(execution.finished_at)}", else: ""}

    Job URL: #{job.url}
    Method: #{job.method}

    ---
    View execution details in your Cronly dashboard.
    """

    email =
      new()
      |> to(to_email)
      |> from({from_name, from_email})
      |> subject(subject)
      |> text_body(String.trim(body))

    case Mailer.deliver(email) do
      {:ok, _} ->
        Logger.info("[Notifications] Email sent to #{to_email} for job #{job.id}")
        :ok

      {:error, reason} ->
        Logger.error("[Notifications] Failed to send email to #{to_email}: #{inspect(reason)}")
        :error
    end
  end

  @doc """
  Sends a failure notification to a webhook URL.
  Auto-detects Slack and Discord webhooks and formats accordingly.
  """
  def send_failure_webhook(execution, webhook_url) do
    job = execution.job

    {payload, content_type} = build_webhook_payload(execution, webhook_url)

    headers = [
      {"content-type", content_type},
      {"user-agent", "Cronly/1.0"}
    ]

    case Req.post(webhook_url, body: payload, headers: headers) do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.info("[Notifications] Webhook sent to #{webhook_url} for job #{job.id}")
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.error("[Notifications] Webhook failed with status #{status}: #{inspect(body)}")
        :error

      {:error, reason} ->
        Logger.error("[Notifications] Webhook request failed: #{inspect(reason)}")
        :error
    end
  end

  # Build the appropriate payload based on webhook type
  defp build_webhook_payload(execution, webhook_url) do
    cond do
      slack_webhook?(webhook_url) ->
        {build_slack_payload(execution), "application/json"}

      discord_webhook?(webhook_url) ->
        {build_discord_payload(execution), "application/json"}

      true ->
        {build_generic_payload(execution), "application/json"}
    end
  end

  defp slack_webhook?(url), do: String.contains?(url, "hooks.slack.com")
  defp discord_webhook?(url), do: String.contains?(url, "discord.com/api/webhooks")

  # Slack payload format
  defp build_slack_payload(execution) do
    job = execution.job

    text = """
    :x: *Job Failed: #{job.name}*

    • Status: `#{execution.status}`
    #{if execution.status_code, do: "• HTTP Status: `#{execution.status_code}`", else: ""}
    #{if execution.error_message, do: "• Error: #{execution.error_message}", else: ""}
    • URL: #{job.url}
    • Scheduled: #{format_datetime(execution.scheduled_for)}
    """

    Jason.encode!(%{text: String.trim(text)})
  end

  # Discord payload format
  defp build_discord_payload(execution) do
    job = execution.job

    content = """
    ❌ **Job Failed: #{job.name}**

    • Status: `#{execution.status}`
    #{if execution.status_code, do: "• HTTP Status: `#{execution.status_code}`", else: ""}
    #{if execution.error_message, do: "• Error: #{execution.error_message}", else: ""}
    • URL: #{job.url}
    • Scheduled: #{format_datetime(execution.scheduled_for)}
    """

    Jason.encode!(%{content: String.trim(content)})
  end

  # Generic JSON payload
  defp build_generic_payload(execution) do
    job = execution.job

    Jason.encode!(%{
      event: "job.failed",
      job: %{
        id: job.id,
        name: job.name,
        url: job.url,
        method: job.method
      },
      execution: %{
        id: execution.id,
        status: execution.status,
        status_code: execution.status_code,
        error_message: execution.error_message,
        scheduled_for: execution.scheduled_for,
        finished_at: execution.finished_at,
        duration_ms: execution.duration_ms
      }
    })
  end

  defp format_datetime(nil), do: "N/A"

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
  end
end
