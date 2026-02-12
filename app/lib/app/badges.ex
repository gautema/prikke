defmodule Prikke.Badges do
  @moduledoc """
  Generates SVG badges for tasks, monitors, and endpoints.

  Badge types:
  - `status` - shields.io-style flat badge showing current status
  - `uptime` - horizontal bar chart of recent execution results
  """

  @doc """
  Generates a status badge SVG for a task.

  Shows the task name and current status (passing/failing/paused/unknown).
  """
  def task_status_badge(task) do
    {label, color} = task_status(task)
    flat_badge(task.name, label, color)
  end

  @doc """
  Generates an uptime bar chart SVG for a task's recent executions.

  Each bar represents one execution. Green = success, red = failed, orange = timeout.
  """
  def task_uptime_bars(task, executions, opts \\ []) do
    name = Keyword.get(opts, :name, "uptime")
    {_label, color} = task_status(task)
    statuses = Enum.map(executions, & &1.status)
    uptime_bars(name, statuses, color)
  end

  @doc """
  Generates a status badge SVG for a monitor.

  Shows the monitor name and current status (up/down/degraded/new).
  """
  def monitor_status_badge(monitor) do
    {label, color} = monitor_status(monitor)
    flat_badge(monitor.name, label, color)
  end

  @doc """
  Generates an uptime bar chart SVG for daily monitor status.

  Each bar represents one day. Green = up, orange = degraded, red = down, gray = no data.
  """
  def monitor_uptime_bars(monitor, daily_status, opts \\ []) do
    name = Keyword.get(opts, :name, "uptime")
    {_label, color} = monitor_status(monitor)
    statuses = Enum.map(daily_status, fn {_date, %{status: s}} -> s end)
    uptime_bars(name, statuses, color)
  end

  @doc """
  Generates a status badge SVG for an endpoint.

  Shows the endpoint name and enabled/disabled status.
  """
  def endpoint_status_badge(endpoint, last_status \\ nil) do
    {label, color} = endpoint_status(endpoint, last_status)
    flat_badge(endpoint.name, label, color)
  end

  @doc """
  Generates an uptime bar chart SVG for endpoint inbound events.
  """
  def endpoint_uptime_bars(endpoint, statuses, last_status \\ nil) do
    {_label, color} = endpoint_status(endpoint, last_status)
    uptime_bars(endpoint.name, statuses, color)
  end

  # -- Status resolution --

  defp task_status(%{enabled: false}), do: {"paused", "#94a3b8"}

  defp task_status(%{last_execution_status: status}) do
    case status do
      "success" -> {"passing", "#10b981"}
      "failed" -> {"failing", "#ef4444"}
      "timeout" -> {"timeout", "#f97316"}
      "running" -> {"running", "#3b82f6"}
      "pending" -> {"pending", "#94a3b8"}
      _ -> {"unknown", "#94a3b8"}
    end
  end

  defp monitor_status(%{enabled: false}), do: {"paused", "#94a3b8"}

  defp monitor_status(%{status: status}) do
    case status do
      "up" -> {"up", "#10b981"}
      "down" -> {"down", "#ef4444"}
      "degraded" -> {"degraded", "#f97316"}
      "new" -> {"new", "#94a3b8"}
      _ -> {"unknown", "#94a3b8"}
    end
  end

  defp endpoint_status(%{enabled: false}, _last_status), do: {"disabled", "#94a3b8"}

  defp endpoint_status(_endpoint, last_status) do
    case last_status do
      "success" -> {"passing", "#10b981"}
      "failed" -> {"failing", "#ef4444"}
      "timeout" -> {"timeout", "#f97316"}
      "running" -> {"running", "#3b82f6"}
      "pending" -> {"pending", "#94a3b8"}
      _ -> {"no data", "#94a3b8"}
    end
  end

  # -- SVG generators --

  @doc """
  Generates a shields.io-style flat badge.

  The badge has two sections: a dark label on the left and a colored value on the right.
  """
  def flat_badge(label, _value, color) do
    label = truncate_label(label)
    label_width = text_width(label) + 8
    dot_section = 14
    total_width = label_width + dot_section
    dot_cx = label_width + div(dot_section, 2)

    """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{total_width}" height="20" role="img" aria-label="#{escape(label)}">
      <title>#{escape(label)}</title>
      <linearGradient id="s" x2="0" y2="100%">
        <stop offset="0" stop-color="#bbb" stop-opacity=".1"/>
        <stop offset="1" stop-opacity=".1"/>
      </linearGradient>
      <clipPath id="r">
        <rect width="#{total_width}" height="20" rx="3" fill="#fff"/>
      </clipPath>
      <g clip-path="url(#r)">
        <rect width="#{label_width}" height="20" fill="#555"/>
        <rect x="#{label_width}" width="#{dot_section}" height="20" fill="#555"/>
        <rect width="#{total_width}" height="20" fill="url(#s)"/>
      </g>
      <g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" text-rendering="geometricPrecision" font-size="11">
        <text x="#{div(label_width, 2)}" y="14" fill="#010101" fill-opacity=".3">#{escape(label)}</text>
        <text x="#{div(label_width, 2)}" y="13">#{escape(label)}</text>
      </g>
      #{pulse_dot(dot_cx, color)}
    </svg>
    """
  end

  @doc """
  Generates a horizontal bar chart of statuses.

  Each bar is a thin vertical rectangle. Colors are mapped from status strings.
  The chart includes a label on the left.
  """
  def uptime_bars(label, statuses, status_color \\ "#94a3b8") do
    count = length(statuses)

    if count == 0 do
      flat_badge(label, "no data", status_color)
    else
      label = truncate_label(label)
      bar_width = 3
      bar_gap = 1
      bar_height = 16
      dot_section = 16
      label_width = text_width(label) + 12
      bars_area_width = count * (bar_width + bar_gap) - bar_gap
      total_width = label_width + dot_section + bars_area_width + 8
      padding_y = 2

      bars_svg =
        statuses
        |> Enum.with_index()
        |> Enum.map(fn {status, i} ->
          x = label_width + dot_section + 4 + i * (bar_width + bar_gap)
          color = bar_color(status)

          ~s(<rect x="#{x}" y="#{padding_y}" width="#{bar_width}" height="#{bar_height}" rx="1" fill="#{color}"/>)
        end)
        |> Enum.join("\n    ")

      dot_cx = label_width + div(dot_section, 2)

      """
      <svg xmlns="http://www.w3.org/2000/svg" width="#{total_width}" height="20" role="img" aria-label="#{escape(label)} uptime">
        <title>#{escape(label)} uptime</title>
        <clipPath id="r">
          <rect width="#{total_width}" height="20" rx="3" fill="#fff"/>
        </clipPath>
        <g clip-path="url(#r)">
          <rect width="#{label_width}" height="20" fill="#555"/>
          <rect x="#{label_width}" width="#{dot_section}" height="20" fill="#555"/>
          <rect x="#{label_width + dot_section}" width="#{total_width - label_width - dot_section}" height="20" fill="#e2e8f0"/>
        </g>
        <g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" text-rendering="geometricPrecision" font-size="11">
          <text x="#{div(label_width, 2)}" y="14" fill="#010101" fill-opacity=".3">#{escape(label)}</text>
          <text x="#{div(label_width, 2)}" y="13">#{escape(label)}</text>
        </g>
        #{pulse_dot(dot_cx, status_color)}
        #{bars_svg}
      </svg>
      """
    end
  end

  # -- Helpers --

  defp pulse_dot(cx, color) do
    """
    <circle cx="#{cx}" cy="10" r="4" fill="#{color}" opacity="0.6">
        <animate attributeName="r" values="4;8;8" dur="2s" keyTimes="0;0.7;1" repeatCount="indefinite"/>
        <animate attributeName="opacity" values="0.6;0;0" dur="2s" keyTimes="0;0.7;1" repeatCount="indefinite"/>
      </circle>
      <circle cx="#{cx}" cy="10" r="4" fill="#{color}"/>
    """
  end

  defp bar_color("success"), do: "#10b981"
  defp bar_color("up"), do: "#10b981"
  defp bar_color("failed"), do: "#ef4444"
  defp bar_color("down"), do: "#ef4444"
  defp bar_color("timeout"), do: "#f97316"
  defp bar_color("degraded"), do: "#f97316"
  defp bar_color("missed"), do: "#6b7280"
  defp bar_color("running"), do: "#3b82f6"
  defp bar_color("pending"), do: "#94a3b8"
  defp bar_color("none"), do: "#cbd5e1"
  defp bar_color(_), do: "#cbd5e1"

  # Approximate text width based on character count.
  # Verdana 11px averages ~6.8px per character.
  defp text_width(text) do
    round(String.length(text) * 6.8)
  end

  defp truncate_label(text) when byte_size(text) > 60 do
    String.slice(text, 0, 57) <> "..."
  end

  defp truncate_label(text), do: text

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  @doc """
  Generates a unique badge token.
  Format: `bt_` followed by 24 hex characters.
  """
  def generate_token do
    "bt_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
  end
end
