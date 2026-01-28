defmodule Prikke.Accounts.UserNotifier do
  import Swoosh.Email

  alias Prikke.Mailer
  alias Prikke.Accounts.User

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"Prikke", "contact@example.com"})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
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
    deliver(user.email, "Log in instructions", """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver an organization invite email.
  """
  def deliver_organization_invite(email, org_name, invited_by_email, url) do
    invited_by_text = if invited_by_email, do: " by #{invited_by_email}", else: ""

    deliver(email, "You've been invited to #{org_name}", """

    ==============================

    Hi,

    You've been invited#{invited_by_text} to join #{org_name} on Prikke.

    Click the link below to accept the invitation:

    #{url}

    If you don't have a Prikke account yet, you'll be able to create one.

    ==============================
    """)
  end
end
