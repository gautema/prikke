defmodule Prikke.ApiMetrics do
  @moduledoc """
  Tracks API response times using an ETS circular buffer.

  Attaches a telemetry handler to [:phoenix, :router_dispatch, :stop]
  and records the last 1000 API requests with their duration, method,
  path, and status code.

  ETS table is public for reads, so LiveViews can read without
  going through the GenServer.
  """

  use GenServer

  @table :prikke_api_metrics
  @max_entries 1000

  @api_prefixes ["/api/v1/", "/ping/", "/in/"]

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

  ## Server Callbacks

  @impl true
  def init(opts) do
    test_mode = Keyword.get(opts, :test_mode, false)

    :ets.new(@table, [:named_table, :set, :public])

    unless test_mode do
      :telemetry.attach(
        "prikke-api-metrics",
        [:phoenix, :router_dispatch, :stop],
        &__MODULE__.handle_telemetry_event/4,
        nil
      )
    end

    {:ok, %{entry_index: 0}}
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
    idx = rem(state.entry_index, @max_entries)
    :ets.insert(@table, {{:entry, idx}, entry})
    :ets.insert(@table, {:latest_index, state.entry_index})

    {:noreply, %{state | entry_index: state.entry_index + 1}}
  end

  ## Private Functions

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
