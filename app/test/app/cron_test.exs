defmodule Prikke.CronTest do
  use ExUnit.Case, async: true

  alias Prikke.Cron

  describe "compute_cron/5" do
    test "every_minute preset" do
      assert Cron.compute_cron("every_minute") == "* * * * *"
    end

    test "every_5_minutes preset" do
      assert Cron.compute_cron("every_5_minutes") == "*/5 * * * *"
    end

    test "every_15_minutes preset" do
      assert Cron.compute_cron("every_15_minutes") == "*/15 * * * *"
    end

    test "every_30_minutes preset" do
      assert Cron.compute_cron("every_30_minutes") == "*/30 * * * *"
    end

    test "every_hour preset" do
      assert Cron.compute_cron("every_hour") == "0 * * * *"
    end

    test "daily preset with time" do
      assert Cron.compute_cron("daily", "30", "14", ["1"], "1") == "30 14 * * *"
    end

    test "daily preset at midnight" do
      assert Cron.compute_cron("daily", "0", "0", ["1"], "1") == "0 0 * * *"
    end

    test "weekly preset with single day" do
      assert Cron.compute_cron("weekly", "0", "9", ["1"], "1") == "0 9 * * 1"
    end

    test "weekly preset with multiple days sorted" do
      assert Cron.compute_cron("weekly", "0", "9", ["5", "1", "3"], "1") == "0 9 * * 1,3,5"
    end

    test "monthly preset" do
      assert Cron.compute_cron("monthly", "0", "9", ["1"], "15") == "0 9 15 * *"
    end

    test "unknown preset defaults to every hour" do
      assert Cron.compute_cron("unknown") == "0 * * * *"
    end
  end

  describe "parse_to_preset/1" do
    test "parses every minute" do
      assert Cron.parse_to_preset("* * * * *") == {"every_minute", "0", "0", ["1"], "1"}
    end

    test "parses every 5 minutes" do
      assert Cron.parse_to_preset("*/5 * * * *") == {"every_5_minutes", "0", "0", ["1"], "1"}
    end

    test "parses every 15 minutes" do
      assert Cron.parse_to_preset("*/15 * * * *") == {"every_15_minutes", "0", "0", ["1"], "1"}
    end

    test "parses every 30 minutes" do
      assert Cron.parse_to_preset("*/30 * * * *") == {"every_30_minutes", "0", "0", ["1"], "1"}
    end

    test "parses every hour" do
      assert Cron.parse_to_preset("0 * * * *") == {"every_hour", "0", "0", ["1"], "1"}
    end

    test "parses daily schedule" do
      assert Cron.parse_to_preset("30 14 * * *") == {"daily", "30", "14", ["1"], "1"}
    end

    test "parses weekly schedule with single day" do
      assert Cron.parse_to_preset("0 9 * * 1") == {"weekly", "0", "9", ["1"], "1"}
    end

    test "parses weekly schedule with multiple days" do
      {preset, minute, hour, weekdays, _dom} = Cron.parse_to_preset("0 9 * * 1,3,5")
      assert preset == "weekly"
      assert minute == "0"
      assert hour == "9"
      assert Enum.sort(weekdays) == ["1", "3", "5"]
    end

    test "parses monthly schedule" do
      assert Cron.parse_to_preset("0 9 15 * *") == {"monthly", "0", "9", ["1"], "15"}
    end

    test "returns :custom for complex expressions" do
      assert Cron.parse_to_preset("0 9 1-15 * 1-5") == :custom
    end

    test "returns :custom for invalid input" do
      assert Cron.parse_to_preset("not a cron") == :custom
    end

    test "returns :custom for nil" do
      assert Cron.parse_to_preset(nil) == :custom
    end

    test "handles leading/trailing whitespace" do
      assert Cron.parse_to_preset("  0 * * * *  ") == {"every_hour", "0", "0", ["1"], "1"}
    end
  end

  describe "round-trip: compute_cron -> parse_to_preset" do
    test "every_minute round-trips" do
      expr = Cron.compute_cron("every_minute")
      {preset, _, _, _, _} = Cron.parse_to_preset(expr)
      assert preset == "every_minute"
    end

    test "every_hour round-trips" do
      expr = Cron.compute_cron("every_hour")
      {preset, _, _, _, _} = Cron.parse_to_preset(expr)
      assert preset == "every_hour"
    end

    test "daily round-trips" do
      expr = Cron.compute_cron("daily", "30", "14", ["1"], "1")
      assert Cron.parse_to_preset(expr) == {"daily", "30", "14", ["1"], "1"}
    end

    test "weekly round-trips" do
      expr = Cron.compute_cron("weekly", "0", "9", ["1", "3", "5"], "1")
      {preset, minute, hour, weekdays, _dom} = Cron.parse_to_preset(expr)
      assert preset == "weekly"
      assert minute == "0"
      assert hour == "9"
      assert Enum.sort(weekdays) == ["1", "3", "5"]
    end

    test "monthly round-trips" do
      expr = Cron.compute_cron("monthly", "0", "9", ["1"], "15")
      assert Cron.parse_to_preset(expr) == {"monthly", "0", "9", ["1"], "15"}
    end
  end

  describe "describe/1" do
    test "describes every minute" do
      assert Cron.describe("* * * * *") == "every minute"
    end

    test "describes every 5 minutes" do
      assert Cron.describe("*/5 * * * *") == "every 5 minutes"
    end

    test "describes every hour" do
      assert Cron.describe("0 * * * *") == "every hour"
    end

    test "describes daily at specific time" do
      assert Cron.describe("0 9 * * *") == "daily at 9:00"
    end

    test "describes daily at midnight" do
      assert Cron.describe("0 0 * * *") == "daily at midnight"
    end

    test "describes weekly schedule" do
      assert Cron.describe("0 9 * * 1-5") == "Mon-Fri at 9:00"
    end
  end
end
