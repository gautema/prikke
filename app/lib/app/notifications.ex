defmodule Prikke.Notifications do
  @moduledoc """
  Handles sending notifications for task execution failures.

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

  @doc """
  Sends recovery notifications for an execution that succeeded after a failure.

  Checks the organization's notification settings and sends:
  - Email to notification_email (or org owner if not set)
  - POST to notification_webhook_url (auto-detects Slack/Discord)

  Only notifies if the previous execution was a failure (status change detection).
  Runs asynchronously via Task.Supervisor.
  """
  def notify_recovery(execution) do
    Task.Supervisor.start_child(Prikke.TaskSupervisor, fn ->
      send_recovery_notifications(execution)
    end)
  end

  defp send_recovery_notifications(execution) do
    task = execution.task
    org = task.organization

    if org.notify_on_recovery and not task.muted do
      previous_status = Prikke.Executions.get_previous_status(task, execution.id)

      if should_notify_recovery?(previous_status) do
        if email = notification_email(org) do
          send_recovery_email(execution, email)
        end

        if webhook_url = org.notification_webhook_url do
          send_recovery_webhook(execution, webhook_url)
        end
      else
        Logger.debug(
          "[Notifications] Skipping recovery notification - previous execution was not failed"
        )
      end
    else
      Logger.debug("[Notifications] Recovery notifications disabled for org #{org.id}")
    end
  end

  # Notify recovery only if previous execution was a failure
  defp should_notify_recovery?(nil), do: false
  defp should_notify_recovery?("success"), do: false
  defp should_notify_recovery?("pending"), do: false
  defp should_notify_recovery?("running"), do: false
  defp should_notify_recovery?(_failed_status), do: true

  defp send_failure_notifications(execution) do
    task = execution.task
    org = task.organization

    # Check if notifications are enabled and task is not muted
    if org.notify_on_failure and not task.muted do
      # Only notify on status change (first failure in a sequence)
      previous_status = Prikke.Executions.get_previous_status(task, execution.id)

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
    task = execution.task

    config = Application.get_env(:app, Prikke.Mailer, [])
    from_name = Keyword.get(config, :from_name, "Runlater")
    from_email = Keyword.get(config, :from_email, "noreply@runlater.eu")

    subject = "[Runlater] Task failed: #{task.name}"

    text_body = """
    Your task "#{task.name}" has failed.

    Status: #{execution.status}
    #{if execution.status_code, do: "HTTP Status: #{execution.status_code}", else: ""}
    #{if execution.error_message, do: "Error: #{execution.error_message}", else: ""}

    Scheduled for: #{format_datetime(execution.scheduled_for)}
    #{if execution.finished_at, do: "Finished at: #{format_datetime(execution.finished_at)}", else: ""}

    Task URL: #{task.url}
    Method: #{task.method}

    ---
    View execution details: https://runlater.eu/tasks/#{task.id}
    """

    execution_url = "https://runlater.eu/tasks/#{task.id}/executions/#{execution.id}"
    html_body = failure_email_template(execution, task, execution_url)

    email =
      new()
      |> to(to_email)
      |> from({from_name, from_email})
      |> subject(subject)
      |> text_body(String.trim(text_body))
      |> html_body(html_body)

    case Mailer.deliver_and_log(email, "task_failure", organization_id: task.organization_id) do
      {:ok, _} ->
        Logger.info("[Notifications] Email sent to #{to_email} for task #{task.id}")
        :ok

      {:error, reason} ->
        Logger.error("[Notifications] Failed to send email to #{to_email}: #{inspect(reason)}")
        :error
    end
  end

  defp failure_email_template(execution, task, execution_url) do
    status_code_row =
      if execution.status_code do
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

    error_row =
      if execution.error_message do
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
                  <h2 style="margin: 0 0 16px 0; font-size: 18px; font-weight: 600; color: #dc2626;">Task Failed</h2>
                  <p style="margin: 0 0 16px 0; font-size: 14px; color: #475569; line-height: 1.6;">
                    Your task <strong>#{task.name}</strong> has failed.
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
                        <p style="margin: 4px 0 0 0; font-size: 14px; color: #0f172a;">#{task.method} #{task.url}</p>
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
                    Runlater - Schedule tasks, simply.
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
    task = execution.task

    {payload, content_type} = build_webhook_payload(execution, webhook_url)

    headers = [
      {"content-type", content_type},
      {"user-agent", "Runlater/1.0"}
    ]

    case Req.post(webhook_url, body: payload, headers: headers) do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.info("[Notifications] Webhook sent to #{webhook_url} for task #{task.id}")
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
    task = execution.task

    text = """
    :x: *Task Failed: #{task.name}*

    • Status: `#{execution.status}`
    #{if execution.status_code, do: "• HTTP Status: `#{execution.status_code}`", else: ""}
    #{if execution.error_message, do: "• Error: #{execution.error_message}", else: ""}
    • URL: #{task.url}
    • Scheduled: #{format_datetime(execution.scheduled_for)}
    """

    Jason.encode!(%{text: String.trim(text)})
  end

  # Discord payload format
  defp build_discord_payload(execution) do
    task = execution.task

    content = """
    ❌ **Task Failed: #{task.name}**

    • Status: `#{execution.status}`
    #{if execution.status_code, do: "• HTTP Status: `#{execution.status_code}`", else: ""}
    #{if execution.error_message, do: "• Error: #{execution.error_message}", else: ""}
    • URL: #{task.url}
    • Scheduled: #{format_datetime(execution.scheduled_for)}
    """

    Jason.encode!(%{content: String.trim(content)})
  end

  # Generic JSON payload
  defp build_generic_payload(execution) do
    task = execution.task

    Jason.encode!(%{
      event: "task.failed",
      task: %{
        id: task.id,
        name: task.name,
        url: task.url,
        method: task.method
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

  @doc """
  Sends a recovery notification email.
  """
  def send_recovery_email(execution, to_email) do
    task = execution.task

    config = Application.get_env(:app, Prikke.Mailer, [])
    from_name = Keyword.get(config, :from_name, "Runlater")
    from_email = Keyword.get(config, :from_email, "noreply@runlater.eu")

    subject = "[Runlater] Task recovered: #{task.name}"

    text_body = """
    Your task "#{task.name}" has recovered and is succeeding again.

    Status: #{execution.status}
    #{if execution.status_code, do: "HTTP Status: #{execution.status_code}", else: ""}

    Scheduled for: #{format_datetime(execution.scheduled_for)}
    #{if execution.finished_at, do: "Finished at: #{format_datetime(execution.finished_at)}", else: ""}

    Task URL: #{task.url}
    Method: #{task.method}

    ---
    View execution details: https://runlater.eu/tasks/#{task.id}
    """

    execution_url = "https://runlater.eu/tasks/#{task.id}/executions/#{execution.id}"
    html_body = recovery_email_template(execution, task, execution_url)

    email =
      new()
      |> to(to_email)
      |> from({from_name, from_email})
      |> subject(subject)
      |> text_body(String.trim(text_body))
      |> html_body(html_body)

    case Mailer.deliver_and_log(email, "task_recovery", organization_id: task.organization_id) do
      {:ok, _} ->
        Logger.info("[Notifications] Recovery email sent to #{to_email} for task #{task.id}")
        :ok

      {:error, reason} ->
        Logger.error(
          "[Notifications] Failed to send recovery email to #{to_email}: #{inspect(reason)}"
        )

        :error
    end
  end

  defp recovery_email_template(execution, task, execution_url) do
    status_code_row =
      if execution.status_code do
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
                  <h2 style="margin: 0 0 16px 0; font-size: 18px; font-weight: 600; color: #10b981;">Task Recovered</h2>
                  <p style="margin: 0 0 16px 0; font-size: 14px; color: #475569; line-height: 1.6;">
                    Your task <strong>#{task.name}</strong> is succeeding again after a failure.
                  </p>
                  <table width="100%" cellpadding="0" cellspacing="0" style="background-color: #f8fafc; border-radius: 6px;">
                    <tr>
                      <td style="padding: 8px 16px;">
                        <p style="margin: 0; font-size: 12px; color: #64748b; text-transform: uppercase;">Status</p>
                        <p style="margin: 4px 0 0 0; font-size: 14px; color: #10b981; font-weight: 500;">#{execution.status}</p>
                      </td>
                    </tr>
                    #{status_code_row}
                    <tr>
                      <td style="padding: 8px 16px;">
                        <p style="margin: 0; font-size: 12px; color: #64748b; text-transform: uppercase;">URL</p>
                        <p style="margin: 4px 0 0 0; font-size: 14px; color: #0f172a;">#{task.method} #{task.url}</p>
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
                    Runlater - Schedule tasks, simply.
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
  Sends a recovery notification to a webhook URL.
  Auto-detects Slack and Discord webhooks and formats accordingly.
  """
  def send_recovery_webhook(execution, webhook_url) do
    task = execution.task

    {payload, content_type} = build_recovery_webhook_payload(execution, webhook_url)

    headers = [
      {"content-type", content_type},
      {"user-agent", "Runlater/1.0"}
    ]

    case Req.post(webhook_url, body: payload, headers: headers) do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.info("[Notifications] Recovery webhook sent to #{webhook_url} for task #{task.id}")
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.error(
          "[Notifications] Recovery webhook failed with status #{status}: #{inspect(body)}"
        )

        :error

      {:error, reason} ->
        Logger.error("[Notifications] Recovery webhook request failed: #{inspect(reason)}")
        :error
    end
  end

  defp build_recovery_webhook_payload(execution, webhook_url) do
    cond do
      slack_webhook?(webhook_url) ->
        {build_slack_recovery_payload(execution), "application/json"}

      discord_webhook?(webhook_url) ->
        {build_discord_recovery_payload(execution), "application/json"}

      true ->
        {build_generic_recovery_payload(execution), "application/json"}
    end
  end

  defp build_slack_recovery_payload(execution) do
    task = execution.task

    text = """
    :white_check_mark: *Task Recovered: #{task.name}*

    • Status: `#{execution.status}`
    #{if execution.status_code, do: "• HTTP Status: `#{execution.status_code}`", else: ""}
    • URL: #{task.url}
    • Scheduled: #{format_datetime(execution.scheduled_for)}
    """

    Jason.encode!(%{text: String.trim(text)})
  end

  defp build_discord_recovery_payload(execution) do
    task = execution.task

    content = """
    :white_check_mark: **Task Recovered: #{task.name}**

    • Status: `#{execution.status}`
    #{if execution.status_code, do: "• HTTP Status: `#{execution.status_code}`", else: ""}
    • URL: #{task.url}
    • Scheduled: #{format_datetime(execution.scheduled_for)}
    """

    Jason.encode!(%{content: String.trim(content)})
  end

  defp build_generic_recovery_payload(execution) do
    task = execution.task

    Jason.encode!(%{
      event: "task.recovered",
      task: %{
        id: task.id,
        name: task.name,
        url: task.url,
        method: task.method
      },
      execution: %{
        id: execution.id,
        status: execution.status,
        status_code: execution.status_code,
        scheduled_for: execution.scheduled_for,
        finished_at: execution.finished_at,
        duration_ms: execution.duration_ms
      }
    })
  end

  ## Monitor Notifications

  @doc """
  Sends a notification when a monitor goes down (missed expected ping).
  Runs asynchronously via Task.Supervisor.
  """
  def notify_monitor_down(monitor) do
    Task.Supervisor.start_child(Prikke.TaskSupervisor, fn ->
      send_monitor_down_notifications(monitor)
    end)
  end

  @doc """
  Sends a notification when a monitor recovers (ping received after being down).
  Runs asynchronously via Task.Supervisor.
  """
  def notify_monitor_recovery(monitor) do
    Task.Supervisor.start_child(Prikke.TaskSupervisor, fn ->
      send_monitor_recovery_notifications(monitor)
    end)
  end

  defp send_monitor_down_notifications(monitor) do
    org = monitor.organization

    if org.notify_on_failure and not monitor.muted do
      if email = notification_email(org) do
        send_monitor_down_email(monitor, email)
      end

      if webhook_url = org.notification_webhook_url do
        send_monitor_webhook(monitor, webhook_url, :down)
      end
    end
  end

  defp send_monitor_recovery_notifications(monitor) do
    org = monitor.organization

    if org.notify_on_recovery and not monitor.muted do
      if email = notification_email(org) do
        send_monitor_recovery_email(monitor, email)
      end

      if webhook_url = org.notification_webhook_url do
        send_monitor_webhook(monitor, webhook_url, :recovered)
      end
    end
  end

  defp send_monitor_down_email(monitor, to_email) do
    config = Application.get_env(:app, Prikke.Mailer, [])
    from_name = Keyword.get(config, :from_name, "Runlater")
    from_email = Keyword.get(config, :from_email, "noreply@runlater.eu")

    subject = "[Runlater] Monitor down: #{monitor.name}"
    monitor_url = "https://runlater.eu/monitors/#{monitor.id}"

    last_ping = if monitor.last_ping_at, do: format_datetime(monitor.last_ping_at), else: "Never"

    text_body = """
    Your monitor "#{monitor.name}" has not received its expected ping.

    Status: DOWN
    Last ping: #{last_ping}
    Expected every: #{format_schedule(monitor)}

    ---
    View monitor: #{monitor_url}
    """

    html_body = monitor_email_template(monitor, monitor_url, :down)

    email =
      new()
      |> to(to_email)
      |> from({from_name, from_email})
      |> subject(subject)
      |> text_body(String.trim(text_body))
      |> html_body(html_body)

    case Mailer.deliver_and_log(email, "monitor_down", organization_id: monitor.organization_id) do
      {:ok, _} ->
        Logger.info("[Notifications] Monitor down email sent for #{monitor.id}")
        :ok

      {:error, reason} ->
        Logger.error("[Notifications] Failed to send monitor down email: #{inspect(reason)}")
        :error
    end
  end

  defp send_monitor_recovery_email(monitor, to_email) do
    config = Application.get_env(:app, Prikke.Mailer, [])
    from_name = Keyword.get(config, :from_name, "Runlater")
    from_email = Keyword.get(config, :from_email, "noreply@runlater.eu")

    subject = "[Runlater] Monitor recovered: #{monitor.name}"
    monitor_url = "https://runlater.eu/monitors/#{monitor.id}"

    text_body = """
    Your monitor "#{monitor.name}" has recovered and is receiving pings again.

    Status: UP
    Last ping: #{format_datetime(monitor.last_ping_at)}

    ---
    View monitor: #{monitor_url}
    """

    html_body = monitor_email_template(monitor, monitor_url, :recovered)

    email =
      new()
      |> to(to_email)
      |> from({from_name, from_email})
      |> subject(subject)
      |> text_body(String.trim(text_body))
      |> html_body(html_body)

    case Mailer.deliver_and_log(email, "monitor_recovery",
           organization_id: monitor.organization_id
         ) do
      {:ok, _} ->
        Logger.info("[Notifications] Monitor recovery email sent for #{monitor.id}")
        :ok

      {:error, reason} ->
        Logger.error("[Notifications] Failed to send monitor recovery email: #{inspect(reason)}")
        :error
    end
  end

  defp send_monitor_webhook(monitor, webhook_url, event_type) do
    event = if event_type == :down, do: "monitor.down", else: "monitor.recovered"
    status = if event_type == :down, do: "down", else: "up"

    payload =
      cond do
        slack_webhook?(webhook_url) ->
          emoji = if event_type == :down, do: ":red_circle:", else: ":white_check_mark:"
          label = if event_type == :down, do: "Monitor Down", else: "Monitor Recovered"

          text = """
          #{emoji} *#{label}: #{monitor.name}*

          • Status: `#{status}`
          • Last ping: #{if monitor.last_ping_at, do: format_datetime(monitor.last_ping_at), else: "Never"}
          • Schedule: #{format_schedule(monitor)}
          """

          Jason.encode!(%{text: String.trim(text)})

        discord_webhook?(webhook_url) ->
          emoji = if event_type == :down, do: ":red_circle:", else: ":white_check_mark:"
          label = if event_type == :down, do: "Monitor Down", else: "Monitor Recovered"

          content = """
          #{emoji} **#{label}: #{monitor.name}**

          • Status: `#{status}`
          • Last ping: #{if monitor.last_ping_at, do: format_datetime(monitor.last_ping_at), else: "Never"}
          • Schedule: #{format_schedule(monitor)}
          """

          Jason.encode!(%{content: String.trim(content)})

        true ->
          Jason.encode!(%{
            event: event,
            monitor: %{
              id: monitor.id,
              name: monitor.name,
              status: status,
              last_ping_at: monitor.last_ping_at,
              schedule_type: monitor.schedule_type,
              cron_expression: monitor.cron_expression,
              interval_seconds: monitor.interval_seconds
            }
          })
      end

    headers = [
      {"content-type", "application/json"},
      {"user-agent", "Runlater/1.0"}
    ]

    case Req.post(webhook_url, body: payload, headers: headers) do
      {:ok, %{status: status_code}} when status_code in 200..299 ->
        Logger.info("[Notifications] Monitor webhook sent for #{monitor.id}")
        :ok

      {:ok, %{status: status_code}} ->
        Logger.error("[Notifications] Monitor webhook failed with status #{status_code}")
        :error

      {:error, reason} ->
        Logger.error("[Notifications] Monitor webhook failed: #{inspect(reason)}")
        :error
    end
  end

  defp monitor_email_template(monitor, monitor_url, event_type) do
    {title, title_color, status_text, status_color, message} =
      if event_type == :down do
        {"Monitor Down", "#dc2626", "DOWN", "#dc2626",
         "Your monitor <strong>#{monitor.name}</strong> has not received its expected ping."}
      else
        {"Monitor Recovered", "#10b981", "UP", "#10b981",
         "Your monitor <strong>#{monitor.name}</strong> has recovered and is receiving pings again."}
      end

    last_ping = if monitor.last_ping_at, do: format_datetime(monitor.last_ping_at), else: "Never"

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
              <tr>
                <td style="padding: 32px 32px 24px 32px; text-align: center; border-bottom: 1px solid #e2e8f0;">
                  <div style="display: inline-flex; align-items: center;">
                    <span style="display: inline-block; width: 12px; height: 12px; background-color: #10b981; border-radius: 50%; margin-right: 8px;"></span>
                    <span style="font-size: 20px; font-weight: 600; color: #0f172a;">runlater</span>
                  </div>
                </td>
              </tr>
              <tr>
                <td style="padding: 32px;">
                  <h2 style="margin: 0 0 16px 0; font-size: 18px; font-weight: 600; color: #{title_color};">#{title}</h2>
                  <p style="margin: 0 0 16px 0; font-size: 14px; color: #475569; line-height: 1.6;">#{message}</p>
                  <table width="100%" cellpadding="0" cellspacing="0" style="background-color: #f8fafc; border-radius: 6px;">
                    <tr>
                      <td style="padding: 8px 16px;">
                        <p style="margin: 0; font-size: 12px; color: #64748b; text-transform: uppercase;">Status</p>
                        <p style="margin: 4px 0 0 0; font-size: 14px; color: #{status_color}; font-weight: 500;">#{status_text}</p>
                      </td>
                    </tr>
                    <tr>
                      <td style="padding: 8px 16px;">
                        <p style="margin: 0; font-size: 12px; color: #64748b; text-transform: uppercase;">Last Ping</p>
                        <p style="margin: 4px 0 0 0; font-size: 14px; color: #0f172a;">#{last_ping}</p>
                      </td>
                    </tr>
                    <tr>
                      <td style="padding: 8px 16px;">
                        <p style="margin: 0; font-size: 12px; color: #64748b; text-transform: uppercase;">Expected Schedule</p>
                        <p style="margin: 4px 0 0 0; font-size: 14px; color: #0f172a;">#{format_schedule(monitor)}</p>
                      </td>
                    </tr>
                  </table>
                  <table width="100%" cellpadding="0" cellspacing="0" style="margin-top: 24px;">
                    <tr>
                      <td align="center">
                        <a href="#{monitor_url}" style="display: inline-block; padding: 14px 32px; background-color: #10b981; color: #ffffff; text-decoration: none; border-radius: 6px; font-weight: 500; font-size: 14px;">View Monitor</a>
                      </td>
                    </tr>
                  </table>
                </td>
              </tr>
              <tr>
                <td style="padding: 24px 32px; border-top: 1px solid #e2e8f0; text-align: center;">
                  <p style="margin: 0; font-size: 12px; color: #94a3b8;">Runlater - Schedule tasks, simply.</p>
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

  defp format_schedule(monitor) do
    case monitor.schedule_type do
      "cron" -> "Cron: #{monitor.cron_expression}"
      "interval" -> "Every #{format_interval(monitor.interval_seconds)}"
      _ -> "Unknown"
    end
  end

  defp format_interval(seconds) when seconds < 120, do: "#{seconds} seconds"
  defp format_interval(seconds) when seconds < 7200, do: "#{div(seconds, 60)} minutes"
  defp format_interval(seconds) when seconds < 172_800, do: "#{div(seconds, 3600)} hours"
  defp format_interval(seconds), do: "#{div(seconds, 86400)} days"

  defp format_datetime(nil), do: "N/A"

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
  end
end
