defmodule Prikke.WorkerPool do
  @moduledoc """
  Worker pool manager that scales workers based on queue depth.

  ## Overview

  The pool manager periodically checks the pending execution count and
  adjusts the number of workers to match demand:

  - Minimum workers: 2 (always ready to process work)
  - Maximum workers: 20 (limit concurrent HTTP requests)
  - Scale up: spawn workers when queue > current workers
  - Scale down: workers self-terminate after idle timeout

  ## How It Works

  ```
  ┌─────────────────────────────────────────────────────────────────┐
  │                      WorkerPool Manager                         │
  │                                                                 │
  │  Every 5 seconds:                                               │
  │  1. Count pending executions (queue depth)                      │
  │  2. Count active workers                                        │
  │  3. Target = min(max_workers, max(min_workers, queue_depth))   │
  │  4. If workers < target: spawn (target - workers) new workers   │
  │  5. Workers self-terminate when idle (no manual scale-down)     │
  └─────────────────────────────────────────────────────────────────┘
  ```

  ## Configuration

  - `@check_interval` - How often to check queue depth (5 seconds)
  - `@min_workers` - Minimum workers to keep ready (2)
  - `@max_workers` - Maximum concurrent workers (20)

  ## Testing

  Start with `test_mode: true` to skip auto-checking.
  Call `scale/0` manually in tests.
  """

  use GenServer
  require Logger

  alias Prikke.Executions
  alias Prikke.WorkerSupervisor

  # Check queue depth every 5 seconds
  @check_interval 5_000

  # Worker pool bounds
  @min_workers 2
  @max_workers 20

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually trigger a scaling check.
  Returns `{:ok, %{queue: n, workers: n, spawned: n}}`.
  """
  def scale do
    GenServer.call(__MODULE__, :scale)
  end

  @doc """
  Returns current pool stats.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    test_mode = Keyword.get(opts, :test_mode, false)

    unless test_mode do
      # Start initial workers
      send(self(), :init_workers)
      # Schedule periodic scaling checks
      send(self(), :check)
    end

    {:ok, %{test_mode: test_mode}}
  end

  @impl true
  def handle_info(:init_workers, state) do
    # Start minimum workers on init
    spawn_workers(@min_workers)
    {:noreply, state}
  end

  @impl true
  def handle_info(:check, state) do
    do_scale()

    # Schedule next check
    Process.send_after(self(), :check, @check_interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:scale, _from, state) do
    result = do_scale()
    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      queue_depth: Executions.count_pending_executions(),
      active_workers: WorkerSupervisor.worker_count(),
      min_workers: @min_workers,
      max_workers: @max_workers
    }
    {:reply, stats, state}
  end

  ## Private Functions

  defp do_scale do
    queue_depth = Executions.count_pending_executions()
    current_workers = WorkerSupervisor.worker_count()

    # Target: at least min_workers, at most max_workers, scale with queue
    target = queue_depth
             |> max(@min_workers)
             |> min(@max_workers)

    spawned = if current_workers < target do
      to_spawn = target - current_workers
      spawn_workers(to_spawn)
      to_spawn
    else
      0
    end

    if spawned > 0 do
      Logger.info("[WorkerPool] Queue: #{queue_depth}, Workers: #{current_workers} -> #{current_workers + spawned}")
    end

    %{queue: queue_depth, workers: current_workers, spawned: spawned}
  end

  defp spawn_workers(count) when count > 0 do
    Enum.each(1..count, fn _ ->
      case WorkerSupervisor.start_worker() do
        {:ok, _pid} -> :ok
        {:error, reason} ->
          Logger.error("[WorkerPool] Failed to spawn worker: #{inspect(reason)}")
      end
    end)
  end

  defp spawn_workers(_), do: :ok
end
