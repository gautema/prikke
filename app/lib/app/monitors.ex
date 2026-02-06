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
