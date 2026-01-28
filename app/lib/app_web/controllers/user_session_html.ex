defmodule PrikkeWeb.UserSessionHTML do
  use PrikkeWeb, :html

  embed_templates "user_session_html/*"

  defp local_mail_adapter? do
    Application.get_env(:app, Prikke.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
