defmodule Prikke.Jobs do
  @moduledoc """
  The Jobs context.
  """

  import Ecto.Query, warn: false
  alias Prikke.Repo

  alias Prikke.Jobs.Job
  alias Prikke.Accounts.Organization
  alias Prikke.Audit

  # Tier limits
  @tier_limits %{
    "free" => %{
      max_jobs: 5,
      min_interval_minutes: 60,
      max_monthly_executions: 5_000,
      retention_days: 7
    },
    "pro" => %{
      max_jobs: :unlimited,
      min_interval_minutes: 1,
      max_monthly_executions: 250_000,
      retention_days: 30
    }
  }

  def tier_limits, do: @tier_limits

  def get_tier_limits(tier) do
    Map.get(@tier_limits, tier, @tier_limits["free"])
  end

  @doc """
  Subscribes to notifications about job changes for an organization.

  The broadcasted messages match the pattern:

    * {:created, %Job{}}
    * {:updated, %Job{}}
    * {:deleted, %Job{}}

  """
  def subscribe_jobs(%Organization{} = org) do
    Phoenix.PubSub.subscribe(Prikke.PubSub, "org:#{org.id}:jobs")
  end

  defp broadcast(%Organization{} = org, message) do
    Phoenix.PubSub.broadcast(Prikke.PubSub, "org:#{org.id}:jobs", message)
  end

  @doc """
  Notifies the scheduler to wake up and check for due jobs.
  Called when a job is created or enabled.
  """
  def notify_scheduler do
    Phoenix.PubSub.broadcast(Prikke.PubSub, "scheduler", :wake)
  end

  @doc """
  Notifies workers to wake up and check for pending executions.
  Called when new executions are created.
  """
  def notify_workers do
    Phoenix.PubSub.broadcast(Prikke.PubSub, "workers", :wake)
  end

  @doc """
  Returns the list of jobs for an organization.

  ## Examples

      iex> list_jobs(organization)
      [%Job{}, ...]

  """
  def list_jobs(%Organization{} = org) do
    # Subquery to get the latest execution time per job
    latest_exec_subquery =
      from(e in Prikke.Executions.Execution,
        group_by: e.job_id,
        select: %{job_id: e.job_id, last_exec: max(e.scheduled_for)}
      )

    from(j in Job,
      where: j.organization_id == ^org.id,
      left_join: le in subquery(latest_exec_subquery),
      on: le.job_id == j.id,
      order_by: [desc_nulls_last: le.last_exec, desc: j.inserted_at],
      select: j
    )
    |> Repo.all()
  end

  @doc """
  Returns enabled jobs for an organization.
  """
  def list_enabled_jobs(%Organization{} = org) do
    Job
    |> where(organization_id: ^org.id)
    |> where(enabled: true)
    |> order_by([j], desc: j.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a single job.

  Raises `Ecto.NoResultsError` if the Job does not exist.

  ## Examples

      iex> get_job!(organization, 123)
      %Job{}

      iex> get_job!(organization, 456)
      ** (Ecto.NoResultsError)

  """
  def get_job!(%Organization{} = org, id) do
    Job
    |> where(organization_id: ^org.id)
    |> Repo.get!(id)
  end

  @doc """
  Gets a single job, returns nil if not found.
  """
  def get_job(%Organization{} = org, id) do
    Job
    |> where(organization_id: ^org.id)
    |> Repo.get(id)
  end

  @doc """
  Creates a job for an organization.

  Enforces tier limits:
  - Free: max 5 jobs, hourly minimum interval
  - Pro: unlimited jobs, per-minute intervals

  ## Examples

      iex> create_job(organization, %{field: value})
      {:ok, %Job{}}

      iex> create_job(organization, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_job(%Organization{} = org, attrs, opts \\ []) do
    changeset = Job.create_changeset(%Job{}, attrs, org.id)

    with :ok <- check_job_limit(org),
         :ok <- check_interval_limit(org, changeset),
         {:ok, job} <- Repo.insert(changeset) do
      broadcast(org, {:created, job})
      audit_log(opts, :created, :job, job.id, org.id)
      {:ok, job}
    else
      {:error, :job_limit_reached} ->
        {:error,
         changeset
         |> Ecto.Changeset.add_error(
           :base,
           "You've reached the maximum number of jobs for your plan (#{get_tier_limits(org.tier).max_jobs}). Upgrade to Pro for unlimited jobs."
         )}

      {:error, :interval_too_frequent} ->
        {:error,
         changeset
         |> Ecto.Changeset.add_error(
           :cron_expression,
           "Free plan only allows hourly or less frequent schedules. Upgrade to Pro for per-minute scheduling."
         )}

      {:error, %Ecto.Changeset{}} = error ->
        error
    end
  end

  defp check_job_limit(%Organization{tier: tier} = org) do
    limits = get_tier_limits(tier)

    case limits.max_jobs do
      :unlimited ->
        :ok

      max when is_integer(max) ->
        if count_jobs(org) < max, do: :ok, else: {:error, :job_limit_reached}
    end
  end

  defp check_interval_limit(%Organization{tier: tier}, changeset) do
    limits = get_tier_limits(tier)
    schedule_type = Ecto.Changeset.get_field(changeset, :schedule_type)
    interval = Ecto.Changeset.get_field(changeset, :interval_minutes)

    cond do
      # One-time jobs are always allowed
      schedule_type == "once" -> :ok
      # No interval computed yet (validation will fail elsewhere)
      is_nil(interval) -> :ok
      # Check minimum interval
      interval >= limits.min_interval_minutes -> :ok
      true -> {:error, :interval_too_frequent}
    end
  end

  @doc """
  Updates a job.

  Enforces tier limits on interval changes.

  ## Examples

      iex> update_job(organization, job, %{field: new_value})
      {:ok, %Job{}}

      iex> update_job(organization, job, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_job(%Organization{} = org, %Job{} = job, attrs, opts \\ []) do
    if job.organization_id != org.id do
      raise ArgumentError, "job does not belong to organization"
    end

    changeset = Job.changeset(job, attrs)

    was_enabled = job.enabled
    old_job = Map.from_struct(job)

    with :ok <- check_interval_limit(org, changeset),
         {:ok, updated_job} <- Repo.update(changeset) do
      broadcast(org, {:updated, updated_job})
      # Notify scheduler if job was just enabled, or if schedule changed to be due soon
      if updated_job.enabled && updated_job.next_run_at do
        just_enabled = !was_enabled && updated_job.enabled
        due_soon = DateTime.diff(updated_job.next_run_at, DateTime.utc_now()) <= 60
        if just_enabled || due_soon, do: notify_scheduler()
      end

      # Audit log with changes
      changes = Audit.compute_changes(old_job, Map.from_struct(updated_job), [
        :name, :url, :method, :headers, :body, :schedule_type, :cron_expression,
        :scheduled_at, :timezone, :enabled, :timeout_ms, :retry_attempts
      ])
      audit_log(opts, :updated, :job, updated_job.id, org.id, changes: changes)

      {:ok, updated_job}
    else
      {:error, :interval_too_frequent} ->
        {:error,
         changeset
         |> Ecto.Changeset.add_error(
           :cron_expression,
           "Free plan only allows hourly or less frequent schedules. Upgrade to Pro for per-minute scheduling."
         )}

      {:error, %Ecto.Changeset{}} = error ->
        error
    end
  end

  @doc """
  Clears the next_run_at field for a job.

  This is used when an execution has been manually created (e.g., via queue API)
  to prevent the scheduler from also creating an execution for the same job.
  """
  def clear_next_run(%Job{} = job) do
    job
    |> Ecto.Changeset.change(next_run_at: nil)
    |> Repo.update()
  end

  @doc """
  Deletes a job.

  ## Examples

      iex> delete_job(organization, job)
      {:ok, %Job{}}

      iex> delete_job(organization, job)
      {:error, %Ecto.Changeset{}}

  """
  def delete_job(%Organization{} = org, %Job{} = job, opts \\ []) do
    if job.organization_id != org.id do
      raise ArgumentError, "job does not belong to organization"
    end

    with {:ok, job} <- Repo.delete(job) do
      broadcast(org, {:deleted, job})
      audit_log(opts, :deleted, :job, job.id, org.id, changes: %{"name" => job.name})
      {:ok, job}
    end
  end

  @doc """
  Toggles a job's enabled status.
  When enabling, resets next_run_at to avoid creating missed executions.
  """
  def toggle_job(%Organization{} = org, %Job{} = job, opts \\ []) do
    if job.organization_id != org.id do
      raise ArgumentError, "job does not belong to organization"
    end

    action = if job.enabled, do: :disabled, else: :enabled

    # When enabling, reset next_run_at to avoid missed executions backlog
    # We use Ecto.Changeset.change directly to bypass Job.changeset's compute_next_run_at
    changeset =
      if job.enabled do
        Ecto.Changeset.change(job, enabled: false, next_run_at: nil)
      else
        Ecto.Changeset.change(job,
          enabled: true,
          next_run_at: compute_next_run_for_enable(job)
        )
      end

    case Repo.update(changeset) do
      {:ok, updated_job} ->
        broadcast(org, {:updated, updated_job})

        # Notify scheduler if job was just enabled and has a next run
        if updated_job.enabled && updated_job.next_run_at do
          notify_scheduler()
        end

        # Log toggle for audit trail
        audit_log(opts, action, :job, updated_job.id, org.id)
        {:ok, updated_job}

      error ->
        error
    end
  end

  # Computes the next run time when enabling a job, starting from now.
  # This prevents creating missed executions for the time the job was disabled.
  defp compute_next_run_for_enable(%Job{schedule_type: "cron"} = job) do
    case Crontab.CronExpression.Parser.parse(job.cron_expression) do
      {:ok, cron} ->
        now = DateTime.utc_now()

        case Crontab.Scheduler.get_next_run_date(cron, DateTime.to_naive(now)) do
          {:ok, naive_next} -> DateTime.from_naive!(naive_next, "Etc/UTC")
          {:error, _} -> nil
        end

      {:error, _} ->
        nil
    end
  end

  defp compute_next_run_for_enable(%Job{schedule_type: "once"} = job) do
    # For one-time jobs, only schedule if scheduled_at is in the future
    if job.scheduled_at && DateTime.compare(job.scheduled_at, DateTime.utc_now()) == :gt do
      job.scheduled_at
    else
      # One-time job in the past won't run
      nil
    end
  end

  defp compute_next_run_for_enable(_job), do: nil

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking job changes.

  ## Examples

      iex> change_job(job)
      %Ecto.Changeset{data: %Job{}}

  """
  def change_job(%Job{} = job, attrs \\ %{}) do
    Job.changeset(job, attrs)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for creating a new job.
  """
  def change_new_job(%Organization{} = org, attrs \\ %{}) do
    Job.create_changeset(%Job{}, attrs, org.id)
  end

  @doc """
  Counts jobs for an organization.
  """
  def count_jobs(%Organization{} = org) do
    Job
    |> where(organization_id: ^org.id)
    |> Repo.aggregate(:count)
  end

  @doc """
  Counts enabled jobs for an organization.
  """
  def count_enabled_jobs(%Organization{} = org) do
    Job
    |> where(organization_id: ^org.id)
    |> where(enabled: true)
    |> Repo.aggregate(:count)
  end

  @doc """
  Deletes completed one-time jobs older than retention_days.

  A one-time job is "completed" when next_run_at is nil (already executed).
  """
  def cleanup_completed_once_jobs(%Organization{} = org, retention_days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-retention_days, :day)

    from(j in Job,
      where: j.organization_id == ^org.id,
      where: j.schedule_type == "once",
      where: is_nil(j.next_run_at),
      where: j.updated_at < ^cutoff
    )
    |> Repo.delete_all()
  end

  ## Platform-wide Stats (for superadmin)

  @doc """
  Counts total jobs across all organizations.
  """
  def count_all_jobs do
    Repo.aggregate(Job, :count)
  end

  @doc """
  Counts enabled jobs across all organizations.
  """
  def count_all_enabled_jobs do
    from(j in Job, where: j.enabled == true)
    |> Repo.aggregate(:count)
  end

  @doc """
  Lists recently created jobs across all organizations.
  """
  def list_recent_jobs_all(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    from(j in Job,
      order_by: [desc: j.inserted_at],
      limit: ^limit,
      preload: [:organization]
    )
    |> Repo.all()
  end

  ## Private: Audit Logging

  defp audit_log(opts, action, resource_type, resource_id, org_id, extra_opts \\ []) do
    scope = Keyword.get(opts, :scope)
    api_key_name = Keyword.get(opts, :api_key_name)
    changes = Keyword.get(extra_opts, :changes, %{})

    cond do
      scope != nil ->
        Audit.log(scope, action, resource_type, resource_id,
          organization_id: org_id,
          changes: changes
        )

      api_key_name != nil ->
        Audit.log_api(api_key_name, action, resource_type, resource_id,
          organization_id: org_id,
          changes: changes
        )

      true ->
        # No audit logging if no scope or api_key provided
        :ok
    end
  end
end
