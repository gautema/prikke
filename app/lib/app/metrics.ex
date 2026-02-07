defmodule Prikke.Metrics do
  @moduledoc """
  System and application metrics collector.

  Samples metrics every 10 seconds and stores them in an ETS table
  as a circular buffer (60 entries = 10 minutes of history).

  ## Metrics tracked

  - Queue depth (pending executions)
  - Active workers
  - Running executions
  - BEAM memory, process count, run queue length
  - System CPU, memory, disk usage (via :os_mon)

  ## Usage

      Prikke.Metrics.current()   # Latest sample
      Prikke.Metrics.recent(30)  # Last 30 samples
      Prikke.Metrics.alerts()    # Active alerts

  ETS table is public for reads, so LiveViews can read without
  going through the GenServer.
  """

  use GenServer
  require Logger

  @table :prikke_metrics
  @sample_interval 10_000
  @max_samples 60

  # Alert thresholds
  @queue_depth_warning 50
  @queue_depth_critical 200
  @cpu_warning_pct 80
  @cpu_critical_pct 95
  @memory_warning_pct 80
  @memory_critical_pct 90
  @disk_warning_pct 80
  @disk_critical_pct 90

  # Throttle: max one alert email per metric per hour
  @alert_throttle_seconds 3600

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

    {:ok, %{test_mode: test_mode, sample_index: 0, last_alert_at: %{}}}
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

    # Check alerts
    {alerts, last_alert_at} = check_alerts(sample, state.last_alert_at)
    :ets.insert(@table, {:alerts, alerts})

    %{state | sample_index: state.sample_index + 1, last_alert_at: last_alert_at}
  end

  defp collect_sample do
    {system_memory_used_pct, system_memory_total_mb, system_memory_used_mb} = get_system_memory()
    disk_usage_pct = get_disk_usage()

    %{
      timestamp: DateTime.utc_now(),
      # Application metrics
      queue_depth: safe_count_pending(),
      active_workers: safe_worker_count(),
      running_executions: safe_count_running(),
      # BEAM metrics
      beam_memory_mb: Float.round(:erlang.memory(:total) / (1024 * 1024), 1),
      beam_processes: :erlang.system_info(:process_count),
      run_queue: :erlang.statistics(:run_queue),
      # System metrics
      cpu_percent: get_cpu_percent(),
      system_memory_used_pct: system_memory_used_pct,
      system_memory_total_mb: system_memory_total_mb,
      system_memory_used_mb: system_memory_used_mb,
      disk_usage_pct: disk_usage_pct
    }
  end

  defp safe_count_pending do
    Prikke.Executions.count_pending_executions()
  rescue
    _ -> 0
  end

  defp safe_worker_count do
    Prikke.WorkerSupervisor.worker_count()
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  defp safe_count_running do
    import Ecto.Query

    Prikke.Executions.Execution
    |> where([e], e.status == "running")
    |> Prikke.Repo.aggregate(:count)
  rescue
    _ -> 0
  end

  defp get_cpu_percent do
    case :cpu_sup.util() do
      {:error, _} -> 0.0
      value when is_float(value) -> Float.round(value, 1)
      value when is_integer(value) -> value * 1.0
      _ -> 0.0
    end
  rescue
    _ -> 0.0
  catch
    :exit, _ -> 0.0
  end

  # Read /proc/meminfo directly for accurate values (same source as `free`).
  # MemAvailable accounts for reclaimable cache/buffers, unlike MemFree.
  # Falls back to :memsup on non-Linux (macOS dev).
  defp get_system_memory do
    case File.read("/proc/meminfo") do
      {:ok, content} -> parse_proc_meminfo(content)
      _ -> get_system_memory_from_memsup()
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

  defp get_system_memory_from_memsup do
    data = :memsup.get_system_memory_data()
    total = Keyword.get(data, :total_memory, 0)
    available = Keyword.get(data, :available_memory, Keyword.get(data, :free_memory, 0))
    used = total - available
    total_mb = Float.round(total / (1024 * 1024), 0)
    used_mb = Float.round(used / (1024 * 1024), 0)
    pct = if total > 0, do: Float.round(used / total * 100, 1), else: 0.0

    {pct, total_mb, used_mb}
  rescue
    _ -> {0.0, 0.0, 0.0}
  catch
    :exit, _ -> {0.0, 0.0, 0.0}
  end

  defp get_disk_usage do
    case :disksup.get_disk_data() do
      disks when is_list(disks) ->
        case List.keyfind(disks, ~c"/", 0) do
          {_, _, pct} when pct > 0 -> pct
          _ -> get_disk_usage_from_df()
        end

      _ ->
        get_disk_usage_from_df()
    end
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  defp get_disk_usage_from_df do
    case System.cmd("df", ["/"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n")
        |> Enum.at(1, "")
        |> String.split(~r/\s+/)
        |> Enum.find_value(0, fn col ->
          case Integer.parse(String.replace(col, "%", "")) do
            {pct, ""} when pct > 0 and pct <= 100 -> pct
            _ -> nil
          end
        end)

      _ ->
        0
    end
  rescue
    _ -> 0
  end

  defp check_alerts(sample, last_alert_at) do
    now = DateTime.utc_now()

    checks = [
      {"queue_depth", sample.queue_depth, @queue_depth_warning, @queue_depth_critical, ""},
      {"cpu_percent", sample.cpu_percent, @cpu_warning_pct, @cpu_critical_pct, "%"},
      {"system_memory", sample.system_memory_used_pct, @memory_warning_pct, @memory_critical_pct,
       "%"},
      {"disk_usage", sample.disk_usage_pct, @disk_warning_pct, @disk_critical_pct, "%"}
    ]

    {alerts, last_alert_at} =
      Enum.reduce(checks, {[], last_alert_at}, fn {metric, value, warning, critical, unit},
                                                   {alerts, alert_times} ->
        cond do
          value >= critical ->
            alert = %{
              level: :critical,
              metric: metric,
              value: value,
              threshold: critical,
              unit: unit
            }

            alert_times = maybe_send_alert(alert, alert_times, now)
            {[alert | alerts], alert_times}

          value >= warning ->
            alert = %{
              level: :warning,
              metric: metric,
              value: value,
              threshold: warning,
              unit: unit
            }

            alert_times = maybe_send_alert(alert, alert_times, now)
            {[alert | alerts], alert_times}

          true ->
            {alerts, alert_times}
        end
      end)

    {Enum.reverse(alerts), last_alert_at}
  end

  defp maybe_send_alert(alert, last_alert_at, now) do
    key = "#{alert.metric}_#{alert.level}"

    should_send =
      case Map.get(last_alert_at, key) do
        nil ->
          true

        last_sent ->
          DateTime.diff(now, last_sent) >= @alert_throttle_seconds
      end

    if should_send do
      send_alert_email(alert)
      Map.put(last_alert_at, key, now)
    else
      last_alert_at
    end
  end

  defp send_alert_email(alert) do
    Task.Supervisor.start_child(Prikke.TaskSupervisor, fn ->
      level_label = if alert.level == :critical, do: "CRITICAL", else: "WARNING"

      Logger.warning(
        "[Metrics] #{level_label}: #{alert.metric} at #{alert.value}#{alert.unit} (threshold: #{alert.threshold}#{alert.unit})"
      )
    end)
  end
end
