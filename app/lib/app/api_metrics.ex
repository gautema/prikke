defmodule Prikke.ApiMetrics do
  @moduledoc """
  Tracks API response times using an ETS circular buffer and histogram buckets.

  Attaches a telemetry handler to [:phoenix, :router_dispatch, :stop]
  and records the last 1000 API requests with their duration, method,
  path, and status code.

  Additionally maintains histogram bucket counters in ETS for daily latency
  aggregation. Flushes histogram data to the database hourly for persistence.

  ETS table is public for reads, so LiveViews can read without
  going through the GenServer.
  """

  use GenServer
  require Logger

  alias Prikke.ApiMetrics.DailyLatency
  alias Prikke.Repo

  @table :prikke_api_metrics
  @max_entries 1000

  @api_prefixes ["/api/v1/", "/ping/", "/in/"]

  # Histogram bucket edges in microseconds
  # [<1ms, 1-5ms, 5-10ms, 10-25ms, 25-50ms, 50-100ms, 100-250ms, 250-500ms, 500ms-1s, 1-2.5s, 2.5-5s, 5-10s, >10s]
  @bucket_edges [
    1_000,
    5_000,
    10_000,
    25_000,
    50_000,
    100_000,
    250_000,
    500_000,
    1_000_000,
    2_500_000,
    5_000_000,
    10_000_000
  ]
  @num_buckets 13

  # Upper bound of each bucket for percentile computation (in microseconds)
  @bucket_upper_bounds [
    1_000,
    5_000,
    10_000,
    25_000,
    50_000,
    100_000,
    250_000,
    500_000,
    1_000_000,
    2_500_000,
    5_000_000,
    10_000_000,
    30_000_000
  ]

  # Flush every 60 minutes
  @flush_interval :timer.minutes(60)

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records a request manually. Used for testing and direct recording.
  """
  def record_request(entry) when is_map(entry) do
    GenServer.cast(__MODULE__, {:record, entry})
  end

  @doc """
  Returns the last `limit` requests, newest first.
  Reads directly from ETS.
  """
  def recent_requests(limit \\ 20) do
    case :ets.lookup(@table, :latest_index) do
      [{:latest_index, latest_idx}] ->
        total = min(limit, min(latest_idx + 1, @max_entries))

        latest_idx..(latest_idx - total + 1)//-1
        |> Enum.map(fn idx ->
          actual = rem(idx + @max_entries, @max_entries)

          case :ets.lookup(@table, {:entry, actual}) do
            [{_, entry}] -> entry
            [] -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      [] ->
        []
    end
  rescue
    ArgumentError -> []
  end

  @doc """
  Returns overall p50, p95, p99 response times across all stored requests.
  """
  def percentiles do
    durations = all_durations()
    calculate_percentiles(durations)
  end

  @doc """
  Returns p50, p95, p99 response times grouped by endpoint category.
  """
  def percentiles_by_group do
    all_entries()
    |> Enum.group_by(& &1.group)
    |> Enum.map(fn {group, entries} ->
      durations = Enum.map(entries, & &1.duration_us)
      stats = calculate_percentiles(durations)
      Map.put(stats, :group, group)
    end)
    |> Enum.sort_by(& &1.group)
  end

  @doc """
  Returns the slowest `limit` requests.
  """
  def slowest(limit \\ 10) do
    all_entries()
    |> Enum.sort_by(& &1.duration_us, :desc)
    |> Enum.take(limit)
  end

  @doc """
  Returns the bucket index (0-12) for a given duration in microseconds.
  """
  def bucket_index(duration_us) do
    Enum.find_index(@bucket_edges, fn edge -> duration_us < edge end) ||
      length(@bucket_edges)
  end

  @doc """
  Computes approximate percentiles from histogram bucket counts.

  Takes a list of 13 counts (one per bucket) and returns a map with
  p50, p95, p99 values in microseconds (estimated from bucket boundaries).
  """
  def compute_percentiles_from_buckets(bucket_counts) when is_list(bucket_counts) do
    total = Enum.sum(bucket_counts)

    if total == 0 do
      %{p50: 0, p95: 0, p99: 0}
    else
      %{
        p50: percentile_from_histogram(bucket_counts, total, 0.50),
        p95: percentile_from_histogram(bucket_counts, total, 0.95),
        p99: percentile_from_histogram(bucket_counts, total, 0.99)
      }
    end
  end

  @doc """
  Returns daily latency data for the last `days` days from the database.
  Only returns the "all" group for the overview.

  Returns a list of maps: %{date: Date, p50: us, p95: us, p99: us, avg: us, request_count: int}
  """
  def list_daily_latency(days \\ 30) do
    import Ecto.Query

    since = Date.utc_today() |> Date.add(-days)

    db_rows =
      DailyLatency
      |> where([d], d.date >= ^since and d.group == "all")
      |> order_by([d], asc: d.date)
      |> Repo.all()
      |> Enum.map(&row_to_latency_map/1)

    # Merge live ETS data for today so the chart doesn't wait for the hourly flush
    today = Date.utc_today()
    today_ets = get_today_latency()

    case Enum.find_index(db_rows, fn row -> row.date == today end) do
      nil when today_ets.request_count > 0 ->
        db_rows ++ [today_ets]

      idx when is_integer(idx) and today_ets.request_count > 0 ->
        # Replace DB row with live ETS data (which includes unflushed requests)
        List.replace_at(db_rows, idx, today_ets)

      _ ->
        db_rows
    end
  end

  @doc """
  Returns today's latency data by merging DB (flushed) + ETS (unflushed) histograms.
  This gives an accurate real-time picture regardless of flush timing.
  """
  def get_today_latency do
    import Ecto.Query

    today = Date.utc_today()
    today_str = Date.to_iso8601(today)

    # ETS has unflushed delta since last flush
    ets_buckets = read_histogram_buckets(today_str, "all")
    ets_count = read_histogram_counter({:hist_count, today_str, "all"})
    ets_duration = read_histogram_counter({:hist_duration, today_str, "all"})

    # DB has accumulated data from previous flushes
    db_row =
      DailyLatency
      |> where([d], d.date == ^today and d.group == "all")
      |> Repo.one()

    {db_buckets, db_count, db_duration} =
      case db_row do
        nil ->
          {List.duplicate(0, @num_buckets), 0, 0}

        row ->
          buckets = for i <- 0..12, do: Map.get(row, String.to_existing_atom("bucket_#{i}"), 0)
          {buckets, row.request_count, row.total_duration_us}
      end

    # Merge: add ETS delta on top of DB totals
    merged_buckets = Enum.zip_with(db_buckets, ets_buckets, &(&1 + &2))
    merged_count = db_count + ets_count
    merged_duration = db_duration + ets_duration

    if merged_count > 0 do
      percentiles = compute_percentiles_from_buckets(merged_buckets)
      avg = div(merged_duration, merged_count)

      %{
        date: today,
        p50: percentiles.p50,
        p95: percentiles.p95,
        p99: percentiles.p99,
        avg: avg,
        request_count: merged_count
      }
    else
      %{date: today, p50: 0, p95: 0, p99: 0, avg: 0, request_count: 0}
    end
  end

  @doc """
  Manually trigger a histogram flush to the database.
  """
  def flush_histograms do
    GenServer.call(__MODULE__, :flush_histograms, :timer.seconds(30))
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    test_mode = Keyword.get(opts, :test_mode, false)

    Process.flag(:trap_exit, true)
    :ets.new(@table, [:named_table, :set, :public])

    unless test_mode do
      :telemetry.attach(
        "prikke-api-metrics",
        [:phoenix, :router_dispatch, :stop],
        &__MODULE__.handle_telemetry_event/4,
        nil
      )

      schedule_flush()
    end

    {:ok, %{entry_index: 0, test_mode: test_mode}}
  end

  @doc false
  def handle_telemetry_event(_event, measurements, metadata, _config) do
    conn = metadata.conn
    path = conn.request_path

    if api_route?(path) do
      duration_us = System.convert_time_unit(measurements.duration, :native, :microsecond)

      entry = %{
        path: path,
        method: conn.method,
        status: conn.status,
        duration_us: duration_us,
        group: categorize_path(path),
        timestamp: DateTime.utc_now()
      }

      record_request(entry)
    end
  end

  @impl true
  def handle_cast({:record, entry}, state) do
    # Circular buffer write
    idx = rem(state.entry_index, @max_entries)
    :ets.insert(@table, {{:entry, idx}, entry})
    :ets.insert(@table, {:latest_index, state.entry_index})

    # Histogram write
    duration_us = entry.duration_us
    group = entry.group
    today = Date.utc_today() |> Date.to_iso8601()
    bucket_idx = bucket_index(duration_us)

    # Update per-group and "all" group
    for g <- [group, "all"] do
      :ets.update_counter(
        @table,
        {:hist, today, g, bucket_idx},
        {2, 1},
        {{:hist, today, g, bucket_idx}, 0}
      )

      :ets.update_counter(@table, {:hist_count, today, g}, {2, 1}, {{:hist_count, today, g}, 0})

      :ets.update_counter(
        @table,
        {:hist_duration, today, g},
        {2, duration_us},
        {{:hist_duration, today, g}, 0}
      )
    end

    {:noreply, %{state | entry_index: state.entry_index + 1}}
  end

  @impl true
  def handle_info(:flush_histograms, state) do
    do_flush_histograms()
    schedule_flush()
    {:noreply, state}
  end

  @impl true
  def handle_call(:flush_histograms, _from, state) do
    result = do_flush_histograms()
    {:reply, result, state}
  end

  @impl true
  def terminate(_reason, _state) do
    do_flush_histograms()
    :ok
  rescue
    _ -> :ok
  end

  ## Private Functions

  defp schedule_flush do
    Process.send_after(self(), :flush_histograms, @flush_interval)
  end

  defp do_flush_histograms do
    # Find all histogram keys in ETS
    hist_keys = find_histogram_keys()

    # Group by {date, group}
    date_groups =
      hist_keys
      |> Enum.map(fn {:hist, date, group, _bucket_idx} -> {date, group} end)
      |> Enum.uniq()

    for {date, group} <- date_groups do
      bucket_counts = read_histogram_buckets(date, group)
      count = read_histogram_counter({:hist_count, date, group})
      duration = read_histogram_counter({:hist_duration, date, group})

      if count > 0 do
        upsert_daily_latency(date, group, count, duration, bucket_counts)

        # Reset counters after successful flush
        for i <- 0..(@num_buckets - 1) do
          :ets.insert(@table, {{:hist, date, group, i}, 0})
        end

        :ets.insert(@table, {{:hist_count, date, group}, 0})
        :ets.insert(@table, {{:hist_duration, date, group}, 0})
      end
    end

    :ok
  rescue
    error ->
      Logger.error("[ApiMetrics] Histogram flush failed: #{Exception.message(error)}")
      :error
  end

  defp find_histogram_keys do
    :ets.match_object(@table, {{:hist, :_, :_, :_}, :_})
    |> Enum.map(fn {key, _val} -> key end)
  rescue
    ArgumentError -> []
  end

  defp read_histogram_buckets(date, group) do
    for i <- 0..(@num_buckets - 1) do
      read_histogram_counter({:hist, date, group, i})
    end
  end

  defp read_histogram_counter(key) do
    case :ets.lookup(@table, key) do
      [{_, val}] -> val
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  defp upsert_daily_latency(date_string, group, count, duration, bucket_counts) do
    date = Date.from_iso8601!(date_string)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Build ON CONFLICT update for additive merge
    bucket_updates =
      for i <- 0..(@num_buckets - 1) do
        field = "bucket_#{i}"
        "#{field} = api_latency_daily.#{field} + EXCLUDED.#{field}"
      end

    conflict_set =
      [
        "request_count = api_latency_daily.request_count + EXCLUDED.request_count",
        "total_duration_us = api_latency_daily.total_duration_us + EXCLUDED.total_duration_us",
        "updated_at = EXCLUDED.updated_at"
        | bucket_updates
      ]
      |> Enum.join(", ")

    sql = """
    INSERT INTO api_latency_daily (id, date, "group", request_count, total_duration_us,
      bucket_0, bucket_1, bucket_2, bucket_3, bucket_4, bucket_5, bucket_6,
      bucket_7, bucket_8, bucket_9, bucket_10, bucket_11, bucket_12,
      inserted_at, updated_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20)
    ON CONFLICT (date, "group") DO UPDATE SET #{conflict_set}
    """

    id = Ecto.UUID.bingenerate()

    params =
      [
        id,
        date,
        group,
        count,
        duration
        | bucket_counts
      ] ++ [now, now]

    Repo.query!(sql, params)
  end

  defp percentile_from_histogram(bucket_counts, total, percentile) do
    target = ceil(total * percentile)
    cumulative = 0
    find_percentile_bucket(bucket_counts, @bucket_upper_bounds, cumulative, target, 0)
  end

  defp find_percentile_bucket([], _bounds, _cumulative, _target, _idx), do: 0

  defp find_percentile_bucket(
         [count | rest_counts],
         [bound | rest_bounds],
         cumulative,
         target,
         idx
       ) do
    new_cumulative = cumulative + count

    if new_cumulative >= target do
      bound
    else
      find_percentile_bucket(rest_counts, rest_bounds, new_cumulative, target, idx + 1)
    end
  end

  defp row_to_latency_map(row) do
    bucket_counts =
      for i <- 0..12 do
        Map.get(row, String.to_existing_atom("bucket_#{i}"), 0)
      end

    percentiles = compute_percentiles_from_buckets(bucket_counts)

    avg =
      if row.request_count > 0,
        do: div(row.total_duration_us, row.request_count),
        else: 0

    %{
      date: row.date,
      p50: percentiles.p50,
      p95: percentiles.p95,
      p99: percentiles.p99,
      avg: avg,
      request_count: row.request_count
    }
  end

  defp api_route?(path) do
    Enum.any?(@api_prefixes, &String.starts_with?(path, &1))
  end

  @doc false
  def categorize_path("/api/v1/tasks" <> _), do: "tasks"
  def categorize_path("/ping/" <> _), do: "ping"
  def categorize_path("/in/" <> _), do: "inbound"
  def categorize_path("/api/v1/" <> _), do: "other_api"
  def categorize_path(_), do: "unknown"

  defp all_entries do
    case :ets.lookup(@table, :latest_index) do
      [{:latest_index, latest_idx}] ->
        total = min(latest_idx + 1, @max_entries)

        latest_idx..(latest_idx - total + 1)//-1
        |> Enum.map(fn idx ->
          actual = rem(idx + @max_entries, @max_entries)

          case :ets.lookup(@table, {:entry, actual}) do
            [{_, entry}] -> entry
            [] -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      [] ->
        []
    end
  rescue
    ArgumentError -> []
  end

  defp all_durations do
    all_entries() |> Enum.map(& &1.duration_us)
  end

  defp calculate_percentiles([]), do: %{p50: 0, p95: 0, p99: 0, count: 0}

  defp calculate_percentiles(durations) do
    sorted = Enum.sort(durations)
    count = length(sorted)

    %{
      p50: percentile_value(sorted, count, 50),
      p95: percentile_value(sorted, count, 95),
      p99: percentile_value(sorted, count, 99),
      count: count
    }
  end

  defp percentile_value(sorted, count, percentile) do
    index = max(round(count * percentile / 100) - 1, 0)
    Enum.at(sorted, index)
  end
end
