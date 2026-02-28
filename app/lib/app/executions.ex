defmodule Prikke.Executions do
  @moduledoc """
  The Executions context.
  Handles task execution history and worker coordination.
  """

  import Ecto.Query, warn: false
  alias Prikke.Repo
  alias Prikke.Executions.Execution
  alias Prikke.Tasks.Task
  alias Prikke.Accounts.Organization

  # Max concurrent running executions per organization.
  # Prevents one org's backlog from starving all other orgs' workers.
  @max_concurrent_per_org 5

  def subscribe_task_executions(task_id) do
    Phoenix.PubSub.subscribe(Prikke.PubSub, "task:#{task_id}:executions")
  end

  def subscribe_organization_executions(org_id) do
    Phoenix.PubSub.subscribe(Prikke.PubSub, "org:#{org_id}:executions")
  end

  def broadcast_execution_update(execution) do
    Phoenix.PubSub.broadcast(
      Prikke.PubSub,
      "task:#{execution.task_id}:executions",
      {:execution_updated, execution}
    )

    # Use preloaded task if available, otherwise fetch for the org broadcast
    execution_with_task =
      if Ecto.assoc_loaded?(execution.task) do
        execution
      else
        get_execution_with_task(execution.id)
      end

    if execution_with_task do
      Phoenix.PubSub.broadcast(
        Prikke.PubSub,
        "org:#{execution_with_task.organization_id}:executions",
        {:execution_updated, execution_with_task}
      )
    end
  end

  def create_execution(attrs) do
    %Execution{}
    |> Execution.create_changeset(attrs)
    |> Repo.insert()
  end

  def create_execution_for_task(task, scheduled_for, opts_or_attempt \\ [])

  def create_execution_for_task(%Task{} = task, scheduled_for, attempt)
      when is_integer(attempt) do
    create_execution_for_task(task, scheduled_for, attempt: attempt)
  end

  def create_execution_for_task(%Task{} = task, scheduled_for, opts) when is_list(opts) do
    attempt = Keyword.get(opts, :attempt, 1)
    callback_url = Keyword.get(opts, :callback_url) || task.callback_url

    attrs = %{
      task_id: task.id,
      organization_id: task.organization_id,
      scheduled_for: scheduled_for,
      attempt: attempt,
      queue: task.queue
    }

    attrs =
      if callback_url do
        Map.put(attrs, :callback_url, callback_url)
      else
        attrs
      end

    create_execution(attrs)
  end

  def create_missed_execution(%Task{} = task, scheduled_for) do
    %Execution{}
    |> Execution.missed_changeset(%{
      task_id: task.id,
      organization_id: task.organization_id,
      scheduled_for: scheduled_for
    })
    |> Repo.insert()
  end

  def get_execution(id), do: Repo.get(Execution, id)

  def get_execution_with_task(id) do
    Execution
    |> Repo.get(id)
    |> Repo.preload(task: :organization)
  end

  def get_execution_for_org(organization, execution_id) do
    from(e in Execution,
      where: e.organization_id == ^organization.id and e.id == ^execution_id,
      preload: [:task]
    )
    |> Repo.one()
  end

  def get_execution_for_task(task, execution_id) do
    from(e in Execution,
      where: e.task_id == ^task.id and e.id == ^execution_id
    )
    |> Repo.one()
  end

  def claim_next_execution do
    now = DateTime.utc_now()

    # Simple NOT IN: exclude executions whose (org, queue) has a running
    # or pending-retry execution. The inner query hits the partial index
    # on (organization_id, queue, status) and returns a tiny set.
    # No joins or subquery materialization needed.
    query =
      from(e in Execution,
        where: e.status == "pending" and e.scheduled_for <= ^now,
        where: ^claimable_queue_filter(now),
        where: ^org_fairness_filter(),
        where: ^paused_queue_filter(),
        order_by: [asc: e.scheduled_for],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"
      )

    Repo.transaction(fn ->
      case Repo.one(query) do
        nil ->
          nil

        execution ->
          execution = Repo.preload(execution, task: :organization)

          case execution |> Execution.start_changeset() |> Repo.update() do
            {:ok, updated} -> %{updated | task: execution.task}
            {:error, _} -> nil
          end
      end
    end)
    |> case do
      {:ok, nil} -> {:ok, nil}
      {:ok, execution} -> {:ok, execution}
      {:error, reason} -> {:error, reason}
    end
  end

  def complete_execution(execution, attrs \\ %{}) do
    result =
      execution
      |> Execution.complete_changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated} ->
        maybe_increment_monthly_count(updated)
        touch_task_last_execution(updated)
        broadcast_execution_update(updated)

      _ ->
        :ok
    end

    result
  end

  def fail_execution(execution, attrs \\ %{}) do
    result =
      execution
      |> Execution.fail_changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated} ->
        maybe_increment_monthly_count(updated)
        touch_task_last_execution(updated)
        broadcast_execution_update(updated)

      _ ->
        :ok
    end

    result
  end

  def timeout_execution(execution, duration_ms \\ nil) do
    result =
      execution
      |> Execution.timeout_changeset(duration_ms)
      |> Repo.update()

    case result do
      {:ok, updated} ->
        maybe_increment_monthly_count(updated)
        touch_task_last_execution(updated)
        broadcast_execution_update(updated)

      _ ->
        :ok
    end

    result
  end

  def list_task_executions(task, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    status = Keyword.get(opts, :status)

    query =
      from(e in Execution,
        where: e.task_id == ^task.id,
        order_by: [desc: e.scheduled_for],
        limit: ^limit,
        offset: ^offset
      )

    query =
      if status && status != "" do
        from(e in query, where: e.status == ^status)
      else
        query
      end

    Repo.all(query)
  end

  def count_task_executions(task, opts \\ []) do
    status = Keyword.get(opts, :status)

    query = from(e in Execution, where: e.task_id == ^task.id)

    query =
      if status && status != "" do
        from(e in query, where: e.status == ^status)
      else
        query
      end

    Repo.aggregate(query, :count)
  end

  def get_latest_status(task) do
    from(e in Execution,
      where: e.task_id == ^task.id,
      order_by: [desc: e.scheduled_for],
      limit: 1,
      select: e.status
    )
    |> Repo.one()
  end

  def get_previous_status(task, current_execution_id) do
    from(e in Execution,
      where: e.task_id == ^task.id and e.id != ^current_execution_id,
      order_by: [desc: e.scheduled_for],
      limit: 1,
      select: e.status
    )
    |> Repo.one()
  end

  @doc """
  Returns the previous execution's {status, attempt} for a task.
  Used to determine if a failure notification was actually sent
  (only sent when all retries are exhausted).
  """
  def get_previous_execution_info(task, current_execution_id) do
    from(e in Execution,
      where: e.task_id == ^task.id and e.id != ^current_execution_id,
      order_by: [desc: e.scheduled_for],
      limit: 1,
      select: {e.status, e.attempt}
    )
    |> Repo.one()
  end

  def get_latest_statuses([]), do: %{}

  def get_latest_statuses(task_ids) when is_list(task_ids) do
    latest_times =
      from(e in Execution,
        where: e.task_id in ^task_ids,
        group_by: e.task_id,
        select: %{task_id: e.task_id, max_scheduled: max(e.scheduled_for)}
      )

    from(e in Execution,
      join: lt in subquery(latest_times),
      on: e.task_id == lt.task_id and e.scheduled_for == lt.max_scheduled,
      select:
        {e.task_id,
         %{
           status: e.status,
           attempt: e.attempt,
           scheduled_for: e.scheduled_for,
           duration_ms: e.duration_ms
         }}
    )
    |> Repo.all()
    |> Map.new()
  end

  def get_recent_statuses_for_tasks(task_ids, limit \\ 20)
  def get_recent_statuses_for_tasks([], _limit), do: %{}

  def get_recent_statuses_for_tasks(task_ids, limit) when is_list(task_ids) do
    numbered =
      from(e in Execution,
        where: e.task_id in ^task_ids and e.status not in ["pending", "running"],
        select: %{
          task_id: e.task_id,
          status: e.status,
          rn: over(row_number(), partition_by: e.task_id, order_by: [desc: e.scheduled_for])
        }
      )

    from(e in subquery(numbered),
      where: e.rn <= ^limit,
      order_by: [asc: e.task_id, asc: e.rn],
      select: {e.task_id, e.status}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  def list_organization_executions(organization, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(e in Execution,
      where: e.organization_id == ^organization.id,
      order_by: [desc: e.scheduled_for],
      limit: ^limit,
      preload: [:task]
    )
    |> Repo.all()
  end

  def count_pending_executions do
    now = DateTime.utc_now()

    from(e in Execution, where: e.status == "pending" and e.scheduled_for <= ^now)
    |> Repo.aggregate(:count)
  end

  @doc """
  Bounded count of claimable pending executions - stops counting at `limit`.
  Excludes queue-blocked executions so pool manager scales based on actual work.
  """
  def count_pending_executions_bounded(limit) do
    now = DateTime.utc_now()

    from(e in Execution,
      where: e.status == "pending" and e.scheduled_for <= ^now,
      where: ^claimable_queue_filter(now),
      where: ^org_fairness_filter(),
      where: ^paused_queue_filter(),
      limit: ^limit,
      select: e.id
    )
    |> Repo.all()
    |> length()
  end

  def get_task_stats(task, opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -24, :hour))

    from(e in Execution,
      where: e.task_id == ^task.id and e.scheduled_for >= ^since,
      select: %{
        total: count(),
        success: count(fragment("CASE WHEN ? = 'success' THEN 1 END", e.status)),
        failed: count(fragment("CASE WHEN ? = 'failed' THEN 1 END", e.status)),
        timeout: count(fragment("CASE WHEN ? = 'timeout' THEN 1 END", e.status)),
        pending: count(fragment("CASE WHEN ? = 'pending' THEN 1 END", e.status)),
        running: count(fragment("CASE WHEN ? = 'running' THEN 1 END", e.status)),
        missed: count(fragment("CASE WHEN ? = 'missed' THEN 1 END", e.status)),
        avg_duration_ms: avg(e.duration_ms)
      }
    )
    |> Repo.one()
  end

  def get_organization_stats(organization, opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -24, :hour))

    from(e in Execution,
      where: e.organization_id == ^organization.id and e.scheduled_for >= ^since,
      select: %{
        total: count(),
        success: count(fragment("CASE WHEN ? = 'success' THEN 1 END", e.status)),
        failed: count(fragment("CASE WHEN ? = 'failed' THEN 1 END", e.status)),
        timeout: count(fragment("CASE WHEN ? = 'timeout' THEN 1 END", e.status)),
        pending: count(fragment("CASE WHEN ? = 'pending' THEN 1 END", e.status)),
        running: count(fragment("CASE WHEN ? = 'running' THEN 1 END", e.status)),
        missed: count(fragment("CASE WHEN ? = 'missed' THEN 1 END", e.status)),
        avg_duration_ms: avg(e.duration_ms)
      }
    )
    |> Repo.one()
  end

  def count_current_month_executions(organization) do
    organization.monthly_execution_count || 0
  end

  def increment_monthly_execution_count(organization_id) do
    from(o in Organization, where: o.id == ^organization_id)
    |> Repo.update_all(inc: [monthly_execution_count: 1])
  end

  def reset_monthly_execution_counts do
    now = DateTime.utc_now()

    from(o in Organization,
      where:
        is_nil(o.monthly_execution_reset_at) or
          o.monthly_execution_reset_at < ^start_of_current_month()
    )
    |> Repo.update_all(set: [monthly_execution_count: 0, monthly_execution_reset_at: now])
  end

  defp start_of_current_month do
    now = DateTime.utc_now()
    Date.new!(now.year, now.month, 1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  defp touch_task_last_execution(%Execution{} = execution) do
    Prikke.ExecutionCounter.touch_task(execution.task_id, execution.status)
  end

  defp maybe_increment_monthly_count(%Execution{attempt: 1} = execution) do
    Prikke.ExecutionCounter.increment(execution.organization_id)
  end

  defp maybe_increment_monthly_count(_execution), do: :ok

  def get_today_stats(organization) do
    today = DateTime.utc_now() |> DateTime.to_date()
    since = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")
    get_organization_stats(organization, since: since)
  end

  @doc """
  Combined dashboard stats: today + 7d in a single query.
  Returns `{today_stats, stats_7d}`.
  """
  def get_dashboard_stats(organization) do
    today = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
    seven_days_ago = DateTime.add(DateTime.utc_now(), -7, :day)

    result =
      from(e in Execution,
        where: e.organization_id == ^organization.id and e.scheduled_for >= ^seven_days_ago,
        select: %{
          today_total: count(fragment("CASE WHEN ? >= ? THEN 1 END", e.scheduled_for, ^today)),
          today_success:
            count(
              fragment(
                "CASE WHEN ? >= ? AND ? = 'success' THEN 1 END",
                e.scheduled_for,
                ^today,
                e.status
              )
            ),
          today_failed:
            count(
              fragment(
                "CASE WHEN ? >= ? AND ? = 'failed' THEN 1 END",
                e.scheduled_for,
                ^today,
                e.status
              )
            ),
          today_timeout:
            count(
              fragment(
                "CASE WHEN ? >= ? AND ? = 'timeout' THEN 1 END",
                e.scheduled_for,
                ^today,
                e.status
              )
            ),
          today_avg_duration:
            fragment(
              "avg(CASE WHEN ? >= ? THEN ? END)",
              e.scheduled_for,
              ^today,
              e.duration_ms
            ),
          week_total: count(),
          week_success: count(fragment("CASE WHEN ? = 'success' THEN 1 END", e.status)),
          week_failed: count(fragment("CASE WHEN ? = 'failed' THEN 1 END", e.status))
        }
      )
      |> Repo.one()

    today_stats = %{
      total: result.today_total,
      success: result.today_success,
      failed: result.today_failed,
      timeout: result.today_timeout,
      avg_duration_ms: result.today_avg_duration
    }

    stats_7d = %{
      total: result.week_total,
      success: result.week_success,
      failed: result.week_failed
    }

    {today_stats, stats_7d}
  end

  @doc """
  Deletes all pending executions for a task.
  Called when a task is soft-deleted to prevent queued work from running.
  """
  def cancel_pending_executions_for_task(%Task{} = task) do
    from(e in Execution,
      where: e.task_id == ^task.id,
      where: e.status == "pending"
    )
    |> Repo.delete_all()
  end

  def cleanup_old_executions(organization, retention_days) do
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days, :day)

    from(e in Execution,
      where: e.organization_id == ^organization.id,
      where: e.finished_at < ^cutoff
    )
    |> Repo.delete_all()
  end

  @doc """
  Reschedule a running execution back to pending with a new scheduled_for time.
  Used by the worker when a host is blocked (429/repeated failures).
  Clears started_at so it can be claimed again when the block expires.
  """
  def reschedule_execution(execution, scheduled_for) do
    execution
    |> Ecto.Changeset.change(%{
      status: "pending",
      scheduled_for: DateTime.truncate(scheduled_for, :second),
      started_at: nil
    })
    |> Repo.update()
  end

  def recover_stale_executions(stale_threshold_minutes \\ 5) do
    cutoff = DateTime.add(DateTime.utc_now(), -stale_threshold_minutes, :minute)

    stale_executions =
      from(e in Execution,
        join: t in Task,
        on: e.task_id == t.id,
        where: e.status == "running" and e.started_at < ^cutoff,
        preload: [task: t]
      )
      |> Repo.all()

    Enum.each(stale_executions, fn execution ->
      execution
      |> Execution.fail_changeset(%{
        error_message: "Execution interrupted (worker restart or crash)"
      })
      |> Repo.update()
    end)

    length(stale_executions)
  end

  def get_duration_percentiles(since \\ nil) do
    since = since || DateTime.add(DateTime.utc_now(), -1, :hour)

    from(e in Execution,
      where: e.status in ["success", "failed", "timeout"],
      where: e.finished_at >= ^since,
      where: not is_nil(e.duration_ms),
      select: %{
        p50: fragment("percentile_cont(0.5) WITHIN GROUP (ORDER BY ?)", e.duration_ms),
        p95: fragment("percentile_cont(0.95) WITHIN GROUP (ORDER BY ?)", e.duration_ms),
        p99: fragment("percentile_cont(0.99) WITHIN GROUP (ORDER BY ?)", e.duration_ms),
        avg: avg(e.duration_ms),
        count: count(e.id)
      }
    )
    |> Repo.one()
  end

  def get_avg_queue_wait(since \\ nil) do
    since = since || DateTime.add(DateTime.utc_now(), -1, :hour)

    from(e in Execution,
      where: e.status in ["success", "failed", "timeout"],
      where: e.finished_at >= ^since,
      where: not is_nil(e.started_at),
      select: %{
        avg_wait_ms:
          avg(fragment("EXTRACT(EPOCH FROM (? - ?)) * 1000", e.started_at, e.scheduled_for)),
        max_wait_ms:
          max(fragment("EXTRACT(EPOCH FROM (? - ?)) * 1000", e.started_at, e.scheduled_for)),
        count: count(e.id)
      }
    )
    |> Repo.one()
  end

  @doc """
  Returns scheduling precision percentiles (p50, p95, p99, avg, max) for the last hour.
  Delay = started_at - scheduled_for in milliseconds.
  """
  def get_scheduling_precision(since \\ nil) do
    since = since || DateTime.add(DateTime.utc_now(), -1, :hour)

    from(e in Execution,
      where: is_nil(e.queue),
      where: e.status in ["success", "failed", "timeout"],
      where: e.finished_at >= ^since,
      where: not is_nil(e.started_at),
      where: not is_nil(e.scheduled_for),
      select: %{
        p50:
          fragment(
            "percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (? - ?)) * 1000)",
            e.started_at,
            e.scheduled_for
          ),
        p95:
          fragment(
            "percentile_cont(0.95) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (? - ?)) * 1000)",
            e.started_at,
            e.scheduled_for
          ),
        p99:
          fragment(
            "percentile_cont(0.99) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (? - ?)) * 1000)",
            e.started_at,
            e.scheduled_for
          ),
        avg: avg(fragment("EXTRACT(EPOCH FROM (? - ?)) * 1000", e.started_at, e.scheduled_for)),
        max: max(fragment("EXTRACT(EPOCH FROM (? - ?)) * 1000", e.started_at, e.scheduled_for)),
        count: count(e.id)
      }
    )
    |> Repo.one()
    |> then(fn result ->
      %{
        p50: round_or_zero(result.p50),
        p95: round_or_zero(result.p95),
        p99: round_or_zero(result.p99),
        avg: round_or_zero(result.avg),
        max: round_or_zero(result.max),
        count: result.count
      }
    end)
  end

  @doc """
  Returns daily scheduling precision for the last N days.
  Reads from the scheduling_precision_daily table (persisted aggregates)
  and supplements with live data from executions for recent days still in retention.
  """
  def get_daily_scheduling_precision(days \\ 90) do
    alias Prikke.Executions.SchedulingPrecisionDaily

    since = Date.utc_today() |> Date.add(-days)

    # Read stored daily aggregates
    stored =
      from(s in SchedulingPrecisionDaily,
        where: s.date >= ^since,
        order_by: [asc: s.date]
      )
      |> Repo.all()
      |> Map.new(fn row ->
        {row.date,
         %{
           date: row.date,
           p50: row.p50_ms,
           p95: row.p95_ms,
           p99: row.p99_ms,
           avg:
             if(row.request_count > 0, do: div(row.total_delay_ms, row.request_count), else: 0),
           max: row.max_ms,
           count: row.request_count
         }}
      end)

    # Compute today's data live from executions (not yet aggregated)
    today = Date.utc_today()
    live = compute_daily_precision_from_executions(today)
    live_by_date = Map.new(live, fn entry -> {entry.date, entry} end)

    # Merge: stored for historical, live for today
    merged = Map.merge(stored, live_by_date)

    merged
    |> Map.values()
    |> Enum.sort_by(& &1.date, Date)
  end

  @doc """
  Aggregates scheduling precision from executions for a date range and stores
  in scheduling_precision_daily. Called by cleanup before deleting old executions.
  """
  def aggregate_scheduling_precision(since_date, until_date \\ nil) do
    alias Prikke.Executions.SchedulingPrecisionDaily

    until_date = until_date || Date.utc_today()
    since = DateTime.new!(since_date, ~T[00:00:00], "Etc/UTC")
    until_dt = DateTime.new!(Date.add(until_date, 1), ~T[00:00:00], "Etc/UTC")

    results =
      from(e in Execution,
        where: is_nil(e.queue),
        where: e.status in ["success", "failed", "timeout"],
        where: e.scheduled_for >= ^since,
        where: e.scheduled_for < ^until_dt,
        where: not is_nil(e.started_at),
        where: not is_nil(e.scheduled_for),
        group_by: fragment("DATE(?)", e.scheduled_for),
        select: {
          fragment("DATE(?)", e.scheduled_for),
          %{
            p50:
              fragment(
                "percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (? - ?)) * 1000)",
                e.started_at,
                e.scheduled_for
              ),
            p95:
              fragment(
                "percentile_cont(0.95) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (? - ?)) * 1000)",
                e.started_at,
                e.scheduled_for
              ),
            p99:
              fragment(
                "percentile_cont(0.99) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (? - ?)) * 1000)",
                e.started_at,
                e.scheduled_for
              ),
            avg:
              avg(fragment("EXTRACT(EPOCH FROM (? - ?)) * 1000", e.started_at, e.scheduled_for)),
            max:
              max(fragment("EXTRACT(EPOCH FROM (? - ?)) * 1000", e.started_at, e.scheduled_for)),
            count: count(e.id)
          }
        }
      )
      |> Repo.all()

    now = DateTime.utc_now(:second)

    for {date, stats} <- results do
      Repo.query!(
        """
        INSERT INTO scheduling_precision_daily (id, date, request_count, total_delay_ms, p50_ms, p95_ms, p99_ms, max_ms, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
        ON CONFLICT (date) DO UPDATE SET
          request_count = EXCLUDED.request_count,
          total_delay_ms = EXCLUDED.total_delay_ms,
          p50_ms = EXCLUDED.p50_ms,
          p95_ms = EXCLUDED.p95_ms,
          p99_ms = EXCLUDED.p99_ms,
          max_ms = EXCLUDED.max_ms,
          updated_at = EXCLUDED.updated_at
        """,
        [
          Ecto.UUID.bingenerate(),
          date,
          stats.count,
          round_or_zero(stats.avg) * stats.count,
          round_or_zero(stats.p50),
          round_or_zero(stats.p95),
          round_or_zero(stats.p99),
          round_or_zero(stats.max),
          now,
          now
        ]
      )
    end

    length(results)
  end

  defp compute_daily_precision_from_executions(since_date) do
    since = DateTime.new!(since_date, ~T[00:00:00], "Etc/UTC")

    from(e in Execution,
      where: is_nil(e.queue),
      where: e.status in ["success", "failed", "timeout"],
      where: e.scheduled_for >= ^since,
      where: not is_nil(e.started_at),
      where: not is_nil(e.scheduled_for),
      group_by: fragment("DATE(?)", e.scheduled_for),
      order_by: [asc: fragment("DATE(?)", e.scheduled_for)],
      select: {
        fragment("DATE(?)", e.scheduled_for),
        %{
          p50:
            fragment(
              "percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (? - ?)) * 1000)",
              e.started_at,
              e.scheduled_for
            ),
          p95:
            fragment(
              "percentile_cont(0.95) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (? - ?)) * 1000)",
              e.started_at,
              e.scheduled_for
            ),
          p99:
            fragment(
              "percentile_cont(0.99) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (? - ?)) * 1000)",
              e.started_at,
              e.scheduled_for
            ),
          avg: avg(fragment("EXTRACT(EPOCH FROM (? - ?)) * 1000", e.started_at, e.scheduled_for)),
          max: max(fragment("EXTRACT(EPOCH FROM (? - ?)) * 1000", e.started_at, e.scheduled_for)),
          count: count(e.id)
        }
      }
    )
    |> Repo.all()
    |> Enum.map(fn {date, stats} ->
      %{
        date: date,
        p50: round_or_zero(stats.p50),
        p95: round_or_zero(stats.p95),
        p99: round_or_zero(stats.p99),
        avg: round_or_zero(stats.avg),
        max: round_or_zero(stats.max),
        count: stats.count
      }
    end)
  end

  defp round_or_zero(nil), do: 0
  defp round_or_zero(%Decimal{} = d), do: Decimal.to_float(d) |> round()
  defp round_or_zero(f) when is_float(f), do: round(f)
  defp round_or_zero(i), do: i

  def throughput_per_minute(minutes \\ 60) do
    since = DateTime.add(DateTime.utc_now(), -minutes, :minute)

    from(e in Execution,
      where: e.finished_at >= ^since,
      where: e.status in ["success", "failed", "timeout"],
      group_by: fragment("date_trunc('minute', ?)", e.finished_at),
      order_by: [asc: fragment("date_trunc('minute', ?)", e.finished_at)],
      select: {fragment("date_trunc('minute', ?)", e.finished_at), count(e.id)}
    )
    |> Repo.all()
  end

  def get_platform_stats do
    now = DateTime.utc_now()
    today = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
    seven_days_ago = DateTime.add(now, -7, :day)
    thirty_days_ago = DateTime.add(now, -30, :day)
    start_of_month = Date.new!(now.year, now.month, 1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    %{
      today: get_platform_stats_since(today),
      seven_days: get_platform_stats_since(seven_days_ago),
      thirty_days: get_platform_stats_since(thirty_days_ago),
      this_month: get_platform_stats_since(start_of_month)
    }
  end

  defp get_platform_stats_since(since) do
    from(e in Execution,
      where: e.scheduled_for >= ^since,
      select: %{
        total: count(),
        success: count(fragment("CASE WHEN ? = 'success' THEN 1 END", e.status)),
        failed: count(fragment("CASE WHEN ? = 'failed' THEN 1 END", e.status)),
        timeout: count(fragment("CASE WHEN ? = 'timeout' THEN 1 END", e.status)),
        pending: count(fragment("CASE WHEN ? = 'pending' THEN 1 END", e.status)),
        running: count(fragment("CASE WHEN ? = 'running' THEN 1 END", e.status)),
        missed: count(fragment("CASE WHEN ? = 'missed' THEN 1 END", e.status))
      }
    )
    |> Repo.one()
  end

  @doc """
  Returns daily execution status for a task over the given number of days.
  Each day is classified as "success" (all passed), "failed" (any failed/timeout),
  or "none" (no executions).
  """
  def get_daily_status_for_task(task, days \\ 30) do
    since = DateTime.utc_now() |> DateTime.add(-days, :day)
    today = Date.utc_today()

    data =
      from(e in Execution,
        where: e.task_id == ^task.id and e.scheduled_for >= ^since,
        group_by: fragment("DATE(?)", e.scheduled_for),
        select: {
          fragment("DATE(?)", e.scheduled_for),
          %{
            total: count(),
            success: count(fragment("CASE WHEN ? = 'success' THEN 1 END", e.status)),
            failed: count(fragment("CASE WHEN ? IN ('failed', 'timeout') THEN 1 END", e.status))
          }
        }
      )
      |> Repo.all()
      |> Map.new()

    Enum.map(0..(days - 1), fn offset ->
      date = Date.add(today, -days + 1 + offset)
      stats = Map.get(data, date, %{total: 0, success: 0, failed: 0})

      status =
        cond do
          stats.total == 0 -> "none"
          stats.failed > 0 -> "failed"
          true -> "success"
        end

      {date, %{status: status, total: stats.total, success: stats.success, failed: stats.failed}}
    end)
  end

  @doc """
  Returns the uptime percentage for a task over the given number of days.
  Calculated as successful executions / total completed executions.
  Returns nil if there are no executions.
  """
  def task_uptime_percentage(task, days \\ 30) do
    since = DateTime.utc_now() |> DateTime.add(-days, :day)

    stats =
      from(e in Execution,
        where: e.task_id == ^task.id and e.scheduled_for >= ^since,
        where: e.status in ["success", "failed", "timeout"],
        select: %{
          total: count(),
          success: count(fragment("CASE WHEN ? = 'success' THEN 1 END", e.status))
        }
      )
      |> Repo.one()

    case stats do
      %{total: 0} -> nil
      %{total: total, success: success} -> Float.round(success / total * 100, 2)
    end
  end

  @doc """
  Returns daily execution status for all tasks in a queue over the given number of days.
  Filters by organization_id and queue name.
  """
  def get_daily_status_for_queue(organization_id, queue_name, days \\ 30) do
    since = DateTime.utc_now() |> DateTime.add(-days, :day)
    today = Date.utc_today()

    data =
      from(e in Execution,
        where:
          e.organization_id == ^organization_id and
            e.queue == ^queue_name and
            e.scheduled_for >= ^since,
        group_by: fragment("DATE(?)", e.scheduled_for),
        select: {
          fragment("DATE(?)", e.scheduled_for),
          %{
            total: count(),
            success: count(fragment("CASE WHEN ? = 'success' THEN 1 END", e.status)),
            failed: count(fragment("CASE WHEN ? IN ('failed', 'timeout') THEN 1 END", e.status))
          }
        }
      )
      |> Repo.all()
      |> Map.new()

    Enum.map(0..(days - 1), fn offset ->
      date = Date.add(today, -days + 1 + offset)
      stats = Map.get(data, date, %{total: 0, success: 0, failed: 0})

      status =
        cond do
          stats.total == 0 -> "none"
          stats.failed > 0 -> "failed"
          true -> "success"
        end

      {date, %{status: status, total: stats.total, success: stats.success, failed: stats.failed}}
    end)
  end

  @doc """
  Returns the uptime percentage for a queue over the given number of days.
  Calculated as successful executions / total completed executions.
  Returns nil if there are no executions.
  """
  def queue_uptime_percentage(organization_id, queue_name, days \\ 30) do
    since = DateTime.utc_now() |> DateTime.add(-days, :day)

    stats =
      from(e in Execution,
        where:
          e.organization_id == ^organization_id and
            e.queue == ^queue_name and
            e.scheduled_for >= ^since,
        where: e.status in ["success", "failed", "timeout"],
        select: %{
          total: count(),
          success: count(fragment("CASE WHEN ? = 'success' THEN 1 END", e.status))
        }
      )
      |> Repo.one()

    case stats do
      %{total: 0} -> nil
      %{total: total, success: success} -> Float.round(success / total * 100, 2)
    end
  end

  @doc """
  Returns the last execution status for a queue.
  """
  def get_last_queue_status(organization_id, queue_name) do
    from(e in Execution,
      where:
        e.organization_id == ^organization_id and
          e.queue == ^queue_name and
          e.status in ["success", "failed", "timeout"],
      order_by: [desc: e.scheduled_for],
      limit: 1,
      select: e.status
    )
    |> Repo.one()
  end

  def executions_by_day_for_org(organization, days \\ 14) do
    since = DateTime.utc_now() |> DateTime.add(-days, :day)
    today = Date.utc_today()

    data =
      from(e in Execution,
        where: e.organization_id == ^organization.id and e.scheduled_for >= ^since,
        group_by: fragment("DATE(?)", e.scheduled_for),
        select: {
          fragment("DATE(?)", e.scheduled_for),
          %{
            total: count(),
            success: count(fragment("CASE WHEN ? = 'success' THEN 1 END", e.status)),
            failed: count(fragment("CASE WHEN ? = 'failed' THEN 1 END", e.status))
          }
        }
      )
      |> Repo.all()
      |> Map.new()

    Enum.map(0..(days - 1), fn offset ->
      date = Date.add(today, -days + 1 + offset)
      stats = Map.get(data, date, %{total: 0, success: 0, failed: 0})
      {date, stats}
    end)
  end

  def executions_by_day(days) do
    since = DateTime.utc_now() |> DateTime.add(-days, :day)
    today = Date.utc_today()

    data =
      from(e in Execution,
        where: e.scheduled_for >= ^since,
        group_by: fragment("DATE(?)", e.scheduled_for),
        select: {
          fragment("DATE(?)", e.scheduled_for),
          %{
            total: count(),
            success: count(fragment("CASE WHEN ? = 'success' THEN 1 END", e.status)),
            failed: count(fragment("CASE WHEN ? = 'failed' THEN 1 END", e.status))
          }
        }
      )
      |> Repo.all()
      |> Map.new()

    Enum.map(0..(days - 1), fn offset ->
      date = Date.add(today, -days + 1 + offset)
      stats = Map.get(data, date, %{total: 0, success: 0, failed: 0})
      {date, stats}
    end)
  end

  def list_pending_retries(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(e in Execution,
      where: e.status == "pending" and e.attempt > 1,
      order_by: [asc: e.scheduled_for],
      limit: ^limit,
      preload: [task: :organization]
    )
    |> Repo.all()
  end

  def list_recent_executions_all(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    from(e in Execution,
      order_by: [desc: e.scheduled_for],
      limit: ^limit,
      preload: [task: :organization]
    )
    |> Repo.all()
  end

  def get_platform_success_rate(since) do
    stats = get_platform_stats_since(since)
    completed = stats.success + stats.failed + stats.timeout

    if completed > 0 do
      round(stats.success / completed * 100)
    else
      nil
    end
  end

  def list_organization_monthly_executions(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    tier_limits = Prikke.Tasks.tier_limits()

    from(o in Organization,
      where: o.monthly_execution_count > 0,
      order_by: [desc: o.monthly_execution_count],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.map(fn org ->
      tier_limit = tier_limits[org.tier][:max_monthly_executions] || 10_000
      {org, org.monthly_execution_count, tier_limit}
    end)
  end

  # Dynamic filter: execution is claimable if it has no queue, or its queue
  # is not blocked. Uses NOT IN with the partial index for a fast lookup.
  defp claimable_queue_filter(_now) do
    dynamic(
      [e],
      is_nil(e.queue) or e.queue == "" or
        fragment(
          "(?, ?) NOT IN (SELECT organization_id, queue FROM executions WHERE queue IS NOT NULL AND queue != '' AND status = 'running')",
          e.organization_id,
          e.queue
        )
    )
  end

  # Dynamic filter: skip executions whose (org, queue) is paused in the queues table.
  # Allows nil/empty queues through (they can't be paused).
  defp paused_queue_filter do
    dynamic(
      [e],
      is_nil(e.queue) or e.queue == "" or
        fragment(
          "(?, ?) NOT IN (SELECT organization_id, name FROM queues WHERE paused = true)",
          e.organization_id,
          e.queue
        )
    )
  end

  # Dynamic filter: skip orgs that already have their tier's max concurrent running.
  # Subquery scans only running executions (tiny set, max ~20 rows) via partial index.
  # JOINs organizations to check tier — still fast since only running rows are scanned.
  defp org_fairness_filter do
    max = @max_concurrent_per_org

    dynamic(
      [e],
      fragment(
        "? NOT IN (SELECT organization_id FROM executions WHERE status = 'running' GROUP BY organization_id HAVING count(*) >= ?)",
        e.organization_id,
        ^max
      )
    )
  end

  ## Failed events dashboard queries

  @doc """
  Lists failed and timed-out executions for an organization.

  Options:
    * `:limit` - max results (default 50)
    * `:offset` - pagination offset (default 0)
    * `:queue` - filter by queue name
  """
  def list_failed_executions(%Organization{} = org, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    queue = Keyword.get(opts, :queue)

    query =
      from(e in Execution,
        where: e.organization_id == ^org.id,
        where: e.status in ["failed", "timeout"],
        order_by: [desc: e.scheduled_for],
        limit: ^limit,
        offset: ^offset,
        preload: [:task]
      )

    query =
      if queue && queue != "" do
        from(e in query, where: e.queue == ^queue)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Counts failed and timed-out executions for an organization.
  """
  def count_failed_executions(%Organization{} = org, opts \\ []) do
    queue = Keyword.get(opts, :queue)

    query =
      from(e in Execution,
        where: e.organization_id == ^org.id,
        where: e.status in ["failed", "timeout"]
      )

    query =
      if queue && queue != "" do
        from(e in query, where: e.queue == ^queue)
      else
        query
      end

    Repo.aggregate(query, :count)
  end

  @doc """
  Creates a new pending execution to retry a failed one.
  Reuses the same task, scheduling for immediate execution.
  """
  def retry_execution(%Execution{} = execution) do
    execution = Repo.preload(execution, :task)

    if is_nil(execution.task) do
      {:error, :task_not_found}
    else
      create_execution_for_task(
        execution.task,
        DateTime.utc_now() |> DateTime.truncate(:second),
        attempt: 1
      )
    end
  end

  @doc """
  Retries multiple failed executions at once.
  Returns `{:ok, count}` with the number of retries created.
  """
  def bulk_retry_executions(%Organization{} = org, execution_ids) when is_list(execution_ids) do
    executions =
      from(e in Execution,
        where: e.organization_id == ^org.id,
        where: e.id in ^execution_ids,
        where: e.status in ["failed", "timeout"],
        preload: [:task]
      )
      |> Repo.all()

    results =
      Enum.map(executions, fn execution ->
        if execution.task do
          create_execution_for_task(
            execution.task,
            DateTime.utc_now() |> DateTime.truncate(:second),
            attempt: 1
          )
        else
          {:error, :task_not_found}
        end
      end)

    created = Enum.count(results, &match?({:ok, _}, &1))
    {:ok, created}
  end
end
