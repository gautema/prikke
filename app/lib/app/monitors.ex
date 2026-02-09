defmodule Prikke.Monitors do
  @moduledoc """
  The Monitors context for heartbeat/dead man's switch monitoring.
  """

  import Ecto.Query, warn: false
  alias Prikke.Repo

  alias Prikke.Monitors.{Monitor, MonitorPing}
  alias Prikke.Accounts.Organization

  @tier_limits %{
    "free" => %{max_monitors: 3},
    "pro" => %{max_monitors: :unlimited}
  }

  def get_tier_limits(tier) do
    Map.get(@tier_limits, tier, @tier_limits["free"])
  end

  ## PubSub

  def subscribe_monitors(%Organization{} = org) do
    Phoenix.PubSub.subscribe(Prikke.PubSub, "org:#{org.id}:monitors")
  end

  defp broadcast(%Organization{} = org, message) do
    Phoenix.PubSub.broadcast(Prikke.PubSub, "org:#{org.id}:monitors", message)
  end

  ## CRUD

  def list_monitors(%Organization{} = org) do
    from(m in Monitor,
      where: m.organization_id == ^org.id,
      order_by: [desc: m.inserted_at]
    )
    |> Repo.all()
  end

  def get_monitor!(%Organization{} = org, id) do
    Monitor
    |> where(organization_id: ^org.id)
    |> Repo.get!(id)
  end

  def get_monitor(%Organization{} = org, id) do
    Monitor
    |> where(organization_id: ^org.id)
    |> Repo.get(id)
  end

  def get_monitor_by_token(token) do
    Repo.one(from m in Monitor, where: m.ping_token == ^token, preload: [:organization])
  end

  def create_monitor(%Organization{} = org, attrs, _opts \\ []) do
    changeset = Monitor.create_changeset(%Monitor{}, attrs, org.id)

    with :ok <- check_monitor_limit(org),
         {:ok, monitor} <- Repo.insert(changeset) do
      broadcast(org, {:monitor_created, monitor})
      {:ok, monitor}
    else
      {:error, :monitor_limit_reached} ->
        {:error,
         changeset
         |> Ecto.Changeset.add_error(
           :base,
           "You've reached the maximum number of monitors for your plan (#{get_tier_limits(org.tier).max_monitors}). Upgrade to Pro for unlimited monitors."
         )}

      {:error, %Ecto.Changeset{}} = error ->
        error
    end
  end

  def update_monitor(%Organization{} = org, %Monitor{} = monitor, attrs, _opts \\ []) do
    if monitor.organization_id != org.id do
      raise ArgumentError, "monitor does not belong to organization"
    end

    changeset = Monitor.changeset(monitor, attrs)

    case Repo.update(changeset) do
      {:ok, updated} ->
        broadcast(org, {:monitor_updated, updated})
        {:ok, updated}

      error ->
        error
    end
  end

  def delete_monitor(%Organization{} = org, %Monitor{} = monitor, _opts \\ []) do
    if monitor.organization_id != org.id do
      raise ArgumentError, "monitor does not belong to organization"
    end

    case Repo.delete(monitor) do
      {:ok, monitor} ->
        broadcast(org, {:monitor_deleted, monitor})
        {:ok, monitor}

      error ->
        error
    end
  end

  def toggle_monitor(%Organization{} = org, %Monitor{} = monitor, _opts \\ []) do
    if monitor.organization_id != org.id do
      raise ArgumentError, "monitor does not belong to organization"
    end

    if monitor.enabled do
      monitor
      |> Ecto.Changeset.change(enabled: false, status: "paused")
      |> Repo.update()
      |> tap_broadcast(org)
    else
      monitor
      |> Ecto.Changeset.change(enabled: true, status: "new", next_expected_at: nil)
      |> Repo.update()
      |> tap_broadcast(org)
    end
  end

  defp tap_broadcast({:ok, monitor} = result, org) do
    broadcast(org, {:monitor_updated, monitor})
    result
  end

  defp tap_broadcast(error, _org), do: error

  def count_monitors(%Organization{} = org) do
    Monitor
    |> where(organization_id: ^org.id)
    |> Repo.aggregate(:count)
  end

  def count_down_monitors(%Organization{} = org) do
    Monitor
    |> where(organization_id: ^org.id)
    |> where(status: "down")
    |> Repo.aggregate(:count)
  end

  def count_all_monitors do
    Repo.aggregate(Monitor, :count)
  end

  def count_all_down_monitors do
    from(m in Monitor, where: m.status == "down") |> Repo.aggregate(:count)
  end

  def change_monitor(%Monitor{} = monitor, attrs \\ %{}) do
    Monitor.changeset(monitor, attrs)
  end

  def change_new_monitor(%Organization{} = org, attrs \\ %{}) do
    Monitor.create_changeset(%Monitor{}, attrs, org.id)
  end

  ## Ping Handling

  def record_ping!(token) do
    Repo.transaction(fn ->
      case Repo.one(from m in Monitor, where: m.ping_token == ^token, preload: [:organization]) do
        nil ->
          Repo.rollback(:not_found)

        %Monitor{enabled: false} ->
          Repo.rollback(:disabled)

        monitor ->
          now = DateTime.utc_now() |> DateTime.truncate(:second)
          was_down = monitor.status == "down"

          %MonitorPing{}
          |> MonitorPing.changeset(%{monitor_id: monitor.id, received_at: now})
          |> Repo.insert!()

          next_expected = Monitor.compute_next_expected_at(monitor, now)

          new_status = if monitor.status in ["new", "down"], do: "up", else: monitor.status

          updated =
            monitor
            |> Ecto.Changeset.change(%{
              last_ping_at: now,
              next_expected_at: next_expected,
              status: new_status
            })
            |> Repo.update!()

          if was_down do
            Prikke.Notifications.notify_monitor_recovery(updated)
          end

          broadcast(monitor.organization, {:monitor_updated, updated})
          updated
      end
    end)
  end

  ## MonitorChecker queries

  def find_overdue_monitors do
    now = DateTime.utc_now()

    from(m in Monitor,
      where: m.enabled == true,
      where: m.status in ["new", "up"],
      where: not is_nil(m.next_expected_at),
      where:
        fragment(
          "? + make_interval(secs => ?) < ?",
          m.next_expected_at,
          m.grace_period_seconds,
          ^now
        ),
      preload: [:organization]
    )
    |> Repo.all()
  end

  def mark_down!(%Monitor{} = monitor) do
    monitor
    |> Ecto.Changeset.change(status: "down")
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        if monitor.organization do
          broadcast(monitor.organization, {:monitor_updated, updated})
        end

        {:ok, updated}

      error ->
        error
    end
  end

  ## Ping History

  def list_recent_pings(%Monitor{} = monitor, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(p in MonitorPing,
      where: p.monitor_id == ^monitor.id,
      order_by: [desc: p.received_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Builds a timeline of up/down periods for a monitor by collapsing consecutive
  pings into ranges and detecting gaps where pings were missed.

  Returns a list of maps sorted newest-first:
    - `%{type: :up, from: datetime, to: datetime, ping_count: integer}` — period with pings
    - `%{type: :down, from: datetime, to: datetime, duration_minutes: integer}` — missed period
  """
  def build_event_timeline(%Monitor{} = monitor, _opts \\ []) do
    pings =
      from(p in MonitorPing,
        where: p.monitor_id == ^monitor.id,
        order_by: [asc: p.received_at],
        limit: 500
      )
      |> Repo.all()

    expected_interval = get_expected_interval_seconds(monitor)

    if expected_interval == 0 or pings == [] do
      []
    else
      threshold = expected_interval + min(monitor.grace_period_seconds, expected_interval)
      periods = build_periods(pings, threshold)

      # If monitor is currently down, add a down period from last ping to now
      periods =
        if monitor.status == "down" and pings != [] do
          last_ping = List.last(pings)
          gap_seconds = DateTime.diff(DateTime.utc_now(), last_ping.received_at, :second)

          if gap_seconds > threshold do
            periods ++
              [
                %{
                  type: :down,
                  from: last_ping.received_at,
                  to: DateTime.utc_now(),
                  duration_minutes: div(gap_seconds, 60)
                }
              ]
          else
            periods
          end
        else
          periods
        end

      Enum.reverse(periods)
    end
  end

  defp build_periods([], _threshold), do: []

  defp build_periods([first | rest], threshold) do
    initial = %{type: :up, from: first.received_at, to: first.received_at, ping_count: 1}
    do_build_periods(rest, threshold, initial, [])
  end

  defp do_build_periods([], _threshold, current, acc), do: [current | acc]

  defp do_build_periods([ping | rest], threshold, current, acc) do
    gap_seconds = DateTime.diff(ping.received_at, current.to, :second)

    if gap_seconds > threshold do
      # Gap detected: close current up period, add down period, start new up period
      down = %{
        type: :down,
        from: current.to,
        to: ping.received_at,
        duration_minutes: div(gap_seconds, 60)
      }

      new_up = %{type: :up, from: ping.received_at, to: ping.received_at, ping_count: 1}
      do_build_periods(rest, threshold, new_up, [down, current | acc])
    else
      # No gap: extend current up period
      updated = %{current | to: ping.received_at, ping_count: current.ping_count + 1}
      do_build_periods(rest, threshold, updated, acc)
    end
  end

  defp get_expected_interval_seconds(%Monitor{schedule_type: "interval", interval_seconds: s})
       when is_integer(s) and s > 0,
       do: s

  defp get_expected_interval_seconds(%Monitor{schedule_type: "cron"} = monitor) do
    daily = expected_daily_pings(monitor)
    if daily > 0, do: div(86400, daily), else: 0
  end

  defp get_expected_interval_seconds(_), do: 0

  ## Daily Status

  @doc """
  Gets daily uptime status for multiple monitors over the last N days.
  Returns a map of monitor_id => [{date, status}, ...] where status is
  "up", "degraded", "down", or "none".

  Status is derived by comparing actual ping count vs expected ping count per day:
  - "up": 100% of expected pings received
  - "degraded": > 0 but < 100% of expected pings
  - "down": 0 pings when pings were expected
  - "none": monitor didn't exist yet or was paused
  """
  def get_daily_status(monitors, days) when is_list(monitors) do
    monitor_ids = Enum.map(monitors, & &1.id)
    since = DateTime.utc_now() |> DateTime.add(-days, :day)
    today = Date.utc_today()

    # Query actual ping counts per day per monitor
    ping_counts =
      from(p in MonitorPing,
        where: p.monitor_id in ^monitor_ids and p.received_at >= ^since,
        group_by: [p.monitor_id, fragment("DATE(?)", p.received_at)],
        select: {p.monitor_id, fragment("DATE(?)", p.received_at), count(p.id)}
      )
      |> Repo.all()
      |> Enum.reduce(%{}, fn {monitor_id, date, count}, acc ->
        Map.update(acc, monitor_id, %{date => count}, &Map.put(&1, date, count))
      end)

    # Build status per day per monitor
    now = DateTime.utc_now()

    monitors
    |> Map.new(fn monitor ->
      full_day_expected = expected_daily_pings(monitor)
      created_date = DateTime.to_date(monitor.inserted_at)

      days_list =
        Enum.map(0..(days - 1), fn offset ->
          date = Date.add(today, -days + 1 + offset)
          actual = get_in(ping_counts, [monitor.id, date]) || 0

          # Scale expected pings for partial days (today and creation date)
          expected =
            scale_expected_pings(
              full_day_expected,
              date,
              today,
              now,
              monitor.inserted_at,
              created_date
            )

          status =
            cond do
              Date.compare(date, created_date) == :lt ->
                "none"

              Date.compare(date, today) == :gt ->
                "none"

              # Paused monitor today: don't penalize for remaining time
              Date.compare(date, today) == :eq and not monitor.enabled ->
                if actual > 0, do: "up", else: "none"

              expected == 0 ->
                if actual > 0, do: "up", else: "none"

              actual >= expected ->
                "up"

              actual > 0 ->
                "degraded"

              true ->
                "down"
            end

          {date, %{status: status, actual: actual, expected: expected}}
        end)

      {monitor.id, days_list}
    end)
  end

  @doc """
  Computes the expected number of pings per day for a monitor based on its schedule.
  """
  def expected_daily_pings(%Monitor{schedule_type: "interval", interval_seconds: seconds})
      when is_integer(seconds) and seconds > 0 do
    div(86400, seconds)
  end

  def expected_daily_pings(%Monitor{schedule_type: "cron", cron_expression: expr})
      when is_binary(expr) do
    case Crontab.CronExpression.Parser.parse(expr) do
      {:ok, cron} ->
        # Count occurrences in a 24h window
        start = ~N[2025-01-01 00:00:00]
        stop = ~N[2025-01-02 00:00:00]

        Crontab.Scheduler.get_next_run_dates(cron, start)
        |> Enum.take_while(fn dt -> NaiveDateTime.compare(dt, stop) == :lt end)
        |> length()

      _ ->
        0
    end
  end

  def expected_daily_pings(_), do: 0

  # Scale expected pings for partial days: today (not finished yet) and
  # the creation date (monitor didn't exist since midnight).
  defp scale_expected_pings(full_day, date, today, now, inserted_at, created_date) do
    cond do
      # Today AND created today: only count from creation time to now
      Date.compare(date, today) == :eq and Date.compare(date, created_date) == :eq ->
        seconds_since_creation = DateTime.diff(now, inserted_at, :second)
        scale_by_seconds(full_day, max(seconds_since_creation, 0))

      # Today (partial day, not finished yet)
      Date.compare(date, today) == :eq ->
        seconds_elapsed = Time.diff(DateTime.to_time(now), ~T[00:00:00])
        scale_by_seconds(full_day, seconds_elapsed)

      # Creation date (monitor started partway through the day)
      Date.compare(date, created_date) == :eq ->
        seconds_remaining = Time.diff(~T[23:59:59], DateTime.to_time(inserted_at)) + 1
        scale_by_seconds(full_day, seconds_remaining)

      # Full past day
      true ->
        full_day
    end
  end

  defp scale_by_seconds(full_day, seconds) do
    trunc(full_day * seconds / 86400)
  end

  ## Cleanup

  def cleanup_old_pings(%Organization{} = org, retention_days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-retention_days, :day)

    from(p in MonitorPing,
      join: m in Monitor,
      on: p.monitor_id == m.id,
      where: m.organization_id == ^org.id,
      where: p.inserted_at < ^cutoff
    )
    |> Repo.delete_all()
  end

  ## Private

  defp check_monitor_limit(%Organization{tier: tier} = org) do
    limits = get_tier_limits(tier)

    case limits.max_monitors do
      :unlimited ->
        :ok

      max when is_integer(max) ->
        if count_monitors(org) < max, do: :ok, else: {:error, :monitor_limit_reached}
    end
  end
end
