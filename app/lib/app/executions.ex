defmodule Prikke.Executions do
  @moduledoc """
  The Executions context.
  Handles job execution history and worker coordination.
  """

  import Ecto.Query, warn: false
  alias Prikke.Repo
  alias Prikke.Executions.Execution
  alias Prikke.Jobs.Job

  @doc """
  Subscribes to execution updates for a specific job.
  Receives {:execution_updated, execution} messages.
  """
  def subscribe_job_executions(job_id) do
    Phoenix.PubSub.subscribe(Prikke.PubSub, "job:#{job_id}:executions")
  end

  @doc """
  Subscribes to execution updates for all jobs in an organization.
  Receives {:execution_updated, execution} messages.
  """
  def subscribe_organization_executions(org_id) do
    Phoenix.PubSub.subscribe(Prikke.PubSub, "org:#{org_id}:executions")
  end

  @doc """
  Broadcasts an execution update to subscribers.
  Broadcasts to both the job-specific and organization-wide topics.
  """
  def broadcast_execution_update(execution) do
    # Broadcast to job-specific topic
    Phoenix.PubSub.broadcast(
      Prikke.PubSub,
      "job:#{execution.job_id}:executions",
      {:execution_updated, execution}
    )

    # Also broadcast to organization topic (need to load job for org_id)
    execution_with_job = get_execution_with_job(execution.id)

    if execution_with_job && execution_with_job.job do
      Phoenix.PubSub.broadcast(
        Prikke.PubSub,
        "org:#{execution_with_job.job.organization_id}:executions",
        {:execution_updated, execution_with_job}
      )
    end
  end

  @doc """
  Creates a pending execution for a job.
  Used by the scheduler when a job is due.
  """
  def create_execution(attrs) do
    %Execution{}
    |> Execution.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a pending execution for a job struct.
  """
  def create_execution_for_job(%Job{} = job, scheduled_for, attempt \\ 1) do
    create_execution(%{
      job_id: job.id,
      scheduled_for: scheduled_for,
      attempt: attempt
    })
  end

  @doc """
  Creates a missed execution for a job.
  Used when the scheduler was unavailable at the scheduled time.
  """
  def create_missed_execution(%Job{} = job, scheduled_for) do
    %Execution{}
    |> Execution.missed_changeset(%{
      job_id: job.id,
      scheduled_for: scheduled_for
    })
    |> Repo.insert()
  end

  @doc """
  Gets a single execution.
  """
  def get_execution(id), do: Repo.get(Execution, id)

  @doc """
  Gets a single execution with preloaded job.
  """
  def get_execution_with_job(id) do
    Execution
    |> Repo.get(id)
    |> Repo.preload(job: :organization)
  end

  @doc """
  Gets an execution by ID, scoped to an organization.
  Returns nil if not found or not belonging to the organization.
  """
  def get_execution_for_org(organization, execution_id) do
    from(e in Execution,
      join: j in Job,
      on: e.job_id == j.id,
      where: j.organization_id == ^organization.id and e.id == ^execution_id,
      preload: [job: j]
    )
    |> Repo.one()
  end

  @doc """
  Gets an execution by ID, scoped to a specific job.
  Returns nil if not found or not belonging to the job.
  """
  def get_execution_for_job(job, execution_id) do
    from(e in Execution,
      where: e.job_id == ^job.id and e.id == ^execution_id
    )
    |> Repo.one()
  end

  @doc """
  Claims the next pending execution for processing.
  Uses FOR UPDATE SKIP LOCKED to allow concurrent workers.
  Returns {:ok, execution} or {:ok, nil} if no work available.

  Priority order:
  1. Pro tier before Free tier
  2. Minute-interval crons before hourly/daily (more time-sensitive)
  3. One-time jobs last (interval_minutes is NULL, sorts last in ASC)
  4. Oldest scheduled_for first within same priority
  """
  def claim_next_execution do
    now = DateTime.utc_now()

    query =
      from(e in Execution,
        join: j in Job,
        on: e.job_id == j.id,
        join: o in Prikke.Accounts.Organization,
        on: j.organization_id == o.id,
        where: e.status == "pending" and e.scheduled_for <= ^now,
        order_by: [
          # Pro customers first
          desc: o.tier,
          # Minute crons first, one-time jobs last (NULL)
          asc: j.interval_minutes,
          # Oldest first within same priority
          asc: e.scheduled_for
        ],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"
      )

    # Wrap in transaction to hold the FOR UPDATE lock until status is updated
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

  @doc """
  Marks an execution as successfully completed.
  """
  def complete_execution(execution, attrs \\ %{}) do
    result =
      execution
      |> Execution.complete_changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated} -> broadcast_execution_update(updated)
      _ -> :ok
    end

    result
  end

  @doc """
  Marks an execution as failed.
  """
  def fail_execution(execution, attrs \\ %{}) do
    result =
      execution
      |> Execution.fail_changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated} -> broadcast_execution_update(updated)
      _ -> :ok
    end

    result
  end

  @doc """
  Marks an execution as timed out.
  """
  def timeout_execution(execution, duration_ms \\ nil) do
    result =
      execution
      |> Execution.timeout_changeset(duration_ms)
      |> Repo.update()

    case result do
      {:ok, updated} -> broadcast_execution_update(updated)
      _ -> :ok
    end

    result
  end

  @doc """
  Lists executions for a job, ordered by most recent first.
  """
  def list_job_executions(job, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(e in Execution,
      where: e.job_id == ^job.id,
      order_by: [desc: e.scheduled_for],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Gets the latest execution status for a job.
  Returns the status string or nil if no executions exist.
  """
  def get_latest_status(job) do
    from(e in Execution,
      where: e.job_id == ^job.id,
      order_by: [desc: e.scheduled_for],
      limit: 1,
      select: e.status
    )
    |> Repo.one()
  end

  @doc """
  Gets the previous execution status for a job, excluding the given execution.
  Returns the status string or nil if no previous execution exists.
  Used to detect status changes for notifications.
  """
  def get_previous_status(job, current_execution_id) do
    from(e in Execution,
      where: e.job_id == ^job.id and e.id != ^current_execution_id,
      order_by: [desc: e.scheduled_for],
      limit: 1,
      select: e.status
    )
    |> Repo.one()
  end

  @doc """
  Gets the latest execution info for multiple jobs.
  Returns a map of job_id => %{status: status, attempt: attempt} (or nil if no executions).
  """
  def get_latest_statuses([]), do: %{}

  def get_latest_statuses(job_ids) when is_list(job_ids) do
    # Subquery to get max scheduled_for per job
    latest_times =
      from(e in Execution,
        where: e.job_id in ^job_ids,
        group_by: e.job_id,
        select: %{job_id: e.job_id, max_scheduled: max(e.scheduled_for)}
      )

    # Join to get the status and attempt for each latest execution
    from(e in Execution,
      join: lt in subquery(latest_times),
      on: e.job_id == lt.job_id and e.scheduled_for == lt.max_scheduled,
      select: {e.job_id, %{status: e.status, attempt: e.attempt}}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Lists recent executions for an organization.
  """
  def list_organization_executions(organization, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(e in Execution,
      join: j in Job,
      on: e.job_id == j.id,
      where: j.organization_id == ^organization.id,
      order_by: [desc: e.scheduled_for],
      limit: ^limit,
      preload: [:job]
    )
    |> Repo.all()
  end

  @doc """
  Counts pending executions (queue depth).
  Used by the worker pool manager to scale workers.
  """
  def count_pending_executions do
    from(e in Execution, where: e.status == "pending")
    |> Repo.aggregate(:count)
  end

  @doc """
  Gets execution stats for a job.
  Returns a map with total count, success count, fail count, etc.
  """
  def get_job_stats(job, opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -24, :hour))

    query =
      from(e in Execution,
        where: e.job_id == ^job.id and e.scheduled_for >= ^since,
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

    Repo.one(query)
  end

  @doc """
  Gets execution stats for an organization.
  """
  def get_organization_stats(organization, opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -24, :hour))

    query =
      from(e in Execution,
        join: j in Job,
        on: e.job_id == j.id,
        where: j.organization_id == ^organization.id and e.scheduled_for >= ^since,
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

    Repo.one(query)
  end

  @doc """
  Counts executions for an organization in a given month.
  Used for enforcing monthly execution limits.

  NOTE: Currently uses a COUNT query which is fine for MVP scale.
  Future optimization: cache in ETS with 5-minute TTL, invalidate on completion.
  """
  def count_monthly_executions(organization, year, month) do
    start_of_month = Date.new!(year, month, 1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    # Calculate first day of next month
    {next_year, next_month} = if month == 12, do: {year + 1, 1}, else: {year, month + 1}
    end_of_month = Date.new!(next_year, next_month, 1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    # Only count initial attempts (attempt == 1), retries are free
    from(e in Execution,
      join: j in Job,
      on: e.job_id == j.id,
      where: j.organization_id == ^organization.id,
      where: e.scheduled_for >= ^start_of_month and e.scheduled_for < ^end_of_month,
      where: e.status in ["success", "failed", "timeout"],
      where: e.attempt == 1
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Counts executions for an organization in the current month.
  """
  def count_current_month_executions(organization) do
    now = DateTime.utc_now()
    count_monthly_executions(organization, now.year, now.month)
  end

  @doc """
  Gets execution stats for an organization for today (since midnight UTC).
  """
  def get_today_stats(organization) do
    today = DateTime.utc_now() |> DateTime.to_date()
    since = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")
    get_organization_stats(organization, since: since)
  end

  @doc """
  Deletes old executions based on tier retention policy.
  Free: 7 days, Pro: 30 days
  """
  def cleanup_old_executions(organization, retention_days) do
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days, :day)

    from(e in Execution,
      join: j in Job,
      on: e.job_id == j.id,
      where: j.organization_id == ^organization.id,
      where: e.finished_at < ^cutoff
    )
    |> Repo.delete_all()
  end

  @doc """
  Recovers stale executions stuck in "running" status.

  An execution is considered stale if it's been in "running" status for longer
  than its job's timeout plus a buffer (default 5 minutes). This can happen if
  a worker crashes or the server restarts during execution.

  Returns the count of recovered executions.
  """
  def recover_stale_executions(stale_threshold_minutes \\ 5) do
    # Find executions stuck in "running" for too long
    # Use a conservative threshold: job timeout + buffer
    cutoff = DateTime.add(DateTime.utc_now(), -stale_threshold_minutes, :minute)

    stale_executions =
      from(e in Execution,
        join: j in Job,
        on: e.job_id == j.id,
        where: e.status == "running" and e.started_at < ^cutoff,
        preload: [job: j]
      )
      |> Repo.all()

    Enum.each(stale_executions, fn execution ->
      # Mark as failed due to worker crash/restart
      execution
      |> Execution.fail_changeset(%{
        error_message: "Execution interrupted (worker restart or crash)"
      })
      |> Repo.update()
    end)

    length(stale_executions)
  end

  ## Platform-wide Stats (for superadmin)

  @doc """
  Gets platform-wide execution stats for the superadmin dashboard.
  """
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

  @doc """
  Gets execution counts by day for the last N days (platform-wide).
  Returns all days, including days with zero executions.
  """
  def executions_by_day(days) do
    since = DateTime.utc_now() |> DateTime.add(-days, :day)
    today = Date.utc_today()

    # Query actual execution data
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

    # Fill in all days with zeros for missing days
    Enum.map(0..(days - 1), fn offset ->
      date = Date.add(today, -days + 1 + offset)
      stats = Map.get(data, date, %{total: 0, success: 0, failed: 0})
      {date, stats}
    end)
  end

  @doc """
  Lists recent executions across all organizations.
  """
  def list_recent_executions_all(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    from(e in Execution,
      order_by: [desc: e.scheduled_for],
      limit: ^limit,
      preload: [job: :organization]
    )
    |> Repo.all()
  end

  @doc """
  Gets overall success rate for the platform.
  """
  def get_platform_success_rate(since) do
    stats = get_platform_stats_since(since)
    completed = stats.success + stats.failed + stats.timeout

    if completed > 0 do
      round(stats.success / completed * 100)
    else
      nil
    end
  end

  @doc """
  Gets monthly execution counts per organization.
  Returns a list of {organization, execution_count, tier_limit} tuples sorted by execution count desc.
  """
  def list_organization_monthly_executions(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    now = DateTime.utc_now()
    start_of_month = Date.new!(now.year, now.month, 1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    tier_limits = Prikke.Jobs.tier_limits()

    from(e in Execution,
      join: j in Job,
      on: e.job_id == j.id,
      join: o in Prikke.Accounts.Organization,
      on: j.organization_id == o.id,
      where: e.scheduled_for >= ^start_of_month,
      where: e.status in ["success", "failed", "timeout"],
      where: e.attempt == 1,
      group_by: [o.id, o.name, o.tier],
      select: {o, count(e.id)},
      order_by: [desc: count(e.id)],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.map(fn {org, count} ->
      tier_limit = tier_limits[org.tier][:max_monthly_executions] || 5_000
      {org, count, tier_limit}
    end)
  end
end
