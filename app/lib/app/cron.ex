defmodule Prikke.Cron do
  @moduledoc """
  Helper functions for working with cron expressions.
  """

  @doc """
  Converts a cron expression to a human-readable description.

  ## Examples

      iex> Prikke.Cron.describe("* * * * *")
      "every minute"

      iex> Prikke.Cron.describe("*/5 * * * *")
      "every 5 minutes"

      iex> Prikke.Cron.describe("0/5 * * * *")
      "every 5 minutes"

      iex> Prikke.Cron.describe("0 * * * *")
      "every hour"

      iex> Prikke.Cron.describe("0 9 * * 1-5")
      "Mon-Fri at 9:00"

  """
  def describe(cron) do
    case String.split(cron, " ") do
      [minute, hour, day, _month, weekday] ->
        cond do
          # Every minute
          minute == "*" and hour == "*" and day == "*" and weekday == "*" ->
            "every minute"

          # Every N minutes (*/5 or 0/5 syntax)
          String.contains?(minute, "/") and hour == "*" and day == "*" and weekday == "*" ->
            n = minute |> String.split("/") |> List.last()
            "every #{n} minutes"

          # Every hour (at minute 0)
          minute == "0" and hour == "*" and day == "*" and weekday == "*" ->
            "every hour"

          # Every hour at specific minute
          hour == "*" and day == "*" and weekday == "*" ->
            "every hour at :#{String.pad_leading(minute, 2, "0")}"

          # Every N hours (*/2 or 0/2 syntax)
          String.contains?(hour, "/") and day == "*" and weekday == "*" ->
            n = hour |> String.split("/") |> List.last()
            "every #{n} hours"

          # Daily at specific time (hour must be numeric)
          day == "*" and weekday == "*" and hour != "*" ->
            format_time(hour, minute)

          # Weekly on specific day(s), every hour
          day == "*" and weekday != "*" and hour == "*" ->
            day_name = weekday_name(weekday)
            m = String.pad_leading(minute, 2, "0")
            if minute == "0", do: "#{day_name}, hourly", else: "#{day_name}, hourly at :#{m}"

          # Weekly on specific day(s) at specific time
          day == "*" and weekday != "*" ->
            day_name = weekday_name(weekday)
            "#{day_name} at #{format_time_short(hour, minute)}"

          # Monthly on specific day
          weekday == "*" ->
            "monthly on day #{day}"

          true ->
            "custom schedule"
        end

      _ ->
        "custom schedule"
    end
  end

  defp format_time(hour, minute) do
    case Integer.parse(hour) do
      {h, ""} ->
        m = String.pad_leading(minute, 2, "0")

        cond do
          h == 0 and m == "00" -> "daily at midnight"
          h == 12 and m == "00" -> "daily at noon"
          true -> "daily at #{h}:#{m}"
        end

      _ ->
        "custom schedule"
    end
  end

  defp format_time_short(hour, minute) do
    case Integer.parse(hour) do
      {h, ""} ->
        m = String.pad_leading(minute, 2, "0")
        "#{h}:#{m}"

      _ ->
        "every hour"
    end
  end

  defp weekday_name("0"), do: "Sun"
  defp weekday_name("1"), do: "Mon"
  defp weekday_name("2"), do: "Tue"
  defp weekday_name("3"), do: "Wed"
  defp weekday_name("4"), do: "Thu"
  defp weekday_name("5"), do: "Fri"
  defp weekday_name("6"), do: "Sat"
  defp weekday_name("7"), do: "Sun"
  defp weekday_name("1-5"), do: "Mon-Fri"
  defp weekday_name("0,6"), do: "weekends"
  defp weekday_name("6,0"), do: "weekends"
  defp weekday_name("6-7"), do: "Sat-Sun"

  defp weekday_name(s) do
    cond do
      String.contains?(s, "-") ->
        case String.split(s, "-") do
          [from, to] -> "#{weekday_short(from)}-#{weekday_short(to)}"
          _ -> s
        end

      String.contains?(s, ",") ->
        s
        |> String.split(",")
        |> Enum.map(&weekday_short/1)
        |> Enum.join(",")

      true ->
        s
    end
  end

  defp weekday_short("0"), do: "Sun"
  defp weekday_short("1"), do: "Mon"
  defp weekday_short("2"), do: "Tue"
  defp weekday_short("3"), do: "Wed"
  defp weekday_short("4"), do: "Thu"
  defp weekday_short("5"), do: "Fri"
  defp weekday_short("6"), do: "Sat"
  defp weekday_short("7"), do: "Sun"
  defp weekday_short(s), do: s
end
