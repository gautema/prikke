defmodule Prikke.ApiMetrics.DailyLatencyTest do
  use Prikke.DataCase, async: false

  alias Prikke.ApiMetrics
  alias Prikke.ApiMetrics.DailyLatency

  setup do
    # Stop the application-started ApiMetrics if running
    case GenServer.whereis(ApiMetrics) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 5000)
    end

    pid = start_supervised!({ApiMetrics, test_mode: true})
    _ = :sys.get_state(pid)
    :ok
  end

  defp make_entry(opts) do
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

  describe "flush_histograms/0" do
    test "flushes ETS histogram data to database" do
      record_and_sync(make_entry(%{duration_us: 3_000, group: "tasks"}))
      record_and_sync(make_entry(%{duration_us: 15_000, group: "tasks"}))
      record_and_sync(make_entry(%{duration_us: 100_000, group: "ping"}))

      assert :ok = ApiMetrics.flush_histograms()

      # Should have rows for tasks, ping, and all
      rows = Repo.all(DailyLatency)
      groups = Enum.map(rows, & &1.group) |> Enum.sort()
      assert "all" in groups
      assert "tasks" in groups
      assert "ping" in groups

      all_row = Enum.find(rows, &(&1.group == "all"))
      assert all_row.request_count == 3
      assert all_row.total_duration_us == 118_000
      assert all_row.date == Date.utc_today()

      tasks_row = Enum.find(rows, &(&1.group == "tasks"))
      assert tasks_row.request_count == 2
    end

    test "additive upsert accumulates on second flush" do
      record_and_sync(make_entry(%{duration_us: 3_000, group: "tasks"}))
      assert :ok = ApiMetrics.flush_histograms()

      # Record more after first flush
      record_and_sync(make_entry(%{duration_us: 7_000, group: "tasks"}))
      assert :ok = ApiMetrics.flush_histograms()

      rows = Repo.all(from d in DailyLatency, where: d.group == "tasks")
      assert length(rows) == 1

      row = hd(rows)
      assert row.request_count == 2
      assert row.total_duration_us == 10_000
    end

    test "resets ETS counters after flush" do
      record_and_sync(make_entry(%{duration_us: 3_000, group: "tasks"}))
      assert :ok = ApiMetrics.flush_histograms()

      today = Date.utc_today() |> Date.to_iso8601()
      [{_, count}] = :ets.lookup(:prikke_api_metrics, {:hist_count, today, "tasks"})
      assert count == 0
    end
  end

  describe "list_daily_latency/1" do
    test "returns empty list when no data" do
      assert ApiMetrics.list_daily_latency(30) == []
    end

    test "returns daily latency data from database" do
      record_and_sync(make_entry(%{duration_us: 3_000, group: "tasks"}))
      record_and_sync(make_entry(%{duration_us: 15_000, group: "tasks"}))
      assert :ok = ApiMetrics.flush_histograms()

      result = ApiMetrics.list_daily_latency(30)
      assert length(result) == 1

      entry = hd(result)
      assert entry.date == Date.utc_today()
      assert entry.request_count == 2
      assert entry.avg > 0
      assert entry.p50 > 0
      assert entry.p95 > 0
      assert entry.p99 > 0
    end

    test "only returns 'all' group" do
      record_and_sync(make_entry(%{duration_us: 3_000, group: "tasks"}))
      record_and_sync(make_entry(%{duration_us: 15_000, group: "ping"}))
      assert :ok = ApiMetrics.flush_histograms()

      result = ApiMetrics.list_daily_latency(30)
      # Should only have one entry (the "all" group)
      assert length(result) == 1
    end
  end

  describe "get_today_latency/0" do
    test "returns zeros when no data" do
      result = ApiMetrics.get_today_latency()
      assert result.request_count == 0
      assert result.p50 == 0
      assert result.p95 == 0
      assert result.p99 == 0
      assert result.avg == 0
    end

    test "returns live ETS data for today" do
      record_and_sync(make_entry(%{duration_us: 3_000, group: "tasks"}))
      record_and_sync(make_entry(%{duration_us: 15_000, group: "tasks"}))

      result = ApiMetrics.get_today_latency()
      assert result.request_count == 2
      assert result.date == Date.utc_today()
      assert result.avg == 9_000
    end
  end

  describe "DailyLatency schema" do
    test "changeset validates required fields" do
      changeset = DailyLatency.changeset(%DailyLatency{}, %{})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).date
      assert "can't be blank" in errors_on(changeset).group
    end

    test "changeset accepts valid attributes" do
      changeset =
        DailyLatency.changeset(%DailyLatency{}, %{
          date: ~D[2026-02-13],
          group: "all",
          request_count: 100,
          total_duration_us: 500_000,
          bucket_0: 10,
          bucket_1: 20,
          bucket_2: 30,
          bucket_3: 20,
          bucket_4: 10,
          bucket_5: 5,
          bucket_6: 3,
          bucket_7: 1,
          bucket_8: 1,
          bucket_9: 0,
          bucket_10: 0,
          bucket_11: 0,
          bucket_12: 0
        })

      assert changeset.valid?
    end
  end
end
