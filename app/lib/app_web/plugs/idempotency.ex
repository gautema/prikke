defmodule PrikkeWeb.Plugs.Idempotency do
  @moduledoc """
  Plug that provides idempotency key support for API requests.

  When a client sends an `Idempotency-Key` header, the plug:
  1. Checks if a cached response exists for this org + key
  2. If cached → returns the stored response immediately (halts)
  3. If new → lets the request through and captures the response via
     `register_before_send/2` to store it for future lookups

  Only 2xx responses are cached. Error responses are not stored so the
  client can retry after fixing the issue.

  Requires `current_organization` in conn assigns (must run after ApiAuth).
  """

  import Plug.Conn

  alias Prikke.Idempotency

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_idempotency_key(conn) do
      nil ->
        conn

      key ->
        org = conn.assigns[:current_organization]

        if is_nil(org) do
          conn
        else
          case Idempotency.get_cached_response(org.id, key) do
            {:ok, cached} ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(cached.status_code, cached.response_body)
              |> halt()

            :not_found ->
              conn
              |> assign(:idempotency_key, key)
              |> register_before_send(&maybe_store_response/1)
          end
        end
    end
  end

  defp get_idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key | _] when key != "" -> key
      _ -> nil
    end
  end

  defp maybe_store_response(conn) do
    key = conn.assigns[:idempotency_key]
    org = conn.assigns[:current_organization]

    if key && org && conn.status >= 200 && conn.status < 300 do
      # resp_body may be iodata from Phoenix.Controller.json/2
      body =
        if is_binary(conn.resp_body) do
          conn.resp_body
        else
          IO.iodata_to_binary(conn.resp_body)
        end

      Idempotency.store_response(org.id, key, conn.status, body)
    end

    conn
  end
end
