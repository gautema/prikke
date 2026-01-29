defmodule Prikke.Status do
  @moduledoc """
  Context for system status monitoring.

  Maintains exactly 3 rows in status_checks (one per component).
  Creates incidents when components go down and resolves them when they recover.
  """

  import Ecto.Query
  alias Prikke.Repo
  alias Prikke.Status.{StatusCheck, Incident}

  @components ~w(scheduler workers api)

  @doc """
  Updates or creates a status check for a component.
  Returns {:ok, check, :created | :updated | :status_changed}
  """
  def upsert_check(component, status, message \\ nil) do
    now = DateTime.utc_now(:second)

    case get_check(component) do
      nil ->
        # First check for this component
        attrs = %{
          component: component,
          status: status,
          message: message,
          started_at: now,
          last_checked_at: now,
          last_status_change_at: now
        }

        case create_check(attrs) do
          {:ok, check} -> {:ok, check, :created}
          error -> error
        end

      existing ->
        # Update existing check
        status_changed = existing.status != status

        attrs = %{
          status: status,
          message: message,
          last_checked_at: now
        }

        attrs =
          if status_changed do
            Map.put(attrs, :last_status_change_at, now)
          else
            attrs
          end

        case update_check(existing, attrs) do
          {:ok, check} ->
            if status_changed do
              {:ok, check, :status_changed}
            else
              {:ok, check, :updated}
            end

          error ->
            error
        end
    end
  end

  @doc """
  Gets the status check for a component.
  """
  def get_check(component) do
    Repo.get_by(StatusCheck, component: component)
  end

  @doc """
  Gets all status checks.
  """
  def list_checks do
    Repo.all(StatusCheck)
  end

  defp create_check(attrs) do
    %StatusCheck{}
    |> StatusCheck.changeset(attrs)
    |> Repo.insert()
  end

  defp update_check(check, attrs) do
    check
    |> StatusCheck.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Gets the current status for all components.
  Returns a map of component => status info.
  """
  def get_current_status do
    checks = list_checks()
    check_map = Map.new(checks, &{&1.component, &1})

    Enum.reduce(@components, %{}, fn component, acc ->
      case Map.get(check_map, component) do
        nil ->
          Map.put(acc, component, %{
            status: "unknown",
            message: "No status check recorded",
            last_checked_at: nil,
            started_at: nil
          })

        check ->
          Map.put(acc, component, %{
            status: check.status,
            message: check.message,
            last_checked_at: check.last_checked_at,
            started_at: check.started_at,
            last_status_change_at: check.last_status_change_at
          })
      end
    end)
  end

  @doc """
  Returns the overall system status.
  """
  def overall_status do
    status = get_current_status()
    statuses = Enum.map(status, fn {_component, %{status: s}} -> s end)

    cond do
      Enum.all?(statuses, &(&1 == "up")) -> "operational"
      Enum.any?(statuses, &(&1 == "down")) -> "down"
      true -> "degraded"
    end
  end

  # Incidents

  @doc """
  Creates an incident when a component goes down.
  """
  def create_incident(component, status, message) do
    %Incident{}
    |> Incident.changeset(%{
      component: component,
      status: status,
      message: message,
      started_at: DateTime.utc_now(:second)
    })
    |> Repo.insert()
  end

  @doc """
  Gets the current open incident for a component (if any).
  """
  def get_open_incident(component) do
    from(i in Incident,
      where: i.component == ^component and is_nil(i.resolved_at),
      order_by: [desc: i.started_at],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Resolves an open incident.
  """
  def resolve_incident(incident) do
    incident
    |> Incident.resolve_changeset()
    |> Repo.update()
  end

  @doc """
  Lists recent resolved incidents (last 90 days).
  Open incidents are excluded as they're shown separately.
  """
  def list_recent_incidents(limit \\ 20) do
    cutoff = DateTime.add(DateTime.utc_now(), -90, :day)

    from(i in Incident,
      where: i.started_at >= ^cutoff and not is_nil(i.resolved_at),
      order_by: [desc: i.started_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Lists currently open incidents.
  """
  def list_open_incidents do
    from(i in Incident,
      where: is_nil(i.resolved_at),
      order_by: [desc: i.started_at]
    )
    |> Repo.all()
  end

  @doc """
  Returns daily uptime status for the last N days.
  Returns a list of {date, status} tuples where status is:
  - :up - no incidents that day
  - :down - had an incident that day
  - :unknown - no monitoring data for that day

  The list is ordered from oldest to newest (left to right for display).
  """
  def get_daily_uptime(days \\ 90) do
    today = Date.utc_today()
    start_date = Date.add(today, -(days - 1))

    # Get the earliest status check to know when monitoring started
    earliest_check =
      from(c in StatusCheck,
        order_by: [asc: c.started_at],
        limit: 1,
        select: c.started_at
      )
      |> Repo.one()

    monitoring_start_date =
      if earliest_check do
        DateTime.to_date(earliest_check)
      else
        nil
      end

    # Get all incidents in the date range
    incidents =
      from(i in Incident,
        where: i.started_at >= ^DateTime.new!(start_date, ~T[00:00:00], "Etc/UTC"),
        select: i
      )
      |> Repo.all()

    # Build a set of dates that had incidents
    incident_dates =
      incidents
      |> Enum.flat_map(fn incident ->
        incident_start = DateTime.to_date(incident.started_at)

        incident_end =
          if incident.resolved_at do
            DateTime.to_date(incident.resolved_at)
          else
            today
          end

        Date.range(incident_start, incident_end) |> Enum.to_list()
      end)
      |> MapSet.new()

    # Generate status for each day
    Date.range(start_date, today)
    |> Enum.map(fn date ->
      status =
        cond do
          # No monitoring data yet
          is_nil(monitoring_start_date) ->
            :unknown

          # Before monitoring started
          Date.compare(date, monitoring_start_date) == :lt ->
            :unknown

          # Had an incident
          MapSet.member?(incident_dates, date) ->
            :down

          # No incident, monitoring was active
          true ->
            :up
        end

      {date, status}
    end)
  end

  @doc """
  Detects if the system was down based on a gap since last check.
  If the last check was more than `threshold_minutes` ago, creates a resolved
  incident for the downtime period.

  Called on startup to record any downtime that occurred while the app wasn't running.
  Returns :ok or {:recorded, incident} if downtime was detected.
  """
  def detect_and_record_downtime(threshold_minutes \\ 2) do
    # Get the most recent status check across all components
    latest_check =
      from(c in StatusCheck,
        order_by: [desc: c.last_checked_at],
        limit: 1
      )
      |> Repo.one()

    case latest_check do
      nil ->
        # No previous checks, first startup
        :ok

      check ->
        now = DateTime.utc_now(:second)
        gap_minutes = DateTime.diff(now, check.last_checked_at, :minute)

        if gap_minutes >= threshold_minutes do
          # There was downtime - create a resolved incident
          downtime_start = check.last_checked_at
          downtime_end = now

          {:ok, incident} =
            %Incident{}
            |> Incident.changeset(%{
              component: "api",
              status: "down",
              message: "System was unavailable (detected on restart)",
              started_at: downtime_start
            })
            |> Repo.insert()

          # Immediately resolve since we're back up
          {:ok, resolved_incident} =
            incident
            |> Incident.resolve_changeset(downtime_end)
            |> Repo.update()

          {:recorded, resolved_incident}
        else
          :ok
        end
    end
  end
end
