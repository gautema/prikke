defmodule Prikke.BadgesTest do
  use ExUnit.Case, async: true

  alias Prikke.Badges

  describe "flat_badge/3" do
    test "generates valid SVG" do
      svg = Badges.flat_badge("status", "passing", "#10b981")
      assert svg =~ ~s(<svg xmlns="http://www.w3.org/2000/svg")
      assert svg =~ "status"
      assert svg =~ "passing"
      assert svg =~ "#10b981"
    end

    test "escapes HTML entities in labels" do
      svg = Badges.flat_badge("<script>", "a&b", "#fff")
      assert svg =~ "&lt;script&gt;"
      assert svg =~ "a&amp;b"
      refute svg =~ "<script>"
    end

    test "truncates long labels" do
      long_name = String.duplicate("a", 100)
      svg = Badges.flat_badge(long_name, "ok", "#10b981")
      assert svg =~ "..."
      refute svg =~ long_name
    end
  end

  describe "uptime_bars/2" do
    test "generates bars for execution statuses" do
      statuses = ["success", "success", "failed", "success", "timeout"]
      svg = Badges.uptime_bars("uptime", statuses)
      assert svg =~ ~s(<svg xmlns="http://www.w3.org/2000/svg")
      assert svg =~ "#10b981"
      assert svg =~ "#ef4444"
      assert svg =~ "#f97316"
    end

    test "returns 'no data' badge when empty" do
      svg = Badges.uptime_bars("uptime", [])
      assert svg =~ "no data"
    end
  end

  describe "task_status_badge/1" do
    test "shows passing for successful task" do
      task = %{name: "My Task", enabled: true, last_execution_status: "success"}
      svg = Badges.task_status_badge(task)
      assert svg =~ "passing"
      assert svg =~ "#10b981"
    end

    test "shows failing for failed task" do
      task = %{name: "My Task", enabled: true, last_execution_status: "failed"}
      svg = Badges.task_status_badge(task)
      assert svg =~ "failing"
      assert svg =~ "#ef4444"
    end

    test "shows paused for disabled task" do
      task = %{name: "My Task", enabled: false, last_execution_status: "success"}
      svg = Badges.task_status_badge(task)
      assert svg =~ "paused"
    end

    test "shows unknown for task with no executions" do
      task = %{name: "My Task", enabled: true, last_execution_status: nil}
      svg = Badges.task_status_badge(task)
      assert svg =~ "unknown"
    end
  end

  describe "monitor_status_badge/1" do
    test "shows up for up monitor" do
      monitor = %{name: "My Monitor", enabled: true, status: "up"}
      svg = Badges.monitor_status_badge(monitor)
      assert svg =~ "up"
      assert svg =~ "#10b981"
    end

    test "shows down for down monitor" do
      monitor = %{name: "My Monitor", enabled: true, status: "down"}
      svg = Badges.monitor_status_badge(monitor)
      assert svg =~ "down"
      assert svg =~ "#ef4444"
    end

    test "shows paused for disabled monitor" do
      monitor = %{name: "My Monitor", enabled: false, status: "up"}
      svg = Badges.monitor_status_badge(monitor)
      assert svg =~ "paused"
    end
  end

  describe "endpoint_status_badge/1" do
    test "shows active for enabled endpoint" do
      endpoint = %{name: "My Endpoint", enabled: true}
      svg = Badges.endpoint_status_badge(endpoint)
      assert svg =~ "active"
      assert svg =~ "#10b981"
    end

    test "shows disabled for disabled endpoint" do
      endpoint = %{name: "My Endpoint", enabled: false}
      svg = Badges.endpoint_status_badge(endpoint)
      assert svg =~ "disabled"
    end
  end

  describe "generate_token/0" do
    test "generates unique tokens with bt_ prefix" do
      token1 = Badges.generate_token()
      token2 = Badges.generate_token()

      assert String.starts_with?(token1, "bt_")
      assert String.starts_with?(token2, "bt_")
      assert token1 != token2
      assert String.length(token1) == 27
    end
  end
end
