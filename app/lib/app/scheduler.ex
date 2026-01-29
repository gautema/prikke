defmodule Prikke.Scheduler do
  @moduledoc """
  Scheduler GenServer that creates pending executions for due jobs.

  - Ticks every 60 seconds
  - Uses Postgres advisory lock so only one node schedules in a cluster
  - Finds jobs where next_run_at <= now
  - Creates pending executions
  - Advances next_run_at for cron jobs
  """

  use GenServer
  require Logger

  import Ecto.Query
  alias Prikke.Repo
  alias Prikke.Jobs.Job
  alias Prikke.Executions

  # Advisory lock ID - arbitrary unique number for this application
  @advisory_lock_id 728_492_847

  # Tick interval in milliseconds (60 seconds)
  @tick_interval 60_000

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually trigger a scheduler tick (for testing).
  """
  def tick do
    GenServer.call(__MODULE__, :tick)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    # Schedule first tick immediately
    send(self(), :tick)
    {:ok, %{has_lock: false}}
  end

  @impl true
  def handle_info(:tick, state) do
    state = maybe_acquire_lock(state)

    if state.has_lock do
      schedule_due_jobs()
    end

    # Schedule next tick
    Process.send_after(self(), :tick, @tick_interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:tick, _from, state) do
    state = maybe_acquire_lock(state)

    result = if state.has_lock do
      schedule_due_jobs()
    else
      {:ok, 0}
    end

    {:reply, result, state}
  end

  ## Private Functions

  defp maybe_acquire_lock(%{has_lock: true} = state), do: state

  defp maybe_acquire_lock(%{has_lock: false} = state) do
    # Try to acquire advisory lock (non-blocking)
    case Repo.query("SELECT pg_try_advisory_lock($1)", [@advisory_lock_id]) do
      {:ok, %{rows: [[true]]}} ->
        Logger.info("[Scheduler] Acquired advisory lock, becoming leader")
        %{state | has_lock: true}

      _ ->
        state
    end
  end

  defp schedule_due_jobs do
    now = DateTime.utc_now()

    # Find all enabled jobs that are due
    due_jobs =
      from(j in Job,
        where: j.enabled == true and j.next_run_at <= ^now,
        preload: [:organization]
      )
      |> Repo.all()

    scheduled_count =
      Enum.reduce(due_jobs, 0, fn job, count ->
        case schedule_job(job, now) do
          :ok -> count + 1
          :skipped -> count
          :error -> count
        end
      end)

    if scheduled_count > 0 do
      Logger.info("[Scheduler] Scheduled #{scheduled_count} job(s)")
    end

    {:ok, scheduled_count}
  end

  defp schedule_job(job, _now) do
    # Check monthly execution limit
    if within_monthly_limit?(job) do
      # Create pending execution
      case Executions.create_execution_for_job(job, job.next_run_at) do
        {:ok, _execution} ->
          # Advance next_run_at for cron jobs, or clear for one-time jobs
          job
          |> Job.advance_next_run_changeset()
          |> Repo.update()

          :ok

        {:error, reason} ->
          Logger.error("[Scheduler] Failed to create execution for job #{job.id}: #{inspect(reason)}")
          :error
      end
    else
      Logger.warning("[Scheduler] Job #{job.id} skipped - monthly limit reached for org #{job.organization_id}")
      # Still advance next_run_at so we don't keep trying
      job
      |> Job.advance_next_run_changeset()
      |> Repo.update()

      :skipped
    end
  end

  defp within_monthly_limit?(job) do
    org = job.organization
    tier_limits = Prikke.Jobs.get_tier_limits(org.tier)

    case tier_limits.max_monthly_executions do
      :unlimited ->
        true

      max when is_integer(max) ->
        current = Executions.count_current_month_executions(org)
        current < max
    end
  end
end
