defmodule PrikkeWeb.RateLimit do
  @moduledoc """
  Rate limiting plug using PlugAttack.

  Throttles requests by IP address to prevent abuse.
  Returns 429 Too Many Requests when limit is exceeded.

  Limits are configurable via application config:
    config :app, PrikkeWeb.RateLimit,
      limit_per_minute: 300,
      limit_per_hour: 5000
  """
  use PlugAttack

  # Defaults: 300/min, 5000/hour
  defp limit_per_minute, do: Application.get_env(:app, __MODULE__)[:limit_per_minute] || 300
  defp limit_per_hour, do: Application.get_env(:app, __MODULE__)[:limit_per_hour] || 5000

  rule "throttle per minute", conn do
    throttle(conn.remote_ip,
      period: 60_000,
      limit: limit_per_minute(),
      storage: {PlugAttack.Storage.Ets, PrikkeWeb.RateLimit.Storage}
    )
  end

  rule "throttle per hour", conn do
    throttle({:hourly, conn.remote_ip},
      period: 3_600_000,
      limit: limit_per_hour(),
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
