defmodule Prikke.Monitors do
  @moduledoc """
  The Monitors context for heartbeat/dead man's switch monitoring.
  """

  import Ecto.Query, warn: false
  alias Prikke.Repo

  alias Prikke.Monitors.{Monitor, MonitorPing}
  alias Prikke.Accounts.Organization
  alias Prikke.Audit

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

  def create_monitor(%Organization{} = org, attrs, opts \\ []) do
    changeset = Monitor.create_changeset(%Monitor{}, attrs, org.id)

    with :ok <- check_monitor_limit(org),
         {:ok, monitor} <- Repo.insert(changeset) do
      broadcast(org, {:monitor_created, monitor})

      audit_log(opts, :created, :monitor, monitor.id, org.id,
        metadata: %{"monitor_name" => monitor.name}
      )

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

  def update_monitor(%Organization{} = org, %Monitor{} = monitor, attrs, opts \\ []) do
    if monitor.organization_id != org.id do
      raise ArgumentError, "monitor does not belong to organization"
    end

    changeset = Monitor.changeset(monitor, attrs)

    case Repo.update(changeset) do
      {:ok, updated} ->
        broadcast(org, {:monitor_updated, updated})

        changes =
          Audit.compute_changes(monitor, updated, [
            :name,
            :url,
            :method,
            :interval_seconds,
            :grace_period_seconds,
            :timeout_ms,
            :expected_status_code
          ])

        audit_log(opts, :updated, :monitor, updated.id, org.id, changes: changes)
        {:ok, updated}

      error ->
        error
    end
  end

  def delete_monitor(%Organization{} = org, %Monitor{} = monitor, opts \\ []) do
    if monitor.organization_id != org.id do
      raise ArgumentError, "monitor does not belong to organization"
    end

    case Repo.delete(monitor) do
      {:ok, monitor} ->
        broadcast(org, {:monitor_deleted, monitor})

        audit_log(opts, :deleted, :monitor, monitor.id, org.id,
          metadata: %{"monitor_name" => monitor.name}
        )

        {:ok, monitor}

      error ->
        error
    end
  end

  def toggle_monitor(%Organization{} = org, %Monitor{} = monitor, opts \\ []) do
    if monitor.organization_id != org.id do
      raise ArgumentError, "monitor does not belong to organization"
    end

    action = if monitor.enabled, do: :disabled, else: :enabled

    result =
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

    case result do
      {:ok, updated} ->
        audit_log(opts, action, :monitor, updated.id, org.id,
          metadata: %{"monitor_name" => updated.name}
        )

        result

      _ ->
        result
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

  @doc """
  Returns the uptime percentage for a monitor over the given number of days.
  Calculated as actual pings received / expected pings, with minute resolution.
  Returns nil if no pings are expected.
  """
  def monitor_uptime_percentage(%Monitor{} = monitor, days \\ 30) do
    since = DateTime.utc_now() |> DateTime.add(-days, :day)

    actual_pings =
      from(p in MonitorPing,
        where: p.monitor_id == ^monitor.id and p.received_at >= ^since,
        select: count()
      )
      |> Repo.one()

    daily_expected = expected_daily_pings(monitor)

    if daily_expected == 0 do
      nil
    else
      # Scale for partial first/last day
      created_at = monitor.inserted_at
      start_time = if DateTime.compare(created_at, since) == :gt, do: created_at, else: since
      minutes_monitored = DateTime.diff(DateTime.utc_now(), start_time, :minute)
      expected_total = minutes_monitored / (86400 / daily_expected / 60)

      if expected_total <= 0 do
        nil
      else
        percent = min(actual_pings / expected_total * 100, 100.0)
        Float.round(percent, 2)
      end
    end
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

          expected_interval = get_expected_interval_seconds(monitor)

          %MonitorPing{}
          |> MonitorPing.changeset(%{
            monitor_id: monitor.id,
            received_at: now,
            expected_interval_seconds: expected_interval
          })
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
  Builds a timeline of up/down periods for a monitor using a SQL window function
  to efficiently find gaps where pings were missed, then constructs up periods
  between those gaps.

  Returns a list of maps sorted newest-first:
    - `%{type: :up, from: datetime, to: datetime}` — period with pings
    - `%{type: :down, from: datetime, to: datetime, duration_minutes: integer}` — missed period
  """
  def build_event_timeline(%Monitor{} = monitor, _opts \\ []) do
    expected_interval = get_expected_interval_seconds(monitor)
    if expected_interval == 0, do: throw(:no_interval)

    threshold = expected_interval + monitor.grace_period_seconds
    grace = monitor.grace_period_seconds

    {:ok, monitor_id_binary} = Ecto.UUID.dump(monitor.id)

    # Use SQL window function to find gaps efficiently.
    # Each ping stores the expected_interval_seconds at the time it was recorded,
    # so we use per-ping thresholds to avoid retroactive false downtime when the
    # monitor interval is changed. Uses GREATEST of both sides of each gap so
    # that transitions between intervals (e.g. 15min→1min) don't create false
    # downtime at the boundary. Falls back to current interval for old pings.
    gaps =
      Repo.all(
        from(
          g in fragment(
            """
            SELECT gap_start, gap_end, gap_seconds
            FROM (
              SELECT
                lag(received_at) OVER (ORDER BY received_at) AS gap_start,
                received_at AS gap_end,
                EXTRACT(EPOCH FROM (received_at - lag(received_at) OVER (ORDER BY received_at))) AS gap_seconds,
                GREATEST(
                  COALESCE(expected_interval_seconds, ?),
                  COALESCE(lag(expected_interval_seconds) OVER (ORDER BY received_at), ?)
                ) + ? AS ping_threshold
              FROM monitor_pings
              WHERE monitor_id = ?
            ) sub
            WHERE gap_seconds > ping_threshold
            ORDER BY gap_end DESC
            """,
            ^expected_interval,
            ^expected_interval,
            ^grace,
            ^monitor_id_binary
          ),
          select: %{
            gap_start: g.gap_start,
            gap_end: g.gap_end,
            gap_seconds: g.gap_seconds
          }
        )
      )

    # Get first and last ping for the full range
    first_ping =
      from(p in MonitorPing,
        where: p.monitor_id == ^monitor.id,
        order_by: [asc: p.received_at],
        limit: 1,
        select: p.received_at
      )
      |> Repo.one()

    last_ping =
      from(p in MonitorPing,
        where: p.monitor_id == ^monitor.id,
        order_by: [desc: p.received_at],
        limit: 1,
        select: p.received_at
      )
      |> Repo.one()

    if is_nil(first_ping) do
      []
    else
      # Build timeline: interleave up periods between down gaps
      build_timeline_from_gaps(gaps, first_ping, last_ping, monitor, threshold)
    end
  catch
    :no_interval -> []
  end

  defp build_timeline_from_gaps(gaps, first_ping, last_ping, monitor, threshold) do
    # Convert gaps to down periods (already sorted newest-first)
    down_periods =
      Enum.map(gaps, fn g ->
        seconds =
          if is_struct(g.gap_seconds, Decimal),
            do: Decimal.to_float(g.gap_seconds),
            else: g.gap_seconds

        %{
          type: :down,
          from: to_utc_datetime(g.gap_start),
          to: to_utc_datetime(g.gap_end),
          duration_minutes: round(seconds / 60)
        }
      end)

    # If monitor is currently down, add ongoing down period
    down_periods =
      if monitor.status == "down" do
        gap_seconds = DateTime.diff(DateTime.utc_now(), last_ping, :second)

        if gap_seconds > threshold do
          [
            %{
              type: :down,
              from: last_ping,
              to: DateTime.utc_now(),
              duration_minutes: div(gap_seconds, 60)
            }
            | down_periods
          ]
        else
          down_periods
        end
      else
        down_periods
      end

    # Sort down periods oldest-first to build up periods between them
    downs_asc = Enum.sort_by(down_periods, & &1.from, DateTime)

    # Build up periods in the gaps between down periods
    periods = build_up_between_downs(first_ping, last_ping, downs_asc, monitor)

    # Sort newest-first for display
    Enum.sort_by(periods, fn p -> p.from end, {:desc, DateTime})
  end

  defp build_up_between_downs(first_ping, last_ping, downs, monitor) do
    now = DateTime.utc_now()

    # End of timeline: now if up, last ping if down
    timeline_end = if monitor.status == "down", do: last_ping, else: now

    case downs do
      [] ->
        [%{type: :up, from: first_ping, to: timeline_end}]

      _ ->
        # Up period before first down (if any)
        first_down = hd(downs)

        before =
          if DateTime.compare(first_ping, first_down.from) == :lt do
            [%{type: :up, from: first_ping, to: first_down.from}]
          else
            []
          end

        # Interleave: down, then up until next down
        middle =
          downs
          |> Enum.chunk_every(2, 1)
          |> Enum.flat_map(fn
            [down, next_down] ->
              [down, %{type: :up, from: down.to, to: next_down.from}]

            [down] ->
              [down]
          end)

        # Up period after last down (if monitor is up)
        last_down = List.last(downs)

        after_last =
          if monitor.status != "down" and DateTime.compare(last_down.to, timeline_end) == :lt do
            [%{type: :up, from: last_down.to, to: timeline_end}]
          else
            []
          end

        before ++ middle ++ after_last
    end
  end

  defp to_utc_datetime(%DateTime{} = dt), do: dt
  defp to_utc_datetime(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")

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

    # Query actual ping counts AND dominant expected interval per day per monitor.
    # Uses MODE() to find the most common expected_interval_seconds for each day,
    # so historical days use the interval that was active then, not the current one.
    ping_data =
      from(p in MonitorPing,
        where: p.monitor_id in ^monitor_ids and p.received_at >= ^since,
        group_by: [p.monitor_id, fragment("DATE(?)", p.received_at)],
        select:
          {p.monitor_id, fragment("DATE(?)", p.received_at), count(p.id),
           fragment("MODE() WITHIN GROUP (ORDER BY ?)", p.expected_interval_seconds)}
      )
      |> Repo.all()
      |> Enum.reduce(%{}, fn {monitor_id, date, count, interval}, acc ->
        Map.update(
          acc,
          monitor_id,
          %{date => {count, interval}},
          &Map.put(&1, date, {count, interval})
        )
      end)

    # Build status per day per monitor
    now = DateTime.utc_now()

    monitors
    |> Map.new(fn monitor ->
      fallback_expected = expected_daily_pings(monitor)
      created_date = DateTime.to_date(monitor.inserted_at)

      days_list =
        Enum.map(0..(days - 1), fn offset ->
          date = Date.add(today, -days + 1 + offset)
          {actual, day_interval} = get_in(ping_data, [monitor.id, date]) || {0, nil}

          # Use the interval that was active on that day, fall back to current
          full_day_expected =
            if is_integer(day_interval) and day_interval > 0,
              do: div(86400, day_interval),
              else: fallback_expected

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

  ## Private: Audit Logging

  defp audit_log(opts, action, resource_type, resource_id, org_id, extra_opts) do
    scope = Keyword.get(opts, :scope)
    changes = Keyword.get(extra_opts, :changes, %{})
    metadata = Keyword.get(extra_opts, :metadata, %{})

    if scope do
      Audit.log(scope, action, resource_type, resource_id,
        organization_id: org_id,
        changes: changes,
        metadata: metadata
      )
    else
      :ok
    end
  end
end
