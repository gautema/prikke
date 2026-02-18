defmodule PrikkeWeb.StatusHTML do
  use PrikkeWeb, :html

  embed_templates("status_html/*")

  def status_color("up"), do: "bg-emerald-600"
  def status_color("operational"), do: "bg-emerald-600"
  def status_color("degraded"), do: "bg-amber-500"
  def status_color("down"), do: "bg-red-500"
  def status_color(_), do: "bg-slate-400"

  def status_text_color("up"), do: "text-emerald-600"
  def status_text_color("operational"), do: "text-emerald-600"
  def status_text_color("degraded"), do: "text-amber-600"
  def status_text_color("down"), do: "text-red-600"
  def status_text_color(_), do: "text-slate-500"

  def status_label("up"), do: "Operational"
  def status_label("operational"), do: "All Systems Operational"
  def status_label("degraded"), do: "Degraded Performance"
  def status_label("down"), do: "Major Outage"
  def status_label("unknown"), do: "Unknown"
  def status_label(status), do: String.capitalize(status)

  def component_label("scheduler"), do: "Task Scheduler"
  def component_label("workers"), do: "Task Workers"
  def component_label("api"), do: "API & Dashboard"
  def component_label(component), do: String.capitalize(component)

  def uptime_percentage(daily_uptime, incidents) do
    monitored = Enum.reject(daily_uptime, fn {_date, status} -> status == :unknown end)

    case length(monitored) do
      0 ->
        "N/A"

      total_days ->
        total_minutes = total_days * 24 * 60

        down_minutes =
          incidents
          |> Enum.map(fn incident ->
            ended = incident.resolved_at || DateTime.utc_now()
            DateTime.diff(ended, incident.started_at, :minute)
          end)
          |> Enum.sum()

        up_minutes = max(total_minutes - down_minutes, 0)
        percent = Float.round(up_minutes / total_minutes * 100, 2)
        "#{percent}%"
    end
  end

  def uptime_status_label(:up), do: "Operational"
  def uptime_status_label(:down), do: "Incident"
  def uptime_status_label(:unknown), do: "No data"

  def format_time(nil), do: "Never"

  def format_time(datetime) do
    Calendar.strftime(datetime, "%d %b %Y, %H:%M UTC")
  end

  def format_duration(nil, _), do: ""

  def format_duration(started_at, nil) do
    duration = DateTime.diff(DateTime.utc_now(), started_at, :minute)
    "Ongoing for #{format_duration_text(duration)}"
  end

  def format_duration(started_at, resolved_at) do
    duration = DateTime.diff(resolved_at, started_at, :minute)
    "Duration: #{format_duration_text(duration)}"
  end

  defp format_duration_text(minutes) when minutes < 60, do: "#{minutes} min"

  defp format_duration_text(minutes) when minutes < 1440 do
    hours = div(minutes, 60)
    "#{hours} hour#{if hours > 1, do: "s", else: ""}"
  end

  defp format_duration_text(minutes) do
    days = div(minutes, 1440)
    "#{days} day#{if days > 1, do: "s", else: ""}"
  end

  @doc """
  Returns a Tailwind color class based on p95 SLO compliance.
  Green: p95 < 200ms, Yellow: 200-500ms, Red: > 500ms, Gray: no data.
  """
  def latency_bar_color(0), do: "bg-slate-200"
  def latency_bar_color(p95_us) when p95_us <= 200_000, do: "bg-emerald-600"
  def latency_bar_color(p95_us) when p95_us <= 500_000, do: "bg-amber-500"
  def latency_bar_color(_p95_us), do: "bg-red-500"

  @doc """
  Formats a latency value in microseconds to a human-readable string.
  """
  def format_latency(0), do: "-"

  def format_latency(us) when us < 1_000 do
    "#{us}us"
  end

  def format_latency(us) when us < 1_000_000 do
    ms = us / 1_000
    if ms >= 10, do: "#{round(ms)}ms", else: "#{Float.round(ms, 1)}ms"
  end

  def format_latency(us) do
    s = us / 1_000_000
    "#{Float.round(s, 1)}s"
  end

  @doc """
  Builds a list of days with latency data, filling gaps with nil entries.
  """
  def fill_latency_days(daily_latency, days \\ 30) do
    today = Date.utc_today()
    latency_by_date = Map.new(daily_latency, fn entry -> {entry.date, entry} end)

    for offset <- -(days - 1)..0 do
      date = Date.add(today, offset)
      {date, Map.get(latency_by_date, date)}
    end
  end

  @doc """
  Returns a Tailwind color class based on scheduling precision SLO compliance.
  Green: p95 < 30s, Yellow: 30-60s, Red: > 60s, Gray: no data.
  """
  def precision_bar_color(0), do: "bg-slate-200"
  def precision_bar_color(p95_ms) when p95_ms <= 30_000, do: "bg-emerald-600"
  def precision_bar_color(p95_ms) when p95_ms <= 60_000, do: "bg-amber-500"
  def precision_bar_color(_p95_ms), do: "bg-red-500"

  @doc """
  Formats a delay value in milliseconds to a human-readable string.
  """
  def format_delay(nil), do: "-"
  def format_delay(0), do: "<1s"

  def format_delay(ms) when ms < 1_000 do
    "#{ms}ms"
  end

  def format_delay(ms) when ms < 60_000 do
    s = ms / 1_000
    if s >= 10, do: "#{round(s)}s", else: "#{Float.round(s, 1)}s"
  end

  def format_delay(ms) do
    m = ms / 60_000
    "#{Float.round(m, 1)}min"
  end

  @doc """
  Builds a list of days with scheduling precision data, filling gaps with nil entries.
  """
  def fill_precision_days(daily_precision, days \\ 90) do
    today = Date.utc_today()
    precision_by_date = Map.new(daily_precision, fn entry -> {entry.date, entry} end)

    for offset <- -(days - 1)..0 do
      date = Date.add(today, offset)
      {date, Map.get(precision_by_date, date)}
    end
  end
end
