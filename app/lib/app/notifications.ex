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
    from_name = Keyword.get(config, :from_name, "Runlater")
    from_email = Keyword.get(config, :from_email, "noreply@runlater.eu")

    subject = "[Runlater] Job failed: #{job.name}"

    text_body = """
    Your job "#{job.name}" has failed.

    Status: #{execution.status}
    #{if execution.status_code, do: "HTTP Status: #{execution.status_code}", else: ""}
    #{if execution.error_message, do: "Error: #{execution.error_message}", else: ""}

    Scheduled for: #{format_datetime(execution.scheduled_for)}
    #{if execution.finished_at, do: "Finished at: #{format_datetime(execution.finished_at)}", else: ""}

    Job URL: #{job.url}
    Method: #{job.method}

    ---
    View execution details: https://runlater.eu/jobs/#{job.id}
    """

    execution_url = "https://runlater.eu/jobs/#{job.id}/executions/#{execution.id}"
    html_body = failure_email_template(execution, job, execution_url)

    email =
      new()
      |> to(to_email)
      |> from({from_name, from_email})
      |> subject(subject)
      |> text_body(String.trim(text_body))
      |> html_body(html_body)

    case Mailer.deliver(email) do
      {:ok, _} ->
        Logger.info("[Notifications] Email sent to #{to_email} for job #{job.id}")
        :ok

      {:error, reason} ->
        Logger.error("[Notifications] Failed to send email to #{to_email}: #{inspect(reason)}")
        :error
    end
  end

  defp failure_email_template(execution, job, execution_url) do
    status_code_row = if execution.status_code do
      """
      <tr>
        <td style="padding: 8px 16px;">
          <p style="margin: 0; font-size: 12px; color: #64748b; text-transform: uppercase;">HTTP Status</p>
          <p style="margin: 4px 0 0 0; font-size: 14px; color: #0f172a; font-weight: 500;">#{execution.status_code}</p>
        </td>
      </tr>
      """
    else
      ""
    end

    error_row = if execution.error_message do
      """
      <tr>
        <td style="padding: 8px 16px;">
          <p style="margin: 0; font-size: 12px; color: #64748b; text-transform: uppercase;">Error</p>
          <p style="margin: 4px 0 0 0; font-size: 14px; color: #dc2626;">#{execution.error_message}</p>
        </td>
      </tr>
      """
    else
      ""
    end

    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
    </head>
    <body style="margin: 0; padding: 0; background-color: #f8fafc; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;">
      <table width="100%" cellpadding="0" cellspacing="0" style="background-color: #f8fafc; padding: 40px 20px;">
        <tr>
          <td align="center">
            <table width="100%" cellpadding="0" cellspacing="0" style="max-width: 480px; background-color: #ffffff; border-radius: 8px; border: 1px solid #e2e8f0;">
              <!-- Header -->
              <tr>
                <td style="padding: 32px 32px 24px 32px; text-align: center; border-bottom: 1px solid #e2e8f0;">
                  <div style="display: inline-flex; align-items: center;">
                    <span style="display: inline-block; width: 12px; height: 12px; background-color: #10b981; border-radius: 50%; margin-right: 8px;"></span>
                    <span style="font-size: 20px; font-weight: 600; color: #0f172a;">runlater</span>
                  </div>
                </td>
              </tr>
              <!-- Content -->
              <tr>
                <td style="padding: 32px;">
                  <h2 style="margin: 0 0 16px 0; font-size: 18px; font-weight: 600; color: #dc2626;">Job Failed</h2>
                  <p style="margin: 0 0 16px 0; font-size: 14px; color: #475569; line-height: 1.6;">
                    Your job <strong>#{job.name}</strong> has failed.
                  </p>
                  <table width="100%" cellpadding="0" cellspacing="0" style="background-color: #f8fafc; border-radius: 6px;">
                    <tr>
                      <td style="padding: 8px 16px;">
                        <p style="margin: 0; font-size: 12px; color: #64748b; text-transform: uppercase;">Status</p>
                        <p style="margin: 4px 0 0 0; font-size: 14px; color: #dc2626; font-weight: 500;">#{execution.status}</p>
                      </td>
                    </tr>
                    #{status_code_row}
                    #{error_row}
                    <tr>
                      <td style="padding: 8px 16px;">
                        <p style="margin: 0; font-size: 12px; color: #64748b; text-transform: uppercase;">URL</p>
                        <p style="margin: 4px 0 0 0; font-size: 14px; color: #0f172a;">#{job.method} #{job.url}</p>
                      </td>
                    </tr>
                    <tr>
                      <td style="padding: 8px 16px;">
                        <p style="margin: 0; font-size: 12px; color: #64748b; text-transform: uppercase;">Scheduled For</p>
                        <p style="margin: 4px 0 0 0; font-size: 14px; color: #0f172a;">#{format_datetime(execution.scheduled_for)}</p>
                      </td>
                    </tr>
                  </table>
                  <!-- Button -->
                  <table width="100%" cellpadding="0" cellspacing="0" style="margin-top: 24px;">
                    <tr>
                      <td align="center">
                        <a href="#{execution_url}" style="display: inline-block; padding: 14px 32px; background-color: #10b981; color: #ffffff; text-decoration: none; border-radius: 6px; font-weight: 500; font-size: 14px;">View Execution</a>
                      </td>
                    </tr>
                  </table>
                </td>
              </tr>
              <!-- Footer -->
              <tr>
                <td style="padding: 24px 32px; border-top: 1px solid #e2e8f0; text-align: center;">
                  <p style="margin: 0; font-size: 12px; color: #94a3b8;">
                    Runlater - Schedule jobs, simply.
                  </p>
                </td>
              </tr>
            </table>
          </td>
        </tr>
      </table>
    </body>
    </html>
    """
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
      {"user-agent", "Runlater/1.0"}
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
