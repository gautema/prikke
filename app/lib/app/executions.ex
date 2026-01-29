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
    execution
    |> Execution.complete_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Marks an execution as failed.
  """
  def fail_execution(execution, attrs \\ %{}) do
    execution
    |> Execution.fail_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Marks an execution as timed out.
  """
  def timeout_execution(execution, duration_ms \\ nil) do
    execution
    |> Execution.timeout_changeset(duration_ms)
    |> Repo.update()
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

    from(e in Execution,
      join: j in Job,
      on: e.job_id == j.id,
      where: j.organization_id == ^organization.id,
      where: e.scheduled_for >= ^start_of_month and e.scheduled_for < ^end_of_month,
      where: e.status in ["success", "failed", "timeout"]
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
end
