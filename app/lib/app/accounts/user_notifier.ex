defmodule Prikke.Accounts.UserNotifier do
  import Swoosh.Email
  require Logger

  alias Prikke.Mailer
  alias Prikke.Accounts.User

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, text_body, html_body, opts) do
    config = Application.get_env(:app, Prikke.Mailer, [])
    from_name = Keyword.get(config, :from_name, "Runlater")
    from_email = Keyword.get(config, :from_email, "noreply@runlater.eu")
    email_type = Keyword.get(opts, :email_type, "transactional")

    email =
      new()
      |> to(recipient)
      |> from({from_name, from_email})
      |> subject(subject)
      |> text_body(text_body)
      |> html_body(html_body)

    Logger.info("Sending email to #{recipient} from #{from_email}, subject: #{subject}")

    case Mailer.deliver_and_log(email, email_type) do
      {:ok, metadata} ->
        Logger.info("Email sent successfully: #{inspect(metadata)}")
        {:ok, email}

      {:error, reason} ->
        Logger.error("Failed to send email to #{recipient}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp email_template(content, button_text, button_url) do
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
                  #{content}
                  <!-- Button -->
                  <table width="100%" cellpadding="0" cellspacing="0" style="margin-top: 24px;">
                    <tr>
                      <td align="center">
                        <a href="#{button_url}" style="display: inline-block; padding: 14px 32px; background-color: #10b981; color: #ffffff; text-decoration: none; border-radius: 6px; font-weight: 500; font-size: 14px;">#{button_text}</a>
                      </td>
                    </tr>
                  </table>
                  <!-- Link fallback -->
                  <p style="margin-top: 24px; font-size: 12px; color: #94a3b8; text-align: center;">
                    Or copy this link:<br>
                    <a href="#{button_url}" style="color: #10b981; word-break: break-all;">#{button_url}</a>
                  </p>
                </td>
              </tr>
              <!-- Footer -->
              <tr>
                <td style="padding: 24px 32px; border-top: 1px solid #e2e8f0; text-align: center;">
                  <p style="margin: 0; font-size: 12px; color: #94a3b8;">
                    Runlater - Webhooks, cron, and queues. Hosted in Europe.
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
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    text = """
    Hi,

    You requested to change your email address on Runlater.

    Click the link below to confirm the change:

    #{url}

    If you didn't request this, you can safely ignore this email.

    - The Runlater Team
    """

    html_content = """
    <h2 style="margin: 0 0 16px 0; font-size: 18px; font-weight: 600; color: #0f172a;">Change your email</h2>
    <p style="margin: 0 0 8px 0; font-size: 14px; color: #475569; line-height: 1.6;">
      You requested to change your email address on Runlater.
    </p>
    <p style="margin: 0; font-size: 14px; color: #475569; line-height: 1.6;">
      Click the button below to confirm the change. If you didn't request this, you can safely ignore this email.
    </p>
    """

    html = email_template(html_content, "Confirm email change", url)

    deliver(user.email, "Confirm your new email - Runlater", text, html,
      email_type: "update_email"
    )
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    text = """
    Hi,

    Click the link below to log in to Runlater:

    #{url}

    This link expires in 10 minutes.

    If you didn't request this, you can safely ignore this email.

    - The Runlater Team
    """

    html_content = """
    <h2 style="margin: 0 0 16px 0; font-size: 18px; font-weight: 600; color: #0f172a;">Log in to Runlater</h2>
    <p style="margin: 0 0 8px 0; font-size: 14px; color: #475569; line-height: 1.6;">
      Click the button below to log in to your account.
    </p>
    <p style="margin: 0; font-size: 14px; color: #475569; line-height: 1.6;">
      This link expires in 10 minutes. If you didn't request this, you can safely ignore this email.
    </p>
    """

    html = email_template(html_content, "Log in to Runlater", url)
    deliver(user.email, "Log in to Runlater", text, html, email_type: "login_instructions")
  end

  defp deliver_confirmation_instructions(user, url) do
    text = """
    Hi,

    Welcome to Runlater! Click the link below to confirm your account:

    #{url}

    If you didn't create an account, you can safely ignore this email.

    - The Runlater Team
    """

    html_content = """
    <h2 style="margin: 0 0 16px 0; font-size: 18px; font-weight: 600; color: #0f172a;">Welcome to Runlater!</h2>
    <p style="margin: 0 0 8px 0; font-size: 14px; color: #475569; line-height: 1.6;">
      Thanks for signing up. Click the button below to confirm your account and get started.
    </p>
    <p style="margin: 0; font-size: 14px; color: #475569; line-height: 1.6;">
      If you didn't create an account, you can safely ignore this email.
    </p>
    """

    html = email_template(html_content, "Confirm your account", url)

    deliver(user.email, "Welcome to Runlater - Confirm your account", text, html,
      email_type: "confirmation"
    )
  end

  @doc """
  Deliver an organization invite email.
  """
  def deliver_organization_invite(email, org_name, invited_by_email, url) do
    invited_by_text = if invited_by_email, do: " by #{invited_by_email}", else: ""

    text = """
    Hi,

    You've been invited#{invited_by_text} to join #{org_name} on Runlater.

    Click the link below to accept the invitation:

    #{url}

    If you don't have a Runlater account yet, you'll be able to create one.

    - The Runlater Team
    """

    invited_html = if invited_by_email, do: " by <strong>#{invited_by_email}</strong>", else: ""

    html_content = """
    <h2 style="margin: 0 0 16px 0; font-size: 18px; font-weight: 600; color: #0f172a;">You're invited!</h2>
    <p style="margin: 0 0 8px 0; font-size: 14px; color: #475569; line-height: 1.6;">
      You've been invited#{invited_html} to join <strong>#{org_name}</strong> on Runlater.
    </p>
    <p style="margin: 0; font-size: 14px; color: #475569; line-height: 1.6;">
      Click the button below to accept. If you don't have a Runlater account yet, you'll be able to create one.
    </p>
    """

    html = email_template(html_content, "Accept invitation", url)

    deliver(email, "You're invited to #{org_name} on Runlater", text, html,
      email_type: "organization_invite"
    )
  end

  @doc """
  Deliver admin notification when a new user signs up.
  """
  def deliver_admin_new_user_notification(user) do
    config = Application.get_env(:app, Prikke.Mailer, [])
    admin_email = Keyword.get(config, :admin_email)

    if admin_email do
      text = """
      New user signup on Runlater!

      Email: #{user.email}
      User ID: #{user.id}
      Signed up at: #{Calendar.strftime(user.inserted_at, "%Y-%m-%d %H:%M:%S UTC")}

      - Runlater System
      """

      html = admin_notification_template(user)

      deliver(admin_email, "New user signup: #{user.email}", text, html,
        email_type: "admin_new_user"
      )
    else
      Logger.debug("No ADMIN_EMAIL configured, skipping new user notification")
      {:ok, :skipped}
    end
  end

  @doc """
  Deliver admin notification when an organization upgrades to Pro.
  """
  def deliver_admin_upgrade_notification(organization) do
    config = Application.get_env(:app, Prikke.Mailer, [])
    admin_email = Keyword.get(config, :admin_email)

    if admin_email do
      text = """
      Organization upgraded to Pro on Runlater!

      Organization: #{organization.name}
      Organization ID: #{organization.id}
      Upgraded at: #{Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M:%S UTC")}

      Action needed: Set up billing for this customer.

      - Runlater System
      """

      html = admin_upgrade_template(organization)

      deliver(admin_email, "Pro upgrade: #{organization.name}", text, html,
        email_type: "admin_upgrade"
      )
    else
      Logger.debug("No ADMIN_EMAIL configured, skipping upgrade notification")
      {:ok, :skipped}
    end
  end

  defp admin_upgrade_template(organization) do
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
                  <h2 style="margin: 0 0 16px 0; font-size: 18px; font-weight: 600; color: #10b981;">New Pro Upgrade!</h2>
                  <table width="100%" cellpadding="0" cellspacing="0" style="background-color: #f8fafc; border-radius: 6px; padding: 16px;">
                    <tr>
                      <td style="padding: 8px 16px;">
                        <p style="margin: 0; font-size: 12px; color: #64748b; text-transform: uppercase;">Organization</p>
                        <p style="margin: 4px 0 0 0; font-size: 14px; color: #0f172a; font-weight: 500;">#{organization.name}</p>
                      </td>
                    </tr>
                    <tr>
                      <td style="padding: 8px 16px;">
                        <p style="margin: 0; font-size: 12px; color: #64748b; text-transform: uppercase;">Organization ID</p>
                        <p style="margin: 4px 0 0 0; font-size: 14px; color: #0f172a; font-family: monospace;">#{organization.id}</p>
                      </td>
                    </tr>
                  </table>
                  <p style="margin: 24px 0 0 0; padding: 12px; background-color: #fef3c7; border-radius: 6px; font-size: 14px; color: #92400e;">
                    <strong>Action needed:</strong> Set up billing for this customer.
                  </p>
                </td>
              </tr>
              <!-- Footer -->
              <tr>
                <td style="padding: 24px 32px; border-top: 1px solid #e2e8f0; text-align: center;">
                  <p style="margin: 0; font-size: 12px; color: #94a3b8;">
                    Runlater Admin Notification
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
  Deliver warning when organization approaches monthly execution limit (80%).
  """
  def deliver_limit_warning(email, organization, current, limit) do
    percent = round(current / limit * 100)

    upgrade_text =
      if organization.tier == "free",
        do: " Upgrade to Pro for 1M executions/month — €29/mo or €290/year.",
        else: ""

    text = """
    Hi,

    Your organization "#{organization.name}" has used #{percent}% of your monthly execution limit on Runlater.

    Current usage: #{format_number(current)} / #{format_number(limit)} executions

    #{upgrade_text}

    View your dashboard: https://runlater.eu/dashboard

    - The Runlater Team
    """

    upgrade_html =
      if organization.tier == "free" do
        """
        <p style="margin: 16px 0 0 0; font-size: 14px; color: #475569;">
          <a href="https://runlater.eu/organizations/settings" style="color: #10b981; font-weight: 500;">Upgrade to Pro</a> for 1M executions/month — €29/mo or €290/year.
        </p>
        """
      else
        ""
      end

    html_content = """
    <h2 style="margin: 0 0 16px 0; font-size: 18px; font-weight: 600; color: #f59e0b;">Approaching Monthly Limit</h2>
    <p style="margin: 0 0 8px 0; font-size: 14px; color: #475569; line-height: 1.6;">
      Your organization <strong>#{organization.name}</strong> has used <strong>#{percent}%</strong> of your monthly execution limit.
    </p>
    <div style="margin: 16px 0; padding: 16px; background-color: #fef3c7; border-radius: 6px;">
      <p style="margin: 0; font-size: 14px; color: #92400e;">
        <strong>#{format_number(current)}</strong> / #{format_number(limit)} executions used
      </p>
    </div>
    #{upgrade_html}
    """

    html = email_template(html_content, "View Dashboard", "https://runlater.eu/dashboard")

    deliver(email, "Approaching monthly limit - #{organization.name}", text, html,
      email_type: "limit_warning"
    )
  end

  @doc """
  Deliver alert when organization reaches monthly execution limit (100%).
  """
  def deliver_limit_reached(email, organization, limit) do
    upgrade_text =
      if organization.tier == "free",
        do: " Upgrade to Pro for 1M executions/month — €29/mo or €290/year.",
        else: " Contact us for higher limits."

    text = """
    Hi,

    Your organization "#{organization.name}" has reached its monthly execution limit on Runlater.

    Limit: #{format_number(limit)} executions/month

    Tasks will be skipped until the limit resets next month.#{upgrade_text}

    View your dashboard: https://runlater.eu/dashboard

    - The Runlater Team
    """

    upgrade_html =
      if organization.tier == "free" do
        """
        <p style="margin: 16px 0 0 0; font-size: 14px; color: #475569;">
          <a href="https://runlater.eu/organizations/settings" style="color: #10b981; font-weight: 500;">Upgrade to Pro</a> for 1M executions/month — €29/mo or €290/year.
        </p>
        """
      else
        """
        <p style="margin: 16px 0 0 0; font-size: 14px; color: #475569;">
          <a href="mailto:support@runlater.eu" style="color: #10b981; font-weight: 500;">Contact us</a> for higher limits.
        </p>
        """
      end

    html_content = """
    <h2 style="margin: 0 0 16px 0; font-size: 18px; font-weight: 600; color: #dc2626;">Monthly Limit Reached</h2>
    <p style="margin: 0 0 8px 0; font-size: 14px; color: #475569; line-height: 1.6;">
      Your organization <strong>#{organization.name}</strong> has reached its monthly execution limit.
    </p>
    <div style="margin: 16px 0; padding: 16px; background-color: #fee2e2; border-radius: 6px;">
      <p style="margin: 0; font-size: 14px; color: #991b1b;">
        <strong>#{format_number(limit)}</strong> executions/month limit reached.<br>
        Tasks will be skipped until next month.
      </p>
    </div>
    #{upgrade_html}
    """

    html = email_template(html_content, "View Dashboard", "https://runlater.eu/dashboard")

    deliver(email, "Monthly limit reached - #{organization.name}", text, html,
      email_type: "limit_reached"
    )
  end

  defp format_number(n) when n >= 1000 do
    Integer.to_string(n)
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_number(n), do: Integer.to_string(n)

  @doc """
  Deliver a monthly summary email to the admin with platform stats.

  The `stats` map should contain:
  - :total_users, :new_users - user counts
  - :total_orgs, :new_orgs, :pro_orgs - organization counts
  - :total_tasks, :enabled_tasks - task counts
  - :executions - map with :total, :success, :failed, :timeout
  - :success_rate - percentage or nil
  - :top_orgs - list of {org, count, limit} tuples
  - :total_monitors, :down_monitors - monitor counts
  - :emails_sent - email count for the month
  - :month_name - e.g. "January 2026"
  """
  def deliver_monthly_summary(stats) do
    config = Application.get_env(:app, Prikke.Mailer, [])
    admin_email = Keyword.get(config, :admin_email)

    if admin_email do
      month_name = stats.month_name

      text = """
      Monthly Summary for #{month_name}

      Users: #{format_number(stats.total_users)} total, #{format_number(stats.new_users)} new
      Organizations: #{format_number(stats.total_orgs)} total, #{format_number(stats.new_orgs)} new, #{format_number(stats.pro_orgs)} pro
      Tasks: #{format_number(stats.total_tasks)} total, #{format_number(stats.enabled_tasks)} enabled
      Monitors: #{format_number(stats.total_monitors)} total, #{format_number(stats.down_monitors)} down

      Executions this month:
      - Total: #{format_number(stats.executions.total)}
      - Success: #{format_number(stats.executions.success)}
      - Failed: #{format_number(stats.executions.failed)}
      - Timeout: #{format_number(stats.executions.timeout)}
      - Success rate: #{stats.success_rate || "N/A"}%

      Emails sent: #{format_number(stats.emails_sent)}

      - Runlater System
      """

      html = admin_monthly_summary_template(stats)

      deliver(admin_email, "Monthly Summary: #{month_name}", text, html,
        email_type: "monthly_summary"
      )
    else
      Logger.debug("No ADMIN_EMAIL configured, skipping monthly summary")
      {:ok, :skipped}
    end
  end

  defp admin_monthly_summary_template(stats) do
    top_orgs_rows =
      stats.top_orgs
      |> Enum.map(fn {org, count, limit} ->
        percent = if limit > 0, do: round(count / limit * 100), else: 0

        """
        <tr>
          <td style="padding: 6px 12px; font-size: 13px; color: #0f172a; border-bottom: 1px solid #f1f5f9;">#{org.name}</td>
          <td style="padding: 6px 12px; font-size: 13px; color: #0f172a; border-bottom: 1px solid #f1f5f9; text-align: right;">#{format_number(count)}</td>
          <td style="padding: 6px 12px; font-size: 13px; color: #64748b; border-bottom: 1px solid #f1f5f9; text-align: right;">#{percent}%</td>
        </tr>
        """
      end)
      |> Enum.join()

    top_orgs_section =
      if stats.top_orgs != [] do
        """
        <h3 style="margin: 24px 0 12px 0; font-size: 14px; font-weight: 600; color: #0f172a;">Top Organizations</h3>
        <table width="100%" cellpadding="0" cellspacing="0" style="border: 1px solid #e2e8f0; border-radius: 6px; overflow: hidden;">
          <tr style="background-color: #f8fafc;">
            <th style="padding: 8px 12px; font-size: 11px; color: #64748b; text-transform: uppercase; text-align: left;">Organization</th>
            <th style="padding: 8px 12px; font-size: 11px; color: #64748b; text-transform: uppercase; text-align: right;">Executions</th>
            <th style="padding: 8px 12px; font-size: 11px; color: #64748b; text-transform: uppercase; text-align: right;">Usage</th>
          </tr>
          #{top_orgs_rows}
        </table>
        """
      else
        ""
      end

    success_rate_display = if stats.success_rate, do: "#{stats.success_rate}%", else: "N/A"

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
            <table width="100%" cellpadding="0" cellspacing="0" style="max-width: 560px; background-color: #ffffff; border-radius: 8px; border: 1px solid #e2e8f0;">
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
                  <h2 style="margin: 0 0 4px 0; font-size: 18px; font-weight: 600; color: #0f172a;">Monthly Summary</h2>
                  <p style="margin: 0 0 24px 0; font-size: 13px; color: #64748b;">#{stats.month_name}</p>

                  <!-- Stat Cards Row 1: Users & Orgs -->
                  <table width="100%" cellpadding="0" cellspacing="0" style="margin-bottom: 12px;">
                    <tr>
                      <td width="50%" style="padding-right: 6px;">
                        <div style="background-color: #f0fdf4; border-radius: 6px; padding: 16px;">
                          <p style="margin: 0; font-size: 11px; color: #64748b; text-transform: uppercase;">Users</p>
                          <p style="margin: 4px 0 0 0; font-size: 22px; font-weight: 700; color: #0f172a;">#{format_number(stats.total_users)}</p>
                          <p style="margin: 4px 0 0 0; font-size: 12px; color: #10b981;">+#{format_number(stats.new_users)} new</p>
                        </div>
                      </td>
                      <td width="50%" style="padding-left: 6px;">
                        <div style="background-color: #f0fdf4; border-radius: 6px; padding: 16px;">
                          <p style="margin: 0; font-size: 11px; color: #64748b; text-transform: uppercase;">Organizations</p>
                          <p style="margin: 4px 0 0 0; font-size: 22px; font-weight: 700; color: #0f172a;">#{format_number(stats.total_orgs)}</p>
                          <p style="margin: 4px 0 0 0; font-size: 12px; color: #10b981;">+#{format_number(stats.new_orgs)} new, #{format_number(stats.pro_orgs)} pro</p>
                        </div>
                      </td>
                    </tr>
                  </table>

                  <!-- Stat Cards Row 2: Jobs & Monitors -->
                  <table width="100%" cellpadding="0" cellspacing="0" style="margin-bottom: 12px;">
                    <tr>
                      <td width="50%" style="padding-right: 6px;">
                        <div style="background-color: #f8fafc; border-radius: 6px; padding: 16px; border: 1px solid #e2e8f0;">
                          <p style="margin: 0; font-size: 11px; color: #64748b; text-transform: uppercase;">Tasks</p>
                          <p style="margin: 4px 0 0 0; font-size: 22px; font-weight: 700; color: #0f172a;">#{format_number(stats.total_tasks)}</p>
                          <p style="margin: 4px 0 0 0; font-size: 12px; color: #64748b;">#{format_number(stats.enabled_tasks)} enabled</p>
                        </div>
                      </td>
                      <td width="50%" style="padding-left: 6px;">
                        <div style="background-color: #f8fafc; border-radius: 6px; padding: 16px; border: 1px solid #e2e8f0;">
                          <p style="margin: 0; font-size: 11px; color: #64748b; text-transform: uppercase;">Monitors</p>
                          <p style="margin: 4px 0 0 0; font-size: 22px; font-weight: 700; color: #0f172a;">#{format_number(stats.total_monitors)}</p>
                          <p style="margin: 4px 0 0 0; font-size: 12px; color: #{if stats.down_monitors > 0, do: "#dc2626", else: "#64748b"};">#{format_number(stats.down_monitors)} down</p>
                        </div>
                      </td>
                    </tr>
                  </table>

                  <!-- Executions Section -->
                  <h3 style="margin: 24px 0 12px 0; font-size: 14px; font-weight: 600; color: #0f172a;">Executions This Month</h3>
                  <table width="100%" cellpadding="0" cellspacing="0" style="background-color: #f8fafc; border-radius: 6px; padding: 4px;">
                    <tr>
                      <td style="padding: 10px 16px;">
                        <p style="margin: 0; font-size: 11px; color: #64748b; text-transform: uppercase;">Total</p>
                        <p style="margin: 2px 0 0 0; font-size: 16px; font-weight: 600; color: #0f172a;">#{format_number(stats.executions.total)}</p>
                      </td>
                      <td style="padding: 10px 16px;">
                        <p style="margin: 0; font-size: 11px; color: #64748b; text-transform: uppercase;">Success</p>
                        <p style="margin: 2px 0 0 0; font-size: 16px; font-weight: 600; color: #10b981;">#{format_number(stats.executions.success)}</p>
                      </td>
                      <td style="padding: 10px 16px;">
                        <p style="margin: 0; font-size: 11px; color: #64748b; text-transform: uppercase;">Failed</p>
                        <p style="margin: 2px 0 0 0; font-size: 16px; font-weight: 600; color: #dc2626;">#{format_number(stats.executions.failed)}</p>
                      </td>
                      <td style="padding: 10px 16px;">
                        <p style="margin: 0; font-size: 11px; color: #64748b; text-transform: uppercase;">Timeout</p>
                        <p style="margin: 2px 0 0 0; font-size: 16px; font-weight: 600; color: #f59e0b;">#{format_number(stats.executions.timeout)}</p>
                      </td>
                    </tr>
                  </table>
                  <p style="margin: 8px 0 0 0; font-size: 13px; color: #64748b;">Success rate: <strong style="color: #0f172a;">#{success_rate_display}</strong></p>

                  #{top_orgs_section}

                  <!-- Emails -->
                  <p style="margin: 24px 0 0 0; font-size: 13px; color: #64748b;">Emails sent this month: <strong style="color: #0f172a;">#{format_number(stats.emails_sent)}</strong></p>
                </td>
              </tr>
              <!-- Footer -->
              <tr>
                <td style="padding: 24px 32px; border-top: 1px solid #e2e8f0; text-align: center;">
                  <p style="margin: 0; font-size: 12px; color: #94a3b8;">
                    Runlater Admin Notification
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

  defp admin_notification_template(user) do
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
                  <h2 style="margin: 0 0 16px 0; font-size: 18px; font-weight: 600; color: #0f172a;">New User Signup!</h2>
                  <table width="100%" cellpadding="0" cellspacing="0" style="background-color: #f8fafc; border-radius: 6px; padding: 16px;">
                    <tr>
                      <td style="padding: 8px 16px;">
                        <p style="margin: 0; font-size: 12px; color: #64748b; text-transform: uppercase;">Email</p>
                        <p style="margin: 4px 0 0 0; font-size: 14px; color: #0f172a; font-weight: 500;">#{user.email}</p>
                      </td>
                    </tr>
                    <tr>
                      <td style="padding: 8px 16px;">
                        <p style="margin: 0; font-size: 12px; color: #64748b; text-transform: uppercase;">User ID</p>
                        <p style="margin: 4px 0 0 0; font-size: 14px; color: #0f172a; font-family: monospace;">#{user.id}</p>
                      </td>
                    </tr>
                    <tr>
                      <td style="padding: 8px 16px;">
                        <p style="margin: 0; font-size: 12px; color: #64748b; text-transform: uppercase;">Signed Up</p>
                        <p style="margin: 4px 0 0 0; font-size: 14px; color: #0f172a;">#{Calendar.strftime(user.inserted_at, "%Y-%m-%d %H:%M:%S UTC")}</p>
                      </td>
                    </tr>
                  </table>
                </td>
              </tr>
              <!-- Footer -->
              <tr>
                <td style="padding: 24px 32px; border-top: 1px solid #e2e8f0; text-align: center;">
                  <p style="margin: 0; font-size: 12px; color: #94a3b8;">
                    Runlater Admin Notification
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
end
