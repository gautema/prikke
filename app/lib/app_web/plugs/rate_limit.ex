defmodule PrikkeWeb.RateLimit do
  @moduledoc """
  Rate limiting plug using PlugAttack.

  Throttles requests by IP address to prevent abuse.
  Returns 429 Too Many Requests when limit is exceeded.
  """
  use PlugAttack

  rule "throttle per minute", conn do
    # 300 requests per minute per IP
    throttle(conn.remote_ip,
      period: 60_000,
      limit: 300,
      storage: {PlugAttack.Storage.Ets, PrikkeWeb.RateLimit.Storage}
    )
  end

  rule "throttle per hour", conn do
    # 5000 requests per hour per IP
    throttle({:hourly, conn.remote_ip},
      period: 3_600_000,
      limit: 5000,
      storage: {PlugAttack.Storage.Ets, PrikkeWeb.RateLimit.Storage}
    )
  end

  def block_action(conn, _data, _opts) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(429, Jason.encode!(%{error: "Rate limit exceeded. Try again later."}))
    |> Plug.Conn.halt()
  end
end
