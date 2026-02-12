defmodule Prikke.ApiMetricsTest do
  use ExUnit.Case, async: true

  alias Prikke.ApiMetrics

  setup do
    # Start a fresh ApiMetrics process for each test with test_mode: true
    # to skip telemetry attachment (avoids conflicts with production handler)
    pid = start_supervised!({ApiMetrics, test_mode: true})
    # Ensure the GenServer is ready
    _ = :sys.get_state(pid)
    :ok
  end

  defp make_entry(opts \\ %{}) do
    Map.merge(
      %{
        path: "/api/v1/tasks",
        method: "GET",
        status: 200,
        duration_us: 1000,
        group: "tasks",
        timestamp: DateTime.utc_now()
      },
      opts
    )
  end

  defp record_and_sync(entry) do
    ApiMetrics.record_request(entry)
    _ = :sys.get_state(ApiMetrics)
  end

  describe "record_request/1 and recent_requests/1" do
    test "records and retrieves a single request" do
      entry = make_entry()
      record_and_sync(entry)

      [result] = ApiMetrics.recent_requests(10)
      assert result.path == "/api/v1/tasks"
      assert result.method == "GET"
      assert result.status == 200
      assert result.duration_us == 1000
    end

    test "returns newest first" do
      record_and_sync(make_entry(%{path: "/api/v1/tasks", duration_us: 100}))
      record_and_sync(make_entry(%{path: "/api/v1/monitors", duration_us: 200}))
      record_and_sync(make_entry(%{path: "/ping/abc", duration_us: 300}))

      results = ApiMetrics.recent_requests(10)
      assert length(results) == 3
      assert hd(results).path == "/ping/abc"
      assert List.last(results).path == "/api/v1/tasks"
    end

    test "respects the limit parameter" do
      for i <- 1..5 do
        record_and_sync(make_entry(%{duration_us: i * 100}))
      end

      results = ApiMetrics.recent_requests(3)
      assert length(results) == 3
    end

    test "returns empty list when no requests recorded" do
      assert ApiMetrics.recent_requests(10) == []
    end

    test "circular buffer wraps around" do
      # Record more than @max_entries (1000)
      for i <- 1..1005 do
        record_and_sync(make_entry(%{duration_us: i}))
      end

      results = ApiMetrics.recent_requests(1000)
      assert length(results) == 1000

      # Most recent should be 1005
      assert hd(results).duration_us == 1005
    end
  end

  describe "percentiles/0" do
    test "returns zeros when no requests" do
      assert ApiMetrics.percentiles() == %{p50: 0, p95: 0, p99: 0, count: 0}
    end

    test "calculates percentiles from recorded requests" do
      for i <- 1..100 do
        record_and_sync(make_entry(%{duration_us: i * 1000}))
      end

      result = ApiMetrics.percentiles()
      assert result.count == 100
      assert result.p50 == 50_000
      assert result.p95 == 95_000
      assert result.p99 == 99_000
    end

    test "handles single request" do
      record_and_sync(make_entry(%{duration_us: 5000}))

      result = ApiMetrics.percentiles()
      assert result.count == 1
      assert result.p50 == 5000
    end
  end

  describe "percentiles_by_group/0" do
    test "returns empty list when no requests" do
      assert ApiMetrics.percentiles_by_group() == []
    end

    test "groups by endpoint category" do
      record_and_sync(make_entry(%{group: "tasks", duration_us: 1000}))
      record_and_sync(make_entry(%{group: "tasks", duration_us: 2000}))
      record_and_sync(make_entry(%{group: "monitors", duration_us: 3000}))
      record_and_sync(make_entry(%{group: "ping", duration_us: 500}))

      results = ApiMetrics.percentiles_by_group()
      assert length(results) == 3

      groups = Enum.map(results, & &1.group) |> Enum.sort()
      assert groups == ["monitors", "ping", "tasks"]

      tasks_group = Enum.find(results, &(&1.group == "tasks"))
      assert tasks_group.count == 2
    end
  end

  describe "slowest/1" do
    test "returns empty list when no requests" do
      assert ApiMetrics.slowest(10) == []
    end

    test "returns slowest requests in descending order" do
      record_and_sync(make_entry(%{duration_us: 100, path: "/api/v1/tasks"}))
      record_and_sync(make_entry(%{duration_us: 5000, path: "/api/v1/monitors"}))
      record_and_sync(make_entry(%{duration_us: 3000, path: "/ping/abc"}))
      record_and_sync(make_entry(%{duration_us: 8000, path: "/in/webhook"}))

      results = ApiMetrics.slowest(3)
      assert length(results) == 3
      assert hd(results).duration_us == 8000
      assert Enum.at(results, 1).duration_us == 5000
      assert Enum.at(results, 2).duration_us == 3000
    end

    test "respects limit" do
      for i <- 1..10 do
        record_and_sync(make_entry(%{duration_us: i * 1000}))
      end

      results = ApiMetrics.slowest(5)
      assert length(results) == 5
    end
  end

  describe "categorize_path/1" do
    test "categorizes API paths correctly" do
      assert ApiMetrics.categorize_path("/api/v1/tasks") == "tasks"
      assert ApiMetrics.categorize_path("/api/v1/tasks/123") == "tasks"
      assert ApiMetrics.categorize_path("/api/v1/monitors") == "monitors"
      assert ApiMetrics.categorize_path("/api/v1/monitors/123/pings") == "monitors"
      assert ApiMetrics.categorize_path("/api/v1/endpoints") == "endpoints"
      assert ApiMetrics.categorize_path("/api/v1/sync") == "sync"
      assert ApiMetrics.categorize_path("/ping/abc123") == "ping"
      assert ApiMetrics.categorize_path("/in/my-webhook") == "inbound"
      assert ApiMetrics.categorize_path("/api/v1/openapi") == "other_api"
      assert ApiMetrics.categorize_path("/dashboard") == "unknown"
    end
  end
end
