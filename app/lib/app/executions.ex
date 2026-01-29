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
      from e in Execution,
        join: j in Job, on: e.job_id == j.id,
        join: o in Prikke.Accounts.Organization, on: j.organization_id == o.id,
        where: e.status == "pending" and e.scheduled_for <= ^now,
        order_by: [
          desc: o.tier,                    # Pro customers first
          asc: j.interval_minutes,         # Minute crons first, one-time jobs last (NULL)
          asc: e.scheduled_for             # Oldest first within same priority
        ],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"

    case Repo.one(query) do
      nil ->
        {:ok, nil}

      execution ->
        execution
        |> Execution.start_changeset()
        |> Repo.update()
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
  def timeout_execution(execution) do
    execution
    |> Execution.timeout_changeset()
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
  Lists recent executions for an organization.
  """
  def list_organization_executions(organization, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(e in Execution,
      join: j in Job, on: e.job_id == j.id,
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
      from e in Execution,
        where: e.job_id == ^job.id and e.scheduled_for >= ^since,
        select: %{
          total: count(e.id),
          success: count(fragment("CASE WHEN ? = 'success' THEN 1 END", e.status)),
          failed: count(fragment("CASE WHEN ? = 'failed' THEN 1 END", e.status)),
          timeout: count(fragment("CASE WHEN ? = 'timeout' THEN 1 END", e.status)),
          pending: count(fragment("CASE WHEN ? = 'pending' THEN 1 END", e.status)),
          running: count(fragment("CASE WHEN ? = 'running' THEN 1 END", e.status)),
          avg_duration_ms: avg(e.duration_ms)
        }

    Repo.one(query)
  end

  @doc """
  Gets execution stats for an organization.
  """
  def get_organization_stats(organization, opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -24, :hour))

    query =
      from e in Execution,
        join: j in Job, on: e.job_id == j.id,
        where: j.organization_id == ^organization.id and e.scheduled_for >= ^since,
        select: %{
          total: count(e.id),
          success: count(fragment("CASE WHEN ? = 'success' THEN 1 END", e.status)),
          failed: count(fragment("CASE WHEN ? = 'failed' THEN 1 END", e.status)),
          timeout: count(fragment("CASE WHEN ? = 'timeout' THEN 1 END", e.status)),
          pending: count(fragment("CASE WHEN ? = 'pending' THEN 1 END", e.status)),
          running: count(fragment("CASE WHEN ? = 'running' THEN 1 END", e.status)),
          avg_duration_ms: avg(e.duration_ms)
        }

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
      join: j in Job, on: e.job_id == j.id,
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
  Deletes old executions based on tier retention policy.
  Free: 7 days, Pro: 30 days
  """
  def cleanup_old_executions(organization, retention_days) do
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days, :day)

    from(e in Execution,
      join: j in Job, on: e.job_id == j.id,
      where: j.organization_id == ^organization.id,
      where: e.finished_at < ^cutoff
    )
    |> Repo.delete_all()
  end
end
