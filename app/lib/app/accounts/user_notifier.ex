defmodule Prikke.Accounts.UserNotifier do
  import Swoosh.Email
  require Logger

  alias Prikke.Mailer
  alias Prikke.Accounts.User

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, text_body, html_body) do
    config = Application.get_env(:app, Prikke.Mailer, [])
    from_name = Keyword.get(config, :from_name, "Cronly")
    from_email = Keyword.get(config, :from_email, "noreply@whitenoise.no")

    email =
      new()
      |> to(recipient)
      |> from({from_name, from_email})
      |> subject(subject)
      |> text_body(text_body)
      |> html_body(html_body)

    Logger.info("Sending email to #{recipient} from #{from_email}, subject: #{subject}")

    case Mailer.deliver(email) do
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
                    <span style="font-size: 20px; font-weight: 600; color: #0f172a;">cronly</span>
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
                    Cronly - Cron jobs, simply.
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

    You requested to change your email address on Cronly.

    Click the link below to confirm the change:

    #{url}

    If you didn't request this, you can safely ignore this email.

    - The Cronly Team
    """

    html_content = """
    <h2 style="margin: 0 0 16px 0; font-size: 18px; font-weight: 600; color: #0f172a;">Change your email</h2>
    <p style="margin: 0 0 8px 0; font-size: 14px; color: #475569; line-height: 1.6;">
      You requested to change your email address on Cronly.
    </p>
    <p style="margin: 0; font-size: 14px; color: #475569; line-height: 1.6;">
      Click the button below to confirm the change. If you didn't request this, you can safely ignore this email.
    </p>
    """

    html = email_template(html_content, "Confirm email change", url)
    deliver(user.email, "Confirm your new email - Cronly", text, html)
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

    Click the link below to log in to Cronly:

    #{url}

    This link expires in 10 minutes.

    If you didn't request this, you can safely ignore this email.

    - The Cronly Team
    """

    html_content = """
    <h2 style="margin: 0 0 16px 0; font-size: 18px; font-weight: 600; color: #0f172a;">Log in to Cronly</h2>
    <p style="margin: 0 0 8px 0; font-size: 14px; color: #475569; line-height: 1.6;">
      Click the button below to log in to your account.
    </p>
    <p style="margin: 0; font-size: 14px; color: #475569; line-height: 1.6;">
      This link expires in 10 minutes. If you didn't request this, you can safely ignore this email.
    </p>
    """

    html = email_template(html_content, "Log in to Cronly", url)
    deliver(user.email, "Log in to Cronly", text, html)
  end

  defp deliver_confirmation_instructions(user, url) do
    text = """
    Hi,

    Welcome to Cronly! Click the link below to confirm your account:

    #{url}

    If you didn't create an account, you can safely ignore this email.

    - The Cronly Team
    """

    html_content = """
    <h2 style="margin: 0 0 16px 0; font-size: 18px; font-weight: 600; color: #0f172a;">Welcome to Cronly!</h2>
    <p style="margin: 0 0 8px 0; font-size: 14px; color: #475569; line-height: 1.6;">
      Thanks for signing up. Click the button below to confirm your account and get started.
    </p>
    <p style="margin: 0; font-size: 14px; color: #475569; line-height: 1.6;">
      If you didn't create an account, you can safely ignore this email.
    </p>
    """

    html = email_template(html_content, "Confirm your account", url)
    deliver(user.email, "Welcome to Cronly - Confirm your account", text, html)
  end

  @doc """
  Deliver an organization invite email.
  """
  def deliver_organization_invite(email, org_name, invited_by_email, url) do
    invited_by_text = if invited_by_email, do: " by #{invited_by_email}", else: ""

    text = """
    Hi,

    You've been invited#{invited_by_text} to join #{org_name} on Cronly.

    Click the link below to accept the invitation:

    #{url}

    If you don't have a Cronly account yet, you'll be able to create one.

    - The Cronly Team
    """

    invited_html = if invited_by_email, do: " by <strong>#{invited_by_email}</strong>", else: ""

    html_content = """
    <h2 style="margin: 0 0 16px 0; font-size: 18px; font-weight: 600; color: #0f172a;">You're invited!</h2>
    <p style="margin: 0 0 8px 0; font-size: 14px; color: #475569; line-height: 1.6;">
      You've been invited#{invited_html} to join <strong>#{org_name}</strong> on Cronly.
    </p>
    <p style="margin: 0; font-size: 14px; color: #475569; line-height: 1.6;">
      Click the button below to accept. If you don't have a Cronly account yet, you'll be able to create one.
    </p>
    """

    html = email_template(html_content, "Accept invitation", url)
    deliver(email, "You're invited to #{org_name} on Cronly", text, html)
  end

  @doc """
  Deliver admin notification when a new user signs up.
  """
  def deliver_admin_new_user_notification(user) do
    config = Application.get_env(:app, Prikke.Mailer, [])
    admin_email = Keyword.get(config, :admin_email)

    if admin_email do
      text = """
      New user signup on Cronly!

      Email: #{user.email}
      User ID: #{user.id}
      Signed up at: #{Calendar.strftime(user.inserted_at, "%Y-%m-%d %H:%M:%S UTC")}

      - Cronly System
      """

      html = admin_notification_template(user)
      deliver(admin_email, "New user signup: #{user.email}", text, html)
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
      Organization upgraded to Pro on Cronly!

      Organization: #{organization.name}
      Organization ID: #{organization.id}
      Upgraded at: #{Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M:%S UTC")}

      Action needed: Set up billing for this customer.

      - Cronly System
      """

      html = admin_upgrade_template(organization)
      deliver(admin_email, "Pro upgrade: #{organization.name}", text, html)
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
                    <span style="font-size: 20px; font-weight: 600; color: #0f172a;">cronly</span>
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
                    Cronly Admin Notification
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
                    <span style="font-size: 20px; font-weight: 600; color: #0f172a;">cronly</span>
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
                    Cronly Admin Notification
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
