defmodule Prikke.Mailer do
  use Swoosh.Mailer, otp_app: :app

  require Logger

  alias Prikke.Emails

  @doc """
  Delivers an email and logs the result to the email_logs table.

  Options:
    - `:email_type` (required) - e.g. "login_instructions", "job_failure"
    - `:organization_id` (optional) - the org this email relates to
  """
  def deliver_and_log(email, email_type, opts \\ []) do
    organization_id = Keyword.get(opts, :organization_id)
    to = extract_to(email)
    subject = email.subject || ""

    case deliver(email) do
      {:ok, _metadata} = result ->
        Emails.log_email(%{
          to: to,
          subject: subject,
          email_type: email_type,
          status: "sent",
          organization_id: organization_id
        })

        result

      {:error, reason} = result ->
        Emails.log_email(%{
          to: to,
          subject: subject,
          email_type: email_type,
          status: "failed",
          error: inspect(reason),
          organization_id: organization_id
        })

        result
    end
  end

  defp extract_to(%{to: [{_name, email}]}), do: email
  defp extract_to(%{to: [{email}]}), do: email
  defp extract_to(%{to: [email]}) when is_binary(email), do: email
  defp extract_to(%{to: to}) when is_binary(to), do: to
  defp extract_to(_), do: "unknown"
end
