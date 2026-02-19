defmodule Prikke.Cleanup do
  @moduledoc """
  Scheduled cleanup of old data.

  Runs daily at 3 AM UTC and cleans up:
  1. Executions older than tier retention limit
  2. Completed one-time tasks older than tier retention limit

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
  alias Prikke.Accounts.UserNotifier
  alias Prikke.Audit
  alias Prikke.Executions
  alias Prikke.Emails
  alias Prikke.Idempotency
  alias Prikke.Tasks
  alias Prikke.Monitors

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

  @doc """
  Manually trigger monthly summary email. Useful for testing from IEx.
  """
  def run_monthly_summary do
    send_monthly_summary()
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    test_mode = Keyword.get(opts, :test_mode, false)

    unless test_mode do
      # Check immediately on startup, then hourly
      send(self(), :check)
    end

    {:ok, %{test_mode: test_mode, last_cleanup_date: nil, last_monthly_email_date: nil}}
  end

  @impl true
  def handle_info(:check, state) do
    now = DateTime.utc_now()
    today = DateTime.to_date(now)

    # Always try to recover stale executions (runs every hour)
    recover_stale_executions()

    state =
      if should_run_cleanup?(now, state.last_cleanup_date) do
        # Send monthly summary BEFORE cleanup (captures last month's data before reset)
        state =
          if should_send_monthly_email?(now, state.last_monthly_email_date) do
            send_monthly_summary()
            %{state | last_monthly_email_date: today}
          else
            state
          end

        case run_with_lock() do
          {:ok, _result} ->
            %{state | last_cleanup_date: today}

          :skipped ->
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

  defp run_with_lock do
    Repo.transaction(fn ->
      case Repo.query("SELECT pg_try_advisory_xact_lock($1)", [@advisory_lock_id]) do
        {:ok, %{rows: [[true]]}} -> do_cleanup()
        _ -> Repo.rollback(:skipped)
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, :skipped} -> :skipped
      {:error, _} -> :skipped
    end
  end

  defp do_cleanup do
    Logger.info("[Cleanup] Starting cleanup")

    organizations = Accounts.list_all_organizations()

    # Aggregate scheduling precision BEFORE deleting executions
    # This preserves historical precision data beyond execution retention
    aggregate_scheduling_precision()

    {total_executions, total_tasks, total_pings} =
      Enum.reduce(organizations, {0, 0, 0}, fn org, {exec_acc, task_acc, ping_acc} ->
        retention_days = get_retention_days(org.tier)

        # Clean old executions
        {exec_deleted, _} = Executions.cleanup_old_executions(org, retention_days)

        # Clean completed one-time tasks
        {tasks_deleted, _} = Tasks.cleanup_completed_once_tasks(org, retention_days)

        # Permanently purge soft-deleted tasks past retention
        {purged, _} = Tasks.purge_deleted_tasks(org, retention_days)

        # Clean old monitor pings (respects tier retention)
        {pings_deleted, _} = Monitors.cleanup_old_pings(org, retention_days)

        {exec_acc + exec_deleted, task_acc + tasks_deleted + purged, ping_acc + pings_deleted}
      end)

    # Clean expired idempotency keys (24-hour TTL)
    {idempotency_deleted, _} = Idempotency.cleanup_expired_keys()

    # Clean old email logs (30 days)
    {emails_deleted, _} = Emails.cleanup_old_email_logs(30)

    # Clean old audit logs (90 days)
    {audit_deleted, _} = Audit.cleanup_old_audit_logs(90)

    # Clean old API latency data (90 days)
    {latency_deleted, _} = cleanup_old_latency_data(90)

    # Clean old scheduling precision data (90 days)
    {precision_deleted, _} = cleanup_old_precision_data(90)

    # Reset monthly execution counters if new month
    Executions.reset_monthly_execution_counts()

    pings_deleted = total_pings

    if total_executions > 0 or total_tasks > 0 or idempotency_deleted > 0 or pings_deleted > 0 or
         emails_deleted > 0 or audit_deleted > 0 or latency_deleted > 0 or precision_deleted > 0 do
      Logger.info(
        "[Cleanup] Deleted #{total_executions} executions, #{total_tasks} completed one-time tasks, #{idempotency_deleted} idempotency keys, #{pings_deleted} monitor pings, #{emails_deleted} email logs, #{audit_deleted} audit logs, #{latency_deleted} latency rows, #{precision_deleted} precision rows"
      )
    else
      Logger.info("[Cleanup] Nothing to clean up")
    end

    {:ok,
     %{
       executions: total_executions,
       tasks: total_tasks,
       idempotency_keys: idempotency_deleted,
       monitor_pings: pings_deleted,
       email_logs: emails_deleted,
       audit_logs: audit_deleted,
       latency_rows: latency_deleted,
       precision_rows: precision_deleted
     }}
  end

  defp get_retention_days(tier) do
    limits = Tasks.get_tier_limits(tier)
    limits.retention_days
  end

  defp should_send_monthly_email?(now, last_monthly_email_date) do
    today = DateTime.to_date(now)
    # Send on the 1st of each month, once per day
    now.day == 1 and last_monthly_email_date != today
  end

  defp send_monthly_summary do
    Logger.info("[Cleanup] Sending monthly summary email")

    now = DateTime.utc_now()

    # Calculate previous month for the summary
    {year, month} =
      if now.month == 1 do
        {now.year - 1, 12}
      else
        {now.year, now.month - 1}
      end

    month_start = Date.new!(year, month, 1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    month_name = Calendar.strftime(month_start, "%B %Y")

    platform_stats = Executions.get_platform_stats()
    this_month = platform_stats.this_month

    stats = %{
      total_users: Accounts.count_users(),
      new_users: Accounts.count_users_since(month_start),
      total_orgs: Accounts.count_organizations(),
      new_orgs: Accounts.count_organizations_since(month_start),
      pro_orgs: Accounts.count_pro_organizations(),
      total_tasks: Tasks.count_all_tasks(),
      enabled_tasks: Tasks.count_all_enabled_tasks(),
      executions: %{
        total: this_month.total,
        success: this_month.success,
        failed: this_month.failed,
        timeout: this_month.timeout
      },
      success_rate: Executions.get_platform_success_rate(month_start),
      top_orgs: Executions.list_organization_monthly_executions(limit: 5),
      total_monitors: Monitors.count_all_monitors(),
      down_monitors: Monitors.count_all_down_monitors(),
      emails_sent: Emails.count_emails_this_month(),
      month_name: month_name
    }

    case UserNotifier.deliver_monthly_summary(stats) do
      {:ok, _} ->
        Logger.info("[Cleanup] Monthly summary email sent successfully")

      {:error, reason} ->
        Logger.error("[Cleanup] Failed to send monthly summary: #{inspect(reason)}")
    end
  end

  defp cleanup_old_latency_data(days) do
    import Ecto.Query

    cutoff = Date.utc_today() |> Date.add(-days)

    Prikke.ApiMetrics.DailyLatency
    |> where([d], d.date < ^cutoff)
    |> Repo.delete_all()
  end

  defp cleanup_old_precision_data(days) do
    import Ecto.Query

    cutoff = Date.utc_today() |> Date.add(-days)

    Prikke.Executions.SchedulingPrecisionDaily
    |> where([d], d.date < ^cutoff)
    |> Repo.delete_all()
  end

  defp aggregate_scheduling_precision do
    # Only aggregate the last 3 days — older days are already stored.
    # This ensures yesterday's data is captured before executions get cleaned up,
    # while keeping the query fast (scans only a few days of executions).
    yesterday = Date.utc_today() |> Date.add(-1)
    three_days_ago = Date.utc_today() |> Date.add(-3)

    count = Executions.aggregate_scheduling_precision(three_days_ago, yesterday)

    if count > 0 do
      Logger.info("[Cleanup] Aggregated scheduling precision for #{count} days")
    end
  end

  # Recover executions stuck in "running" status (worker crashed or server restarted)
  defp recover_stale_executions do
    recovered = Executions.recover_stale_executions()

    if recovered > 0 do
      Logger.info("[Cleanup] Recovered #{recovered} stale execution(s) stuck in running status")
    end
  end
end
