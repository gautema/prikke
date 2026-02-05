defmodule Prikke.Cleanup do
  @moduledoc """
  Scheduled cleanup of old data.

  Runs daily at 3 AM UTC and cleans up:
  1. Executions older than tier retention limit
  2. Completed one-time jobs older than tier retention limit

  Retention limits:
  - Free: 7 days
  - Pro: 30 days

  Uses advisory lock for leader election (same pattern as Scheduler)
  so only one node performs cleanup in a cluster.
  """

  use GenServer
  require Logger

  alias Prikke.Repo
  alias Prikke.Accounts
  alias Prikke.Executions
  alias Prikke.Idempotency
  alias Prikke.Jobs

  # Advisory lock ID for cleanup (different from scheduler)
  @advisory_lock_id 728_492_848

  # Check every 5 minutes for stale executions, daily cleanup at 3 AM
  @check_interval :timer.minutes(5)

  # Run cleanup at 3 AM UTC
  @cleanup_hour 3

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually trigger cleanup. Used for testing.
  """
  def run_cleanup do
    GenServer.call(__MODULE__, :cleanup, :timer.minutes(5))
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    test_mode = Keyword.get(opts, :test_mode, false)

    unless test_mode do
      # Check immediately on startup, then hourly
      send(self(), :check)
    end

    {:ok, %{test_mode: test_mode, last_cleanup_date: nil}}
  end

  @impl true
  def handle_info(:check, state) do
    now = DateTime.utc_now()
    today = DateTime.to_date(now)

    # Always try to recover stale executions (runs every hour)
    recover_stale_executions()

    state =
      if should_run_cleanup?(now, state.last_cleanup_date) do
        case try_acquire_lock() do
          true ->
            do_cleanup()
            release_lock()
            %{state | last_cleanup_date: today}

          false ->
            # Another node is handling cleanup
            state
        end
      else
        state
      end

    # Schedule next check
    Process.send_after(self(), :check, @check_interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:cleanup, _from, state) do
    result = do_cleanup()
    today = DateTime.utc_now() |> DateTime.to_date()
    {:reply, result, %{state | last_cleanup_date: today}}
  end

  ## Private Functions

  defp should_run_cleanup?(now, last_cleanup_date) do
    today = DateTime.to_date(now)
    hour = now.hour

    # Run at 3 AM UTC, once per day
    hour == @cleanup_hour and last_cleanup_date != today
  end

  defp try_acquire_lock do
    case Repo.query("SELECT pg_try_advisory_lock($1)", [@advisory_lock_id]) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp release_lock do
    Repo.query("SELECT pg_advisory_unlock($1)", [@advisory_lock_id])
  end

  defp do_cleanup do
    Logger.info("[Cleanup] Starting cleanup")

    organizations = Accounts.list_all_organizations()

    {total_executions, total_jobs} =
      Enum.reduce(organizations, {0, 0}, fn org, {exec_acc, job_acc} ->
        retention_days = get_retention_days(org.tier)

        # Clean old executions
        {exec_deleted, _} = Executions.cleanup_old_executions(org, retention_days)

        # Clean completed one-time jobs
        {jobs_deleted, _} = Jobs.cleanup_completed_once_jobs(org, retention_days)

        {exec_acc + exec_deleted, job_acc + jobs_deleted}
      end)

    # Clean expired idempotency keys (24-hour TTL)
    {idempotency_deleted, _} = Idempotency.cleanup_expired_keys()

    if total_executions > 0 or total_jobs > 0 or idempotency_deleted > 0 do
      Logger.info(
        "[Cleanup] Deleted #{total_executions} executions, #{total_jobs} completed one-time jobs, #{idempotency_deleted} idempotency keys"
      )
    else
      Logger.info("[Cleanup] Nothing to clean up")
    end

    {:ok, %{executions: total_executions, jobs: total_jobs, idempotency_keys: idempotency_deleted}}
  end

  defp get_retention_days(tier) do
    limits = Jobs.get_tier_limits(tier)
    limits.retention_days
  end

  # Recover executions stuck in "running" status (worker crashed or server restarted)
  defp recover_stale_executions do
    recovered = Executions.recover_stale_executions()

    if recovered > 0 do
      Logger.info("[Cleanup] Recovered #{recovered} stale execution(s) stuck in running status")
    end
  end
end
