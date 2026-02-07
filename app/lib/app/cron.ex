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

  @doc """
  Builds a cron expression from builder parameters.

  ## Examples

      iex> Prikke.Cron.compute_cron("every_minute", "0", "9", ["1"], "1")
      "* * * * *"

      iex> Prikke.Cron.compute_cron("daily", "30", "14", ["1"], "1")
      "30 14 * * *"

      iex> Prikke.Cron.compute_cron("weekly", "0", "9", ["1", "3", "5"], "1")
      "0 9 * * 1,3,5"

      iex> Prikke.Cron.compute_cron("monthly", "0", "9", ["1"], "15")
      "0 9 15 * *"

  """
  def compute_cron(preset, minute \\ "0", hour \\ "9", weekdays \\ ["1"], day_of_month \\ "1") do
    case preset do
      "every_minute" -> "* * * * *"
      "every_5_minutes" -> "*/5 * * * *"
      "every_15_minutes" -> "*/15 * * * *"
      "every_30_minutes" -> "*/30 * * * *"
      "every_hour" -> "0 * * * *"
      "daily" -> "#{minute} #{hour} * * *"
      "weekly" -> "#{minute} #{hour} * * #{Enum.sort(weekdays) |> Enum.join(",")}"
      "monthly" -> "#{minute} #{hour} #{day_of_month} * *"
      _ -> "0 * * * *"
    end
  end

  @doc """
  Parses a cron expression back into builder parameters.

  Returns `{preset, minute, hour, weekdays, day_of_month}` or `:custom`
  if the expression cannot be mapped to a known preset.

  ## Examples

      iex> Prikke.Cron.parse_to_preset("* * * * *")
      {"every_minute", "0", "0", ["1"], "1"}

      iex> Prikke.Cron.parse_to_preset("*/5 * * * *")
      {"every_5_minutes", "0", "0", ["1"], "1"}

      iex> Prikke.Cron.parse_to_preset("0 * * * *")
      {"every_hour", "0", "0", ["1"], "1"}

      iex> Prikke.Cron.parse_to_preset("30 14 * * *")
      {"daily", "30", "14", ["1"], "1"}

      iex> Prikke.Cron.parse_to_preset("0 9 * * 1,3,5")
      {"weekly", "0", "9", ["1", "3", "5"], "1"}

      iex> Prikke.Cron.parse_to_preset("0 9 15 * *")
      {"monthly", "0", "9", ["1"], "15"}

  """
  def parse_to_preset(expression) when is_binary(expression) do
    case String.split(String.trim(expression), " ") do
      [minute, hour, day, month, weekday] ->
        cond do
          # Every minute
          minute == "*" and hour == "*" and day == "*" and month == "*" and weekday == "*" ->
            {"every_minute", "0", "0", ["1"], "1"}

          # Every N minutes
          minute == "*/5" and hour == "*" and day == "*" and month == "*" and weekday == "*" ->
            {"every_5_minutes", "0", "0", ["1"], "1"}

          minute == "*/15" and hour == "*" and day == "*" and month == "*" and weekday == "*" ->
            {"every_15_minutes", "0", "0", ["1"], "1"}

          minute == "*/30" and hour == "*" and day == "*" and month == "*" and weekday == "*" ->
            {"every_30_minutes", "0", "0", ["1"], "1"}

          # Every hour
          minute == "0" and hour == "*" and day == "*" and month == "*" and weekday == "*" ->
            {"every_hour", "0", "0", ["1"], "1"}

          # Weekly: specific weekdays, wildcard day-of-month
          day == "*" and month == "*" and weekday != "*" and numeric?(minute) and numeric?(hour) ->
            days = weekday |> String.split(",") |> Enum.sort()
            {"weekly", minute, hour, days, "1"}

          # Monthly: specific day-of-month, wildcard weekday
          month == "*" and weekday == "*" and day != "*" and numeric?(minute) and numeric?(hour) and
              numeric?(day) ->
            {"monthly", minute, hour, ["1"], day}

          # Daily: wildcard day and weekday
          day == "*" and month == "*" and weekday == "*" and numeric?(minute) and numeric?(hour) ->
            {"daily", minute, hour, ["1"], "1"}

          true ->
            :custom
        end

      _ ->
        :custom
    end
  end

  def parse_to_preset(_), do: :custom

  defp numeric?(s), do: Regex.match?(~r/^\d+$/, s)
end
