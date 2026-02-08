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

    execution_with_task = get_execution_with_task(execution.id)

    if execution_with_task && execution_with_task.task do
      Phoenix.PubSub.broadcast(
        Prikke.PubSub,
        "org:#{execution_with_task.task.organization_id}:executions",
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
      scheduled_for: scheduled_for,
      attempt: attempt
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
      join: t in Task,
      on: e.task_id == t.id,
      where: t.organization_id == ^organization.id and e.id == ^execution_id,
      preload: [task: t]
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

    query =
      from(e in Execution,
        join: t in Task,
        on: e.task_id == t.id,
        join: o in Prikke.Accounts.Organization,
        on: t.organization_id == o.id,
        where: e.status == "pending" and e.scheduled_for <= ^now,
        where:
          is_nil(t.queue) or
            fragment(
              """
              NOT EXISTS (
                SELECT 1 FROM executions e2
                JOIN tasks t2 ON e2.task_id = t2.id
                WHERE t2.organization_id = ? AND t2.queue = ?
                  AND e2.id != ?
                  AND (e2.status = 'running' OR (e2.status = 'pending' AND e2.scheduled_for > ?))
              )
              """,
              t.organization_id,
              t.queue,
              e.id,
              ^now
            ),
        order_by: [
          desc: o.tier,
          asc: t.interval_minutes,
          asc: e.scheduled_for
        ],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"
      )

    Repo.transaction(fn ->
      case Repo.one(query) do
        nil ->
          nil

        execution ->
          case execution |> Execution.start_changeset() |> Repo.update() do
            {:ok, updated} -> updated
            {:error, _} -> Repo.rollback(:update_failed)
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
      join: t in Task,
      on: e.task_id == t.id,
      where: t.organization_id == ^organization.id,
      order_by: [desc: e.scheduled_for],
      limit: ^limit,
      preload: [:task]
    )
    |> Repo.all()
  end

  def count_pending_executions do
    from(e in Execution, where: e.status == "pending")
    |> Repo.aggregate(:count)
  end

  def get_task_stats(task, opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -24, :hour))

    from(e in Execution,
      where: e.task_id == ^task.id and e.scheduled_for >= ^since,
      select: %{
        total: count(e.id),
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
      join: t in Task,
      on: e.task_id == t.id,
      where: t.organization_id == ^organization.id and e.scheduled_for >= ^since,
      select: %{
        total: count(e.id),
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

  defp maybe_increment_monthly_count(%Execution{attempt: 1} = execution) do
    execution = Repo.preload(execution, task: :organization)
    increment_monthly_execution_count(execution.task.organization_id)
  end

  defp maybe_increment_monthly_count(_execution), do: :ok

  def get_today_stats(organization) do
    today = DateTime.utc_now() |> DateTime.to_date()
    since = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")
    get_organization_stats(organization, since: since)
  end

  def cleanup_old_executions(organization, retention_days) do
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days, :day)

    from(e in Execution,
      join: t in Task,
      on: e.task_id == t.id,
      where: t.organization_id == ^organization.id,
      where: e.finished_at < ^cutoff
    )
    |> Repo.delete_all()
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
        total: count(e.id),
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

  def executions_by_day_for_org(organization, days \\ 14) do
    since = DateTime.utc_now() |> DateTime.add(-days, :day)
    today = Date.utc_today()

    data =
      from(e in Execution,
        join: t in Task,
        on: e.task_id == t.id,
        where: t.organization_id == ^organization.id and e.scheduled_for >= ^since,
        group_by: fragment("DATE(?)", e.scheduled_for),
        select: {
          fragment("DATE(?)", e.scheduled_for),
          %{
            total: count(e.id),
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
            total: count(e.id),
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
      tier_limit = tier_limits[org.tier][:max_monthly_executions] || 5_000
      {org, org.monthly_execution_count, tier_limit}
    end)
  end
end
