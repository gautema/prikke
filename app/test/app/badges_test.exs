defmodule Prikke.BadgesTest do
  use ExUnit.Case, async: true

  alias Prikke.Badges

  describe "flat_badge/3" do
    test "generates valid SVG with name and colored dot" do
      svg = Badges.flat_badge("status", "passing", "#10b981")
      assert svg =~ ~s(<svg xmlns="http://www.w3.org/2000/svg")
      assert svg =~ "status"
      assert svg =~ ~s(fill="#10b981")
      assert svg =~ "<circle"
    end

    test "escapes HTML entities in labels" do
      svg = Badges.flat_badge("<script>", "a&b", "#fff")
      assert svg =~ "&lt;script&gt;"
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

    test "returns dot badge when empty" do
      svg = Badges.uptime_bars("uptime", [])
      assert svg =~ "<circle"
      assert svg =~ "#94a3b8"
    end
  end

  describe "task_status_badge/1" do
    test "shows green dot for successful task" do
      task = %{name: "My Task", enabled: true, last_execution_status: "success"}
      svg = Badges.task_status_badge(task)
      assert svg =~ "My Task"
      assert svg =~ ~s(fill="#10b981")
    end

    test "shows red dot for failed task" do
      task = %{name: "My Task", enabled: true, last_execution_status: "failed"}
      svg = Badges.task_status_badge(task)
      assert svg =~ "My Task"
      assert svg =~ ~s(fill="#ef4444")
    end

    test "shows gray dot for disabled task" do
      task = %{name: "My Task", enabled: false, last_execution_status: "success"}
      svg = Badges.task_status_badge(task)
      assert svg =~ ~s(fill="#94a3b8")
    end

    test "shows gray dot for task with no executions" do
      task = %{name: "My Task", enabled: true, last_execution_status: nil}
      svg = Badges.task_status_badge(task)
      assert svg =~ ~s(fill="#94a3b8")
    end
  end

  describe "monitor_status_badge/1" do
    test "shows green dot for up monitor" do
      monitor = %{name: "My Monitor", enabled: true, status: "up"}
      svg = Badges.monitor_status_badge(monitor)
      assert svg =~ "My Monitor"
      assert svg =~ ~s(fill="#10b981")
    end

    test "shows red dot for down monitor" do
      monitor = %{name: "My Monitor", enabled: true, status: "down"}
      svg = Badges.monitor_status_badge(monitor)
      assert svg =~ ~s(fill="#ef4444")
    end

    test "shows gray dot for disabled monitor" do
      monitor = %{name: "My Monitor", enabled: false, status: "up"}
      svg = Badges.monitor_status_badge(monitor)
      assert svg =~ ~s(fill="#94a3b8")
    end
  end

  describe "endpoint_status_badge/2" do
    test "shows green dot when last event succeeded" do
      endpoint = %{name: "My Endpoint", enabled: true}
      svg = Badges.endpoint_status_badge(endpoint, "success")
      assert svg =~ "My Endpoint"
      assert svg =~ ~s(fill="#10b981")
    end

    test "shows red dot when last event failed" do
      endpoint = %{name: "My Endpoint", enabled: true}
      svg = Badges.endpoint_status_badge(endpoint, "failed")
      assert svg =~ ~s(fill="#ef4444")
    end

    test "shows gray dot when no events" do
      endpoint = %{name: "My Endpoint", enabled: true}
      svg = Badges.endpoint_status_badge(endpoint)
      assert svg =~ ~s(fill="#94a3b8")
    end

    test "shows gray dot for disabled endpoint" do
      endpoint = %{name: "My Endpoint", enabled: false}
      svg = Badges.endpoint_status_badge(endpoint)
      assert svg =~ ~s(fill="#94a3b8")
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
