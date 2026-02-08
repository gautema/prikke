defmodule Prikke.Scheduler do
  @moduledoc """
  Scheduler GenServer that creates pending executions for due tasks.

  ## Overview

  The scheduler is responsible for finding tasks that are due to run and creating
  pending executions for them. Workers then claim and execute these pending
  executions.

  ## How It Works

  ```
  ┌─────────────────────────────────────────────────────────────────┐
  │                         Scheduler                                │
  │                                                                  │
  │  1. Tick every 10s or wake via PubSub                            │
  │  2. Acquire advisory lock (leader election)                      │
  │  3. Query: SELECT * FROM tasks WHERE enabled AND                 │
  │            next_run_at <= now + 30 seconds (lookahead)           │
  │  4. For each due task:                                           │
  │     a. Check monthly execution limit                             │
  │     b. Create pending execution with scheduled_for = next_run_at │
  │     c. Advance next_run_at (cron) or clear it (one-time)        │
  │  5. Workers claim executions only when scheduled_for <= now      │
  └─────────────────────────────────────────────────────────────────┘
  ```

  ## Leader Election (Clustering)

  In a multi-node cluster, only one scheduler should create executions to avoid
  duplicates. We use Postgres transaction-level advisory locks:

  - `pg_try_advisory_xact_lock(id)` - non-blocking, returns true if acquired
  - Lock auto-releases when transaction commits
  - Each tick competes for the lock; no persistent leader

  This avoids connection pool issues with session-level locks.

  ## Wake-up Mechanism

  In addition to the 10-second tick interval, the scheduler can be woken immediately
  when a task becomes due:

  - Subscribes to PubSub topic "scheduler"
  - `Tasks.notify_scheduler/0` broadcasts `:wake` message
  - Called when a task is enabled or updated to be due soon
  - Reduces latency for one-time tasks and recently-enabled tasks

  ## Task Scheduling Flow

  For **cron tasks**:
  1. Task created with `next_run_at` = next cron time (computed from expression)
  2. Scheduler finds task when `next_run_at <= now + 30s` (lookahead)
  3. Creates pending execution with `scheduled_for = next_run_at`
  4. Advances `next_run_at` to next cron time
  5. Workers claim execution when `scheduled_for <= now` (precise timing)
  6. Repeat forever

  For **one-time tasks**:
  1. Task created with `next_run_at = scheduled_at`
  2. Scheduler finds task when `next_run_at <= now + 30s` (lookahead)
  3. Creates pending execution with `scheduled_for = next_run_at`
  4. Sets `next_run_at = nil` (task won't run again)
  5. Workers claim execution when `scheduled_for <= now`

  ## Monthly Limits

  Before creating an execution, the scheduler checks the organization's monthly
  execution count against their tier limit:

  - Free: 5,000 executions/month
  - Pro: 1,000,000 executions/month

  If the limit is reached, the task is skipped but `next_run_at` is still advanced
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
  alias Prikke.Tasks.Task
  alias Prikke.Executions

  # Advisory lock ID - arbitrary unique number for this application
  # Used for leader election in multi-node clusters
  @advisory_lock_id 728_492_847

  # Tick interval in milliseconds (10 seconds)
  @tick_interval 10_000

  # Lookahead window in seconds (10 seconds)
  # Tasks are created this far in advance for more precise timing.
  # Workers only claim executions when scheduled_for <= now.
  @lookahead_seconds 10

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

  Finds all due tasks and creates pending executions. Returns `{:ok, count}`
  where count is the number of tasks scheduled.

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

    {:ok, %{test_mode: test_mode}}
  end

  @impl true
  def handle_info(:tick, state) do
    run_with_lock(state)

    # Schedule next tick
    Process.send_after(self(), :tick, @tick_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:wake, state) do
    # Immediately check for due tasks when notified
    run_with_lock(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:tick, _from, state) do
    result = run_with_lock(state)
    {:reply, result, state}
  end

  ## Private Functions

  # Runs schedule_due_tasks inside a transaction with an advisory lock.
  # Uses pg_try_advisory_xact_lock which auto-releases when transaction commits.
  # This avoids connection pool issues with session-level locks.
  defp run_with_lock(%{test_mode: true}) do
    # In test mode, skip advisory lock (each test has its own scheduler)
    schedule_due_tasks()
  end

  defp run_with_lock(_state) do
    Repo.transaction(fn ->
      case Repo.query("SELECT pg_try_advisory_xact_lock($1)", [@advisory_lock_id]) do
        {:ok, %{rows: [[true]]}} ->
          schedule_due_tasks()

        _ ->
          # Another node holds the lock for this tick
          {:ok, 0}
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, _} -> {:ok, 0}
    end
  end

  # Finds all due tasks and creates pending executions for them.
  # A task is "due" when: enabled = true AND next_run_at <= now + lookahead
  # Tasks within the lookahead window get executions created early, but workers
  # only claim them when scheduled_for <= now, giving precise timing.
  # Returns {:ok, count} where count is tasks successfully scheduled.
  defp schedule_due_tasks do
    now = DateTime.utc_now()
    lookahead_time = DateTime.add(now, @lookahead_seconds, :second)

    due_tasks =
      from(t in Task,
        where: t.enabled == true and t.next_run_at <= ^lookahead_time,
        preload: [:organization]
      )
      |> Repo.all()

    scheduled_count =
      Enum.reduce(due_tasks, 0, fn task, count ->
        case schedule_task(task) do
          :ok -> count + 1
          :skipped -> count
          :error -> count
        end
      end)

    if scheduled_count > 0 do
      Logger.info("[Scheduler] Scheduled #{scheduled_count} task(s)")
      # Wake workers to process the new executions
      Prikke.Tasks.notify_workers()
    end

    {:ok, scheduled_count}
  end

  # Schedules a single task, handling both upcoming and overdue tasks.
  #
  # For upcoming tasks (next_run_at > now but within lookahead):
  # - Create pending execution with scheduled_for = next_run_at
  # - Workers will claim it when scheduled_for <= now
  # - Advance next_run_at to next cron time
  #
  # For overdue tasks (next_run_at <= now):
  # - Use catch-up logic for missed runs
  # - Grace period: 50% of interval (min 30s, max 1 hour)
  #
  # Returns:
  # - :ok - execution created
  # - :skipped - monthly limit reached or no executions created
  # - :error - failed to create execution
  defp schedule_task(task) do
    now = DateTime.utc_now()

    if DateTime.compare(task.next_run_at, now) == :gt do
      # Upcoming task (within lookahead window) - pre-schedule for precise timing
      schedule_upcoming_task(task)
    else
      # Overdue task - use catch-up logic
      schedule_overdue_task(task, now)
    end
  end

  # Schedules an upcoming task by creating an execution in advance.
  # The execution has scheduled_for set to the task's next_run_at,
  # so workers will only claim it at the right time.
  defp schedule_upcoming_task(task) do
    if within_monthly_limit?(task) do
      case Executions.create_execution_for_task(task, task.next_run_at) do
        {:ok, _} ->
          advance_next_run_at(task)
          # Check if we should notify about approaching/reaching limit
          check_limit_notification(task.organization)
          :ok

        {:error, reason} ->
          Logger.error(
            "[Scheduler] Failed to create execution for task #{task.id}: #{inspect(reason)}"
          )

          :error
      end
    else
      Logger.warning(
        "[Scheduler] Task #{task.id} skipped - monthly limit reached for org #{task.organization_id}"
      )

      # Still advance to prevent infinite retries
      advance_next_run_at(task)
      # Notify that limit was reached
      check_limit_notification(task.organization)
      :skipped
    end
  end

  # Checks if we should send a limit notification (80% warning or 100% reached)
  defp check_limit_notification(organization) do
    org = Prikke.Repo.reload!(organization)
    current_count = Executions.count_current_month_executions(org)
    Prikke.Accounts.maybe_send_limit_notification(org, current_count)
  end

  # Schedules an overdue task, handling any missed runs if the scheduler was down.
  defp schedule_overdue_task(task, now) do
    # Compute all missed run times
    missed_times = compute_missed_run_times(task, now)

    if Enum.empty?(missed_times) do
      :skipped
    else
      # Create executions for each missed time
      result = create_catchup_executions(task, missed_times, now)

      # Advance next_run_at past all missed times
      advance_task_past_missed(task, missed_times)

      result
    end
  end

  # Computes all run times that were missed between next_run_at and now.
  # For cron tasks, this can be multiple times if scheduler was down.
  # For one-time tasks, this is just the single scheduled time.
  # Only includes times AFTER the task was created (no backfill for new tasks).
  defp compute_missed_run_times(task, now) do
    times =
      case task.schedule_type do
        "cron" ->
          compute_missed_cron_times(task, now, [])

        "once" ->
          # One-time tasks have only one run time
          if task.next_run_at && DateTime.compare(task.next_run_at, now) != :gt do
            [task.next_run_at]
          else
            []
          end

        _ ->
          []
      end

    # Filter out any times before the task was created
    # This prevents backfilling missed executions for newly created tasks
    Enum.filter(times, fn scheduled_for ->
      DateTime.compare(scheduled_for, task.inserted_at) != :lt
    end)
  end

  # Recursively computes all missed cron times from next_run_at until now.
  defp compute_missed_cron_times(task, now, acc) do
    current_run = task.next_run_at

    if current_run && DateTime.compare(current_run, now) != :gt do
      # This time is due, add it and compute next
      case compute_next_cron_time(task, current_run) do
        {:ok, next_run} ->
          updated_task = %{task | next_run_at: next_run}
          compute_missed_cron_times(updated_task, now, acc ++ [current_run])

        :error ->
          acc ++ [current_run]
      end
    else
      acc
    end
  end

  # Computes the next cron time after a given reference time.
  defp compute_next_cron_time(task, reference) do
    case Crontab.CronExpression.Parser.parse(task.cron_expression) do
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
  defp create_catchup_executions(task, missed_times, now) do
    {all_but_last, last} = split_last(missed_times)

    # Create missed executions for all but the last
    Enum.each(all_but_last, fn scheduled_for ->
      Executions.create_missed_execution(task, scheduled_for)
    end)

    # For the last one, check grace period and monthly limit
    case last do
      nil ->
        :skipped

      scheduled_for ->
        if within_grace_period?(task, scheduled_for, now) and within_monthly_limit?(task) do
          case Executions.create_execution_for_task(task, scheduled_for) do
            {:ok, _} ->
              :ok

            {:error, reason} ->
              Logger.error(
                "[Scheduler] Failed to create execution for task #{task.id}: #{inspect(reason)}"
              )

              :error
          end
        else
          # Past grace period or over monthly limit - mark as missed
          if not within_monthly_limit?(task) do
            Logger.warning(
              "[Scheduler] Task #{task.id} skipped - monthly limit reached for org #{task.organization_id}"
            )
          end

          Executions.create_missed_execution(task, scheduled_for)
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
  # One-time tasks always run (no grace limit) since they're explicitly scheduled.
  defp within_grace_period?(task, scheduled_for, now) do
    case task.interval_minutes do
      nil ->
        # One-time tasks: always within grace, they should always run
        true

      interval_minutes ->
        grace_seconds = compute_grace_period_seconds(interval_minutes)
        seconds_overdue = DateTime.diff(now, scheduled_for, :second)
        seconds_overdue < grace_seconds
    end
  end

  # Computes grace period in seconds based on task interval.
  # 50% of interval, minimum 30 seconds, maximum 1 hour.
  defp compute_grace_period_seconds(interval_minutes) do
    # 50% of interval in seconds
    grace = interval_minutes * 30
    # Minimum 30 seconds
    grace = max(grace, 30)
    # Maximum 1 hour
    min(grace, 3600)
  end

  # Advances the task's next_run_at to the next scheduled time.
  # For cron tasks: computes next cron time from current next_run_at
  # For one-time tasks: sets next_run_at to nil
  defp advance_next_run_at(task) do
    case task.schedule_type do
      "cron" ->
        case compute_next_cron_time(task, task.next_run_at) do
          {:ok, next_run} ->
            task
            |> Ecto.Changeset.change(next_run_at: next_run)
            |> Repo.update()

          :error ->
            :ok
        end

      "once" ->
        task
        |> Ecto.Changeset.change(next_run_at: nil)
        |> Repo.update()

      _ ->
        :ok
    end
  end

  # Advances the task's next_run_at past all missed times.
  defp advance_task_past_missed(task, missed_times) do
    case task.schedule_type do
      "cron" ->
        # Get the last missed time and compute next from there
        last_missed = List.last(missed_times)

        case compute_next_cron_time(task, last_missed) do
          {:ok, next_run} ->
            task
            |> Ecto.Changeset.change(next_run_at: next_run)
            |> Repo.update()

          :error ->
            :ok
        end

      "once" ->
        # One-time tasks set next_run_at to nil
        task
        |> Ecto.Changeset.change(next_run_at: nil)
        |> Repo.update()

      _ ->
        :ok
    end
  end

  # Checks if the organization is within their monthly execution limit.
  # Limits are defined in Tasks.get_tier_limits/1:
  # - Free: 5,000 executions/month
  # - Pro: 1,000,000 executions/month
  defp within_monthly_limit?(task) do
    # Reload org to get fresh counter value
    org = Prikke.Repo.reload!(task.organization)
    tier_limits = Prikke.Tasks.get_tier_limits(org.tier)

    case tier_limits.max_monthly_executions do
      :unlimited ->
        true

      max when is_integer(max) ->
        current = Executions.count_current_month_executions(org)
        current < max
    end
  end
end
