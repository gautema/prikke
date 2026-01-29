defmodule PrikkeWeb.Plugs.ApiAuth do
  @moduledoc """
  Plug for authenticating API requests using API keys.

  Expects the Authorization header in the format:
    Authorization: Bearer pk_live_xxx.sk_live_yyy

  On success, assigns `:current_organization` to the connection.
  On failure, returns 401 Unauthorized.
  """
  import Plug.Conn
  alias Prikke.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, token} <- get_token_from_header(conn),
         {:ok, organization} <- Accounts.verify_api_key(token) do
      assign(conn, :current_organization, organization)
    else
      {:error, _reason} ->
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
end
