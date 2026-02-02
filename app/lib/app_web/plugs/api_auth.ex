defmodule PrikkeWeb.Plugs.ApiAuth do
  @moduledoc """
  Plug for authenticating API requests using API keys.

  Expects the Authorization header in the format:
    Authorization: Bearer pk_live_xxx.sk_live_yyy

  On success, assigns `:current_organization` to the connection.
  On failure, returns 401 Unauthorized and logs the attempt.
  """
  import Plug.Conn
  require Logger

  alias Prikke.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, token} <- get_token_from_header(conn),
         {:ok, organization, api_key_name} <- Accounts.verify_api_key(token) do
      conn
      |> assign(:current_organization, organization)
      |> assign(:api_key_name, api_key_name)
    else
      {:error, reason} ->
        log_auth_failure(conn, reason)

        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{
          error: %{code: "unauthorized", message: "Invalid or missing API key"}
        })
        |> halt()
    end
  end

  defp get_token_from_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _ -> {:error, :missing_token}
    end
  end

  defp log_auth_failure(conn, reason) do
    # Extract key_id if present (for identifying which key is being attacked)
    key_id = extract_key_id(conn)

    Logger.warning(
      "[ApiAuth] Failed authentication",
      key_id: key_id,
      reason: to_string(reason),
      ip: format_ip(conn),
      path: conn.request_path
    )
  end

  defp extract_key_id(conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         [key_id, _secret] <- String.split(token, ".", parts: 2) do
      key_id
    else
      _ -> "none"
    end
  end

  defp format_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end
end
