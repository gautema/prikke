defmodule PrikkeWeb.Plugs.TrackPageview do
  @moduledoc """
  Plug for tracking pageviews asynchronously.

  Uses IP hash as session identifier for privacy-preserving unique visitor counting.
  No cookies are set.
  """
  import Plug.Conn
  alias Prikke.Analytics

  def init(opts), do: opts

  def call(conn, _opts) do
    # Skip API requests and assets
    if should_track?(conn) do
      track_pageview(conn)
    end

    conn
  end

  defp should_track?(conn) do
    # Only track browser GET requests to HTML pages
    conn.method == "GET" &&
      !String.starts_with?(conn.request_path, "/api") &&
      !String.starts_with?(conn.request_path, "/assets") &&
      !String.starts_with?(conn.request_path, "/health") &&
      !String.starts_with?(conn.request_path, "/dev") &&
      !String.ends_with?(conn.request_path, ".js") &&
      !String.ends_with?(conn.request_path, ".css") &&
      !String.ends_with?(conn.request_path, ".ico")
  end

  defp track_pageview(conn) do
    user_id =
      if conn.assigns[:current_scope] && conn.assigns.current_scope.user do
        conn.assigns.current_scope.user.id
      end

    # Use IP hash as session identifier (no cookies)
    ip_hash = get_ip_hash(conn)

    attrs = %{
      path: conn.request_path,
      session_id: ip_hash,
      referrer: get_referrer(conn),
      user_agent: get_user_agent(conn),
      ip_hash: ip_hash,
      user_id: user_id
    }

    Analytics.track_pageview_async(attrs)
  end

  defp get_referrer(conn) do
    case get_req_header(conn, "referer") do
      [referrer | _] -> String.slice(referrer, 0, 2048)
      [] -> nil
    end
  end

  defp get_user_agent(conn) do
    case get_req_header(conn, "user-agent") do
      [ua | _] -> String.slice(ua, 0, 1024)
      [] -> nil
    end
  end

  defp get_ip_hash(conn) do
    # Get IP from X-Forwarded-For header (for proxies) or remote_ip
    ip =
      case get_req_header(conn, "x-forwarded-for") do
        [forwarded | _] ->
          forwarded |> String.split(",") |> List.first() |> String.trim()

        [] ->
          conn.remote_ip |> :inet.ntoa() |> to_string()
      end

    Analytics.hash_ip(ip)
  end
end
