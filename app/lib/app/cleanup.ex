defmodule Prikke.Cleanup do
  @moduledoc """
  Scheduled cleanup of old execution history.

  Runs daily at 3 AM UTC and deletes executions older than
  the organization's tier retention limit:

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
  alias Prikke.Jobs

  # Advisory lock ID for cleanup (different from scheduler)
  @advisory_lock_id 728_492_848

  # Check every hour if it's time to run cleanup
  @check_interval :timer.hours(1)

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
    Logger.info("[Cleanup] Starting execution history cleanup")

    organizations = Accounts.list_all_organizations()

    results =
      Enum.map(organizations, fn org ->
        retention_days = get_retention_days(org.tier)
        {deleted, _} = Executions.cleanup_old_executions(org, retention_days)
        {org.id, deleted}
      end)

    total_deleted = Enum.reduce(results, 0, fn {_, count}, acc -> acc + count end)

    if total_deleted > 0 do
      Logger.info("[Cleanup] Deleted #{total_deleted} old executions")
    else
      Logger.info("[Cleanup] No old executions to delete")
    end

    {:ok, total_deleted}
  end

  defp get_retention_days(tier) do
    limits = Jobs.get_tier_limits(tier)
    limits.retention_days
  end
end
