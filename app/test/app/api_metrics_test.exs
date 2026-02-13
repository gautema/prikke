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
      record_and_sync(make_entry(%{group: "ping", duration_us: 3000}))
      record_and_sync(make_entry(%{group: "inbound", duration_us: 500}))

      results = ApiMetrics.percentiles_by_group()
      assert length(results) == 3

      groups = Enum.map(results, & &1.group) |> Enum.sort()
      assert groups == ["inbound", "ping", "tasks"]

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
      assert ApiMetrics.categorize_path("/api/v1/monitors") == "other_api"
      assert ApiMetrics.categorize_path("/api/v1/monitors/123/pings") == "other_api"
      assert ApiMetrics.categorize_path("/api/v1/endpoints") == "other_api"
      assert ApiMetrics.categorize_path("/api/v1/sync") == "other_api"
      assert ApiMetrics.categorize_path("/ping/abc123") == "ping"
      assert ApiMetrics.categorize_path("/in/my-webhook") == "inbound"
      assert ApiMetrics.categorize_path("/api/v1/openapi") == "other_api"
      assert ApiMetrics.categorize_path("/dashboard") == "unknown"
    end
  end

  describe "bucket_index/1" do
    test "assigns sub-millisecond to bucket 0" do
      assert ApiMetrics.bucket_index(500) == 0
      assert ApiMetrics.bucket_index(999) == 0
    end

    test "assigns 1-5ms to bucket 1" do
      assert ApiMetrics.bucket_index(1_000) == 1
      assert ApiMetrics.bucket_index(4_999) == 1
    end

    test "assigns 5-10ms to bucket 2" do
      assert ApiMetrics.bucket_index(5_000) == 2
      assert ApiMetrics.bucket_index(9_999) == 2
    end

    test "assigns 10-25ms to bucket 3" do
      assert ApiMetrics.bucket_index(10_000) == 3
      assert ApiMetrics.bucket_index(24_999) == 3
    end

    test "assigns 25-50ms to bucket 4" do
      assert ApiMetrics.bucket_index(25_000) == 4
    end

    test "assigns 50-100ms to bucket 5" do
      assert ApiMetrics.bucket_index(50_000) == 5
    end

    test "assigns 100-250ms to bucket 6" do
      assert ApiMetrics.bucket_index(100_000) == 6
    end

    test "assigns 250-500ms to bucket 7" do
      assert ApiMetrics.bucket_index(250_000) == 7
    end

    test "assigns 500ms-1s to bucket 8" do
      assert ApiMetrics.bucket_index(500_000) == 8
    end

    test "assigns 1-2.5s to bucket 9" do
      assert ApiMetrics.bucket_index(1_000_000) == 9
    end

    test "assigns 2.5-5s to bucket 10" do
      assert ApiMetrics.bucket_index(2_500_000) == 10
    end

    test "assigns 5-10s to bucket 11" do
      assert ApiMetrics.bucket_index(5_000_000) == 11
    end

    test "assigns >10s to bucket 12" do
      assert ApiMetrics.bucket_index(10_000_000) == 12
      assert ApiMetrics.bucket_index(99_000_000) == 12
    end
  end

  describe "compute_percentiles_from_buckets/1" do
    test "returns zeros for empty histogram" do
      buckets = List.duplicate(0, 13)
      assert ApiMetrics.compute_percentiles_from_buckets(buckets) == %{p50: 0, p95: 0, p99: 0}
    end

    test "returns correct percentiles for single bucket" do
      # All 100 requests in bucket 1 (1-5ms, upper bound 5_000us)
      buckets = [0, 100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
      result = ApiMetrics.compute_percentiles_from_buckets(buckets)
      assert result.p50 == 5_000
      assert result.p95 == 5_000
      assert result.p99 == 5_000
    end

    test "returns correct percentiles for distributed requests" do
      # 50 in bucket 1 (1-5ms), 40 in bucket 3 (10-25ms), 10 in bucket 6 (100-250ms)
      buckets = [0, 50, 0, 40, 0, 0, 10, 0, 0, 0, 0, 0, 0]
      result = ApiMetrics.compute_percentiles_from_buckets(buckets)

      # p50: 50th request out of 100 → in bucket 1 (first 50 are bucket 1)
      assert result.p50 == 5_000

      # p95: 95th request → 50 + 40 = 90, so 95th is in bucket 6
      assert result.p95 == 250_000

      # p99: 99th request → in bucket 6
      assert result.p99 == 250_000
    end
  end

  describe "histogram recording in ETS" do
    test "records histogram data alongside circular buffer" do
      record_and_sync(make_entry(%{duration_us: 3_000, group: "tasks"}))
      record_and_sync(make_entry(%{duration_us: 15_000, group: "ping"}))

      today = Date.utc_today() |> Date.to_iso8601()

      # Check "all" group count
      [{_, all_count}] = :ets.lookup(:prikke_api_metrics, {:hist_count, today, "all"})
      assert all_count == 2

      # Check per-group counts
      [{_, tasks_count}] = :ets.lookup(:prikke_api_metrics, {:hist_count, today, "tasks"})
      assert tasks_count == 1

      [{_, ping_count}] = :ets.lookup(:prikke_api_metrics, {:hist_count, today, "ping"})
      assert ping_count == 1
    end

    test "increments correct histogram bucket" do
      # 3_000us should go to bucket 1 (1-5ms)
      record_and_sync(make_entry(%{duration_us: 3_000, group: "tasks"}))

      today = Date.utc_today() |> Date.to_iso8601()

      [{_, bucket_1_count}] = :ets.lookup(:prikke_api_metrics, {:hist, today, "tasks", 1})
      assert bucket_1_count == 1

      # Bucket 0 should be empty
      assert :ets.lookup(:prikke_api_metrics, {:hist, today, "tasks", 0}) == []
    end

    test "accumulates duration sum" do
      record_and_sync(make_entry(%{duration_us: 3_000, group: "tasks"}))
      record_and_sync(make_entry(%{duration_us: 7_000, group: "tasks"}))

      today = Date.utc_today() |> Date.to_iso8601()

      [{_, total_duration}] = :ets.lookup(:prikke_api_metrics, {:hist_duration, today, "tasks"})
      assert total_duration == 10_000
    end
  end
end
