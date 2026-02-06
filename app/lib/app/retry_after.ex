defmodule Prikke.RetryAfter do
  @moduledoc """
  Parses the HTTP Retry-After header into milliseconds.

  Supports two formats per RFC 7231:
  - Delay in seconds: "120"
  - HTTP-date: "Thu, 06 Feb 2026 13:00:00 GMT"
  """

  @doc """
  Parses Retry-After from a list of response headers.

  Returns the delay in milliseconds, or nil if no valid Retry-After header is found.
  """
  def parse(headers) do
    retry_value =
      headers
      |> Enum.find_value(fn
        {"retry-after", value} -> value
        _ -> nil
      end)

    parse_value(retry_value)
  end

  @doc """
  Parses a Retry-After header value string into milliseconds.
  """
  def parse_value(nil), do: nil

  def parse_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds > 0 ->
        seconds * 1000

      _ ->
        parse_http_date(value)
    end
  end

  def parse_value(_), do: nil

  @doc """
  Parses an HTTP-date string into milliseconds from now.

  Returns nil if the date is in the past or cannot be parsed.
  """
  def parse_http_date(value) do
    case Regex.run(
           ~r/\w+,\s+(\d{2})\s+(\w+)\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+GMT/,
           value
         ) do
      [_, day, month_str, year, hour, min, sec] ->
        month = month_to_number(month_str)

        if month do
          with {:ok, date} <- Date.new(String.to_integer(year), month, String.to_integer(day)),
               {:ok, time} <-
                 Time.new(String.to_integer(hour), String.to_integer(min), String.to_integer(sec)),
               {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
            diff_ms = DateTime.diff(datetime, DateTime.utc_now(), :millisecond)
            if diff_ms > 0, do: diff_ms, else: nil
          else
            _ -> nil
          end
        end

      _ ->
        nil
    end
  end

  defp month_to_number("Jan"), do: 1
  defp month_to_number("Feb"), do: 2
  defp month_to_number("Mar"), do: 3
  defp month_to_number("Apr"), do: 4
  defp month_to_number("May"), do: 5
  defp month_to_number("Jun"), do: 6
  defp month_to_number("Jul"), do: 7
  defp month_to_number("Aug"), do: 8
  defp month_to_number("Sep"), do: 9
  defp month_to_number("Oct"), do: 10
  defp month_to_number("Nov"), do: 11
  defp month_to_number("Dec"), do: 12
  defp month_to_number(_), do: nil
end
