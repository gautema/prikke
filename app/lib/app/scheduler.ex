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
  │  1. Tick every 10s or wake via PubSub                            │
  │  2. Acquire advisory lock (leader election)                      │
  │  3. Query: SELECT * FROM jobs WHERE enabled AND                  │
  │            next_run_at <= now + 30 seconds (lookahead)           │
  │  4. For each due job:                                            │
  │     a. Check monthly execution limit                             │
  │     b. Create pending execution with scheduled_for = next_run_at │
  │     c. Advance next_run_at (cron) or clear it (one-time)        │
  │  5. Workers claim executions only when scheduled_for <= now      │
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

  In addition to the 10-second tick interval, the scheduler can be woken immediately
  when a job becomes due:

  - Subscribes to PubSub topic "scheduler"
  - `Jobs.notify_scheduler/0` broadcasts `:wake` message
  - Called when a job is enabled or updated to be due soon
  - Reduces latency for one-time jobs and recently-enabled jobs

  ## Job Scheduling Flow

  For **cron jobs**:
  1. Job created with `next_run_at` = next cron time (computed from expression)
  2. Scheduler finds job when `next_run_at <= now + 30s` (lookahead)
  3. Creates pending execution with `scheduled_for = next_run_at`
  4. Advances `next_run_at` to next cron time
  5. Workers claim execution when `scheduled_for <= now` (precise timing)
  6. Repeat forever

  For **one-time jobs**:
  1. Job created with `next_run_at = scheduled_at`
  2. Scheduler finds job when `next_run_at <= now + 30s` (lookahead)
  3. Creates pending execution with `scheduled_for = next_run_at`
  4. Sets `next_run_at = nil` (job won't run again)
  5. Workers claim execution when `scheduled_for <= now`

  ## Monthly Limits

  Before creating an execution, the scheduler checks the organization's monthly
  execution count against their tier limit:

  - Free: 5,000 executions/month
  - Pro: 250,000 executions/month

  If the limit is reached, the job is skipped but `next_run_at` is still advanced
  to prevent infinite retry loops.

  ## Configuration

  - `@tick_interval` - Tick interval (10 seconds)
  - `@lookahead_seconds` - How far ahead to create executions (30 seconds)
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

  # Tick interval in milliseconds (10 seconds)
  @tick_interval 10_000

  # Lookahead window in seconds (30 seconds)
  # Jobs are created this far in advance for more precise timing.
  # Workers only claim executions when scheduled_for <= now.
  @lookahead_seconds 30

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
  automatically every 10 seconds and responds to PubSub wake-ups.

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

    result =
      if state.has_lock do
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
  # A job is "due" when: enabled = true AND next_run_at <= now + lookahead
  # Jobs within the lookahead window get executions created early, but workers
  # only claim them when scheduled_for <= now, giving precise timing.
  # Returns {:ok, count} where count is jobs successfully scheduled.
  defp schedule_due_jobs do
    now = DateTime.utc_now()
    lookahead_time = DateTime.add(now, @lookahead_seconds, :second)

    due_jobs =
      from(j in Job,
        where: j.enabled == true and j.next_run_at <= ^lookahead_time,
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
      # Wake workers to process the new executions
      Prikke.Jobs.notify_workers()
    end

    {:ok, scheduled_count}
  end

  # Schedules a single job, handling both upcoming and overdue jobs.
  #
  # For upcoming jobs (next_run_at > now but within lookahead):
  # - Create pending execution with scheduled_for = next_run_at
  # - Workers will claim it when scheduled_for <= now
  # - Advance next_run_at to next cron time
  #
  # For overdue jobs (next_run_at <= now):
  # - Use catch-up logic for missed runs
  # - Grace period: 50% of interval (min 30s, max 1 hour)
  #
  # Returns:
  # - :ok - execution created
  # - :skipped - monthly limit reached or no executions created
  # - :error - failed to create execution
  defp schedule_job(job) do
    now = DateTime.utc_now()

    if DateTime.compare(job.next_run_at, now) == :gt do
      # Upcoming job (within lookahead window) - pre-schedule for precise timing
      schedule_upcoming_job(job)
    else
      # Overdue job - use catch-up logic
      schedule_overdue_job(job, now)
    end
  end

  # Schedules an upcoming job by creating an execution in advance.
  # The execution has scheduled_for set to the job's next_run_at,
  # so workers will only claim it at the right time.
  defp schedule_upcoming_job(job) do
    if within_monthly_limit?(job) do
      case Executions.create_execution_for_job(job, job.next_run_at) do
        {:ok, _} ->
          advance_next_run_at(job)
          # Check if we should notify about approaching/reaching limit
          check_limit_notification(job.organization)
          :ok

        {:error, reason} ->
          Logger.error(
            "[Scheduler] Failed to create execution for job #{job.id}: #{inspect(reason)}"
          )
          :error
      end
    else
      Logger.warning(
        "[Scheduler] Job #{job.id} skipped - monthly limit reached for org #{job.organization_id}"
      )
      # Still advance to prevent infinite retries
      advance_next_run_at(job)
      # Notify that limit was reached
      check_limit_notification(job.organization)
      :skipped
    end
  end

  # Checks if we should send a limit notification (80% warning or 100% reached)
  defp check_limit_notification(organization) do
    current_count = Executions.count_current_month_executions(organization)
    Prikke.Accounts.maybe_send_limit_notification(organization, current_count)
  end

  # Schedules an overdue job, handling any missed runs if the scheduler was down.
  defp schedule_overdue_job(job, now) do
    # Compute all missed run times
    missed_times = compute_missed_run_times(job, now)

    if Enum.empty?(missed_times) do
      :skipped
    else
      # Create executions for each missed time
      result = create_catchup_executions(job, missed_times, now)

      # Advance next_run_at past all missed times
      advance_job_past_missed(job, missed_times)

      result
    end
  end

  # Computes all run times that were missed between next_run_at and now.
  # For cron jobs, this can be multiple times if scheduler was down.
  # For one-time jobs, this is just the single scheduled time.
  # Only includes times AFTER the job was created (no backfill for new jobs).
  defp compute_missed_run_times(job, now) do
    times =
      case job.schedule_type do
        "cron" ->
          compute_missed_cron_times(job, now, [])

        "once" ->
          # One-time jobs have only one run time
          if job.next_run_at && DateTime.compare(job.next_run_at, now) != :gt do
            [job.next_run_at]
          else
            []
          end

        _ ->
          []
      end

    # Filter out any times before the job was created
    # This prevents backfilling missed executions for newly created jobs
    Enum.filter(times, fn scheduled_for ->
      DateTime.compare(scheduled_for, job.inserted_at) != :lt
    end)
  end

  # Recursively computes all missed cron times from next_run_at until now.
  defp compute_missed_cron_times(job, now, acc) do
    current_run = job.next_run_at

    if current_run && DateTime.compare(current_run, now) != :gt do
      # This time is due, add it and compute next
      case compute_next_cron_time(job, current_run) do
        {:ok, next_run} ->
          updated_job = %{job | next_run_at: next_run}
          compute_missed_cron_times(updated_job, now, acc ++ [current_run])

        :error ->
          acc ++ [current_run]
      end
    else
      acc
    end
  end

  # Computes the next cron time after a given reference time.
  defp compute_next_cron_time(job, reference) do
    case Crontab.CronExpression.Parser.parse(job.cron_expression) do
      {:ok, cron} ->
        # Add 1 minute to reference to get the NEXT run, not the same one
        reference_plus_one = DateTime.add(reference, 60, :second)

        case Crontab.Scheduler.get_next_run_date(cron, DateTime.to_naive(reference_plus_one)) do
          {:ok, naive_next} ->
            {:ok, DateTime.from_naive!(naive_next, "Etc/UTC")}

          {:error, _} ->
            :error
        end

      {:error, _} ->
        :error
    end
  end

  # Creates executions for all missed times.
  # - All times except the last: "missed" status (for visibility)
  # - Last time within grace period: "pending" status (can still run)
  # - Last time past grace period: "missed" status
  defp create_catchup_executions(job, missed_times, now) do
    {all_but_last, last} = split_last(missed_times)

    # Create missed executions for all but the last
    Enum.each(all_but_last, fn scheduled_for ->
      Executions.create_missed_execution(job, scheduled_for)
    end)

    # For the last one, check grace period and monthly limit
    case last do
      nil ->
        :skipped

      scheduled_for ->
        if within_grace_period?(job, scheduled_for, now) and within_monthly_limit?(job) do
          case Executions.create_execution_for_job(job, scheduled_for) do
            {:ok, _} ->
              :ok

            {:error, reason} ->
              Logger.error(
                "[Scheduler] Failed to create execution for job #{job.id}: #{inspect(reason)}"
              )

              :error
          end
        else
          # Past grace period or over monthly limit - mark as missed
          if not within_monthly_limit?(job) do
            Logger.warning(
              "[Scheduler] Job #{job.id} skipped - monthly limit reached for org #{job.organization_id}"
            )
          end

          Executions.create_missed_execution(job, scheduled_for)
          :skipped
        end
    end
  end

  # Splits a list into all elements except the last, and the last element.
  defp split_last([]), do: {[], nil}

  defp split_last(list) do
    {Enum.drop(list, -1), List.last(list)}
  end

  # Checks if a scheduled time is within the grace period.
  # Grace period = 50% of interval (min 30s, max 1 hour)
  # One-time jobs always run (no grace limit) since they're explicitly scheduled.
  defp within_grace_period?(job, scheduled_for, now) do
    case job.interval_minutes do
      nil ->
        # One-time jobs: always within grace, they should always run
        true

      interval_minutes ->
        grace_seconds = compute_grace_period_seconds(interval_minutes)
        seconds_overdue = DateTime.diff(now, scheduled_for, :second)
        seconds_overdue < grace_seconds
    end
  end

  # Computes grace period in seconds based on job interval.
  # 50% of interval, minimum 30 seconds, maximum 1 hour.
  defp compute_grace_period_seconds(interval_minutes) do
    # 50% of interval in seconds
    grace = interval_minutes * 30
    # Minimum 30 seconds
    grace = max(grace, 30)
    # Maximum 1 hour
    min(grace, 3600)
  end

  # Advances the job's next_run_at to the next scheduled time.
  # For cron jobs: computes next cron time from current next_run_at
  # For one-time jobs: sets next_run_at to nil
  defp advance_next_run_at(job) do
    case job.schedule_type do
      "cron" ->
        case compute_next_cron_time(job, job.next_run_at) do
          {:ok, next_run} ->
            job
            |> Ecto.Changeset.change(next_run_at: next_run)
            |> Repo.update()

          :error ->
            :ok
        end

      "once" ->
        job
        |> Ecto.Changeset.change(next_run_at: nil)
        |> Repo.update()

      _ ->
        :ok
    end
  end

  # Advances the job's next_run_at past all missed times.
  defp advance_job_past_missed(job, missed_times) do
    case job.schedule_type do
      "cron" ->
        # Get the last missed time and compute next from there
        last_missed = List.last(missed_times)

        case compute_next_cron_time(job, last_missed) do
          {:ok, next_run} ->
            job
            |> Ecto.Changeset.change(next_run_at: next_run)
            |> Repo.update()

          :error ->
            :ok
        end

      "once" ->
        # One-time jobs set next_run_at to nil
        job
        |> Ecto.Changeset.change(next_run_at: nil)
        |> Repo.update()

      _ ->
        :ok
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
