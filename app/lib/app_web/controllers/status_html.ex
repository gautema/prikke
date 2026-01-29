defmodule PrikkeWeb.StatusHTML do
  use PrikkeWeb, :html

  embed_templates "status_html/*"

  def status_color("up"), do: "bg-emerald-500"
  def status_color("operational"), do: "bg-emerald-500"
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

  def component_label("scheduler"), do: "Job Scheduler"
  def component_label("workers"), do: "Job Workers"
  def component_label("api"), do: "API & Dashboard"
  def component_label(component), do: String.capitalize(component)

  def format_time(nil), do: "Never"
  def format_time(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y %H:%M UTC")
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
end
