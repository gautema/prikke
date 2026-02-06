defmodule Prikke.RetryAfterTest do
  use ExUnit.Case, async: true

  alias Prikke.RetryAfter

  describe "parse/1" do
    test "returns nil when no retry-after header" do
      assert RetryAfter.parse([{"content-type", "application/json"}]) == nil
    end

    test "returns nil for empty headers" do
      assert RetryAfter.parse([]) == nil
    end

    test "parses seconds format" do
      headers = [{"retry-after", "120"}]
      assert RetryAfter.parse(headers) == 120_000
    end

    test "parses single second" do
      headers = [{"retry-after", "1"}]
      assert RetryAfter.parse(headers) == 1_000
    end

    test "returns nil for zero seconds" do
      headers = [{"retry-after", "0"}]
      assert RetryAfter.parse(headers) == nil
    end

    test "returns nil for negative seconds" do
      headers = [{"retry-after", "-5"}]
      assert RetryAfter.parse(headers) == nil
    end

    test "finds retry-after among other headers" do
      headers = [
        {"content-type", "application/json"},
        {"retry-after", "60"},
        {"x-request-id", "abc"}
      ]

      assert RetryAfter.parse(headers) == 60_000
    end
  end

  describe "parse_value/1" do
    test "returns nil for nil" do
      assert RetryAfter.parse_value(nil) == nil
    end

    test "parses integer seconds" do
      assert RetryAfter.parse_value("30") == 30_000
      assert RetryAfter.parse_value("300") == 300_000
    end

    test "returns nil for non-numeric non-date string" do
      assert RetryAfter.parse_value("abc") == nil
    end

    test "returns nil for non-string values" do
      assert RetryAfter.parse_value(123) == nil
    end
  end

  describe "parse_http_date/1" do
    test "parses a future HTTP-date" do
      # Build a date 5 minutes from now
      future = DateTime.add(DateTime.utc_now(), 300, :second)

      date_str =
        Calendar.strftime(future, "%a, %d %b %Y %H:%M:%S GMT")

      result = RetryAfter.parse_http_date(date_str)

      # Should be roughly 300 seconds (allow some slack for test execution time)
      assert result != nil
      assert_in_delta result, 300_000, 2_000
    end

    test "returns nil for a past HTTP-date" do
      past = DateTime.add(DateTime.utc_now(), -300, :second)

      date_str =
        Calendar.strftime(past, "%a, %d %b %Y %H:%M:%S GMT")

      assert RetryAfter.parse_http_date(date_str) == nil
    end

    test "returns nil for invalid date string" do
      assert RetryAfter.parse_http_date("not-a-date") == nil
    end

    test "returns nil for invalid month" do
      assert RetryAfter.parse_http_date("Thu, 06 Xyz 2026 13:00:00 GMT") == nil
    end

    test "parses all months correctly" do
      months = ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

      for month <- months do
        # Use a date far in the future so it's always valid
        date_str = "Fri, 15 #{month} 2100 12:00:00 GMT"
        result = RetryAfter.parse_http_date(date_str)
        assert result != nil, "Failed to parse month: #{month}"
      end
    end
  end
end
