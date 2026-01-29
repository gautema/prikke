defmodule Prikke.Scheduler do
  @moduledoc """
  Scheduler GenServer that creates pending executions for due jobs.

  ## Overview

  The scheduler is responsible for finding jobs that are due to run and creating
  pending executions for them. Workers then claim and execute these pending
  executions.

  ## How It Works

  ```
  ┌─────────────────────────────────────────────────────────────────┐
  │                         Scheduler                                │
  │                                                                  │
  │  1. Tick every 60s (fallback) or wake via PubSub                │
  │  2. Acquire advisory lock (leader election)                      │
  │  3. Query: SELECT * FROM jobs WHERE enabled AND next_run_at <= now│
  │  4. For each due job:                                            │
  │     a. Check monthly execution limit                             │
  │     b. Create pending execution                                  │
  │     c. Advance next_run_at (cron) or clear it (one-time)        │
  └─────────────────────────────────────────────────────────────────┘
  ```

  ## Leader Election (Clustering)

  In a multi-node cluster, only one scheduler should create executions to avoid
  duplicates. We use Postgres advisory locks for leader election:

  - `pg_try_advisory_lock(id)` - non-blocking, returns true if acquired
  - `pg_advisory_unlock(id)` - releases the lock on shutdown
  - Lock is tied to the database connection, auto-releases if connection drops

  If a node can't acquire the lock, it stays passive until the leader fails.

  ## Wake-up Mechanism

  Instead of only ticking every 60 seconds, the scheduler can be woken immediately
  when a job becomes due:

  - Subscribes to PubSub topic "scheduler"
  - `Jobs.notify_scheduler/0` broadcasts `:wake` message
  - Called when a job is enabled or updated to be due within 60 seconds
  - Reduces latency for one-time jobs and recently-enabled jobs

  ## Job Scheduling Flow

  For **cron jobs**:
  1. Job created with `next_run_at` = next cron time (computed from expression)
  2. Scheduler finds job when `next_run_at <= now`
  3. Creates pending execution with `scheduled_for = next_run_at`
  4. Advances `next_run_at` to next cron time
  5. Repeat forever

  For **one-time jobs**:
  1. Job created with `next_run_at = scheduled_at`
  2. Scheduler finds job when `next_run_at <= now`
  3. Creates pending execution
  4. Sets `next_run_at = nil` (job won't run again)

  ## Monthly Limits

  Before creating an execution, the scheduler checks the organization's monthly
  execution count against their tier limit:

  - Free: 5,000 executions/month
  - Pro: 250,000 executions/month

  If the limit is reached, the job is skipped but `next_run_at` is still advanced
  to prevent infinite retry loops.

  ## Configuration

  - `@tick_interval` - Fallback tick interval (60 seconds)
  - `@advisory_lock_id` - Unique ID for the Postgres advisory lock

  ## Testing

  Start with `test_mode: true` to:
  - Skip auto-tick on init (call `tick/0` manually)
  - Bypass advisory lock (each test gets its own scheduler)
  """

  use GenServer
  require Logger

  import Ecto.Query
  alias Prikke.Repo
  alias Prikke.Jobs.Job
  alias Prikke.Executions

  # Advisory lock ID - arbitrary unique number for this application
  # Used for leader election in multi-node clusters
  @advisory_lock_id 728_492_847

  # Tick interval in milliseconds (60 seconds)
  # This is the fallback; PubSub wake-ups provide faster response
  @tick_interval 60_000

  ## Client API

  @doc """
  Starts the scheduler GenServer.

  ## Options

  - `:test_mode` - If true, skips auto-tick and advisory lock (default: false)

  ## Examples

      # Normal start (in application supervisor)
      Prikke.Scheduler.start_link()

      # Test mode
      start_supervised({Prikke.Scheduler, test_mode: true})
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually trigger a scheduler tick.

  Finds all due jobs and creates pending executions. Returns `{:ok, count}`
  where count is the number of jobs scheduled.

  This is primarily used for testing. In production, the scheduler ticks
  automatically every 60 seconds and responds to PubSub wake-ups.

  ## Examples

      iex> Prikke.Scheduler.tick()
      {:ok, 3}
  """
  def tick do
    GenServer.call(__MODULE__, :tick)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    # Subscribe to scheduler wake-up notifications
    Phoenix.PubSub.subscribe(Prikke.PubSub, "scheduler")

    test_mode = Keyword.get(opts, :test_mode, false)

    # In test mode, don't auto-tick (tests call tick() manually)
    unless test_mode do
      send(self(), :tick)
    end

    # In test mode, skip advisory lock (each test has its own scheduler)
    {:ok, %{has_lock: test_mode, test_mode: test_mode}}
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
  def handle_info(:wake, state) do
    # Immediately check for due jobs when notified
    state = maybe_acquire_lock(state)

    if state.has_lock do
      schedule_due_jobs()
    end

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

  @impl true
  def terminate(_reason, %{has_lock: true}) do
    # Release advisory lock on shutdown
    Repo.query("SELECT pg_advisory_unlock($1)", [@advisory_lock_id])
    :ok
  end

  def terminate(_reason, _state), do: :ok

  ## Private Functions

  # Attempts to acquire the Postgres advisory lock for leader election.
  # Returns state unchanged if already holding lock or in test mode.
  # Uses pg_try_advisory_lock which is non-blocking.
  defp maybe_acquire_lock(%{has_lock: true} = state), do: state
  defp maybe_acquire_lock(%{test_mode: true} = state), do: %{state | has_lock: true}

  defp maybe_acquire_lock(%{has_lock: false} = state) do
    case Repo.query("SELECT pg_try_advisory_lock($1)", [@advisory_lock_id]) do
      {:ok, %{rows: [[true]]}} ->
        Logger.info("[Scheduler] Acquired advisory lock, becoming leader")
        %{state | has_lock: true}

      _ ->
        # Another node holds the lock, stay passive
        state
    end
  end

  # Finds all due jobs and creates pending executions for them.
  # A job is "due" when: enabled = true AND next_run_at <= now
  # Returns {:ok, count} where count is jobs successfully scheduled.
  defp schedule_due_jobs do
    now = DateTime.utc_now()

    due_jobs =
      from(j in Job,
        where: j.enabled == true and j.next_run_at <= ^now,
        preload: [:organization]
      )
      |> Repo.all()

    scheduled_count =
      Enum.reduce(due_jobs, 0, fn job, count ->
        case schedule_job(job) do
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

  # Schedules a single job by creating a pending execution.
  #
  # Flow:
  # 1. Check monthly execution limit for the organization
  # 2. Create pending execution with scheduled_for = job.next_run_at
  # 3. Advance next_run_at:
  #    - Cron jobs: compute next cron time
  #    - One-time jobs: set to nil (won't run again)
  #
  # Returns:
  # - :ok - execution created successfully
  # - :skipped - monthly limit reached (next_run_at still advanced)
  # - :error - failed to create execution
  defp schedule_job(job) do
    if within_monthly_limit?(job) do
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
      # Still advance next_run_at so we don't keep trying this job
      job
      |> Job.advance_next_run_changeset()
      |> Repo.update()

      :skipped
    end
  end

  # Checks if the organization is within their monthly execution limit.
  # Limits are defined in Jobs.get_tier_limits/1:
  # - Free: 5,000 executions/month
  # - Pro: 250,000 executions/month
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
