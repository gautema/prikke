defmodule Prikke.Metrics do
  @moduledoc """
  Lightweight system metrics collector.

  Samples metrics every 30 seconds and stores them in an ETS table
  as a circular buffer (60 entries = 30 minutes of history).

  Only collects cheap metrics (BEAM intrinsics + /proc reads).
  No DB queries or shell commands in the sampling loop.

  ETS table is public for reads, so LiveViews can read without
  going through the GenServer.
  """

  use GenServer
  require Logger

  @table :prikke_metrics
  @sample_interval 30_000
  @max_samples 60

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the latest metrics sample, or an empty map if none collected yet.
  Reads directly from ETS (no GenServer call).
  """
  def current do
    case :ets.lookup(@table, :latest_index) do
      [{:latest_index, idx}] ->
        actual_idx = rem(idx, @max_samples)

        case :ets.lookup(@table, {:sample, actual_idx}) do
          [{_, sample}] -> sample
          [] -> %{}
        end

      [] ->
        %{}
    end
  rescue
    ArgumentError -> %{}
  end

  @doc """
  Returns the last `count` samples, oldest first.
  Reads directly from ETS (no GenServer call).
  """
  def recent(count \\ @max_samples) do
    case :ets.lookup(@table, :latest_index) do
      [{:latest_index, latest_idx}] ->
        total_collected = min(count, latest_idx + 1) |> min(@max_samples)

        (latest_idx - total_collected + 1)..latest_idx
        |> Enum.map(fn idx ->
          actual_idx = rem(idx + @max_samples, @max_samples)

          case :ets.lookup(@table, {:sample, actual_idx}) do
            [{_, sample}] -> sample
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
  Returns currently active alerts.
  Reads directly from ETS (no GenServer call).
  """
  def alerts do
    case :ets.lookup(@table, :alerts) do
      [{:alerts, alerts}] -> alerts
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  @doc """
  Manually trigger a sample collection. Used in tests.
  """
  def sample do
    GenServer.call(__MODULE__, :sample)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    test_mode = Keyword.get(opts, :test_mode, false)

    # Create ETS table (public for reads)
    :ets.new(@table, [:named_table, :set, :public])
    :ets.insert(@table, {:alerts, []})

    unless test_mode do
      send(self(), :sample)
    end

    {:ok, %{test_mode: test_mode, sample_index: 0}}
  end

  @impl true
  def handle_info(:sample, state) do
    state = do_sample(state)

    Process.send_after(self(), :sample, @sample_interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:sample, _from, state) do
    state = do_sample(state)
    {:reply, :ok, state}
  end

  ## Private Functions

  defp do_sample(state) do
    sample = collect_sample()
    idx = rem(state.sample_index, @max_samples)

    :ets.insert(@table, {{:sample, idx}, sample})
    :ets.insert(@table, {:latest_index, state.sample_index})

    # Simple alert check (just store, no emails)
    alerts = check_alerts(sample)
    :ets.insert(@table, {:alerts, alerts})

    %{state | sample_index: state.sample_index + 1}
  end

  defp collect_sample do
    {system_memory_used_pct, system_memory_total_mb, system_memory_used_mb} = get_system_memory()

    %{
      timestamp: DateTime.utc_now(),
      # Application metrics (cheap in-memory lookups only)
      queue_depth: safe_count_pending(),
      active_workers: safe_worker_count(),
      running_executions: 0,
      # BEAM metrics (free — built-in intrinsics)
      beam_memory_mb: Float.round(:erlang.memory(:total) / (1024 * 1024), 1),
      beam_processes: :erlang.system_info(:process_count),
      run_queue: :erlang.statistics(:run_queue),
      # System metrics (cheap /proc reads, no shell commands)
      cpu_percent: get_cpu_percent(),
      system_memory_used_pct: system_memory_used_pct,
      system_memory_total_mb: system_memory_total_mb,
      system_memory_used_mb: system_memory_used_mb,
      disk_usage_pct: 0
    }
  end

  defp safe_count_pending do
    Prikke.Executions.count_pending_executions_bounded(200)
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  defp safe_worker_count do
    Prikke.WorkerSupervisor.worker_count()
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  # Read /proc/stat directly — no port programs, no os_mon dependency.
  # Stores previous sample in ETS for delta calculation.
  defp get_cpu_percent do
    case read_proc_stat() do
      {:ok, current} ->
        case :ets.lookup(@table, :cpu_prev) do
          [{:cpu_prev, prev}] ->
            delta_total = current.total - prev.total
            delta_idle = current.idle - prev.idle

            pct =
              if delta_total > 0 do
                Float.round((delta_total - delta_idle) / delta_total * 100, 1)
              else
                0.0
              end

            :ets.insert(@table, {:cpu_prev, current})
            pct

          [] ->
            :ets.insert(@table, {:cpu_prev, current})
            0.0
        end

      :error ->
        0.0
    end
  rescue
    _ -> 0.0
  end

  defp read_proc_stat do
    case File.read("/proc/stat") do
      {:ok, content} ->
        case String.split(content, "\n") |> hd() |> String.split() do
          ["cpu" | values] ->
            nums = Enum.map(values, fn v -> String.to_integer(v) end)
            total = Enum.sum(nums)
            idle = Enum.at(nums, 3, 0) + Enum.at(nums, 4, 0)
            {:ok, %{total: total, idle: idle}}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp get_system_memory do
    case File.read("/proc/meminfo") do
      {:ok, content} -> parse_proc_meminfo(content)
      _ -> {0.0, 0.0, 0.0}
    end
  rescue
    _ -> {0.0, 0.0, 0.0}
  end

  defp parse_proc_meminfo(content) do
    values =
      content
      |> String.split("\n")
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, ~r/:\s+/) do
          [key, rest] ->
            case Integer.parse(rest) do
              {val_kb, _} -> Map.put(acc, key, val_kb)
              _ -> acc
            end

          _ ->
            acc
        end
      end)

    total_kb = Map.get(values, "MemTotal", 0)
    available_kb = Map.get(values, "MemAvailable", Map.get(values, "MemFree", 0))
    used_kb = total_kb - available_kb

    total_mb = Float.round(total_kb / 1024, 0)
    used_mb = Float.round(used_kb / 1024, 0)
    pct = if total_kb > 0, do: Float.round(used_kb / total_kb * 100, 1), else: 0.0

    {pct, total_mb, used_mb}
  end

  defp check_alerts(sample) do
    alerts = []

    alerts =
      if sample.queue_depth >= 200 do
        [%{level: :critical, metric: "queue_depth", value: sample.queue_depth} | alerts]
      else
        if sample.queue_depth >= 50 do
          [%{level: :warning, metric: "queue_depth", value: sample.queue_depth} | alerts]
        else
          alerts
        end
      end

    alerts =
      if sample.cpu_percent >= 95 do
        [%{level: :critical, metric: "cpu_percent", value: sample.cpu_percent} | alerts]
      else
        if sample.cpu_percent >= 80 do
          [%{level: :warning, metric: "cpu_percent", value: sample.cpu_percent} | alerts]
        else
          alerts
        end
      end

    Enum.reverse(alerts)
  end
end
