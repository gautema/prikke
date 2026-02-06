defmodule Prikke.MonitorChecker do
  @moduledoc """
  GenServer that checks for overdue monitors every 60 seconds.

  Finds monitors where the expected ping has not arrived within the
  grace period. Marks them as "down" and sends notifications.

  Uses advisory lock for leader election in multi-node clusters.
  """

  use GenServer
  require Logger

  alias Prikke.{Monitors, Notifications, Repo}

  @check_interval 30_000
  @advisory_lock_id 728_492_849

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def check_now do
    GenServer.call(__MODULE__, :check)
  end

  @impl true
  def init(opts) do
    test_mode = Keyword.get(opts, :test_mode, false)

    unless test_mode do
      Process.send_after(self(), :check, 5_000)
    end

    {:ok, %{test_mode: test_mode}}
  end

  @impl true
  def handle_info(:check, state) do
    try do
      run_with_lock(state)
    rescue
      e ->
        Logger.error("[MonitorChecker] Error during check: #{Exception.message(e)}")
    end

    Process.send_after(self(), :check, @check_interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:check, _from, state) do
    result = run_with_lock(state)
    {:reply, result, state}
  end

  defp run_with_lock(%{test_mode: true}) do
    check_overdue_monitors()
  end

  defp run_with_lock(_state) do
    Repo.transaction(fn ->
      case Repo.query("SELECT pg_try_advisory_xact_lock($1)", [@advisory_lock_id]) do
        {:ok, %{rows: [[true]]}} -> check_overdue_monitors()
        _ -> {:ok, 0}
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, _} -> {:ok, 0}
    end
  end

  defp check_overdue_monitors do
    overdue = Monitors.find_overdue_monitors()

    Enum.each(overdue, fn monitor ->
      Logger.warning("[MonitorChecker] Monitor #{monitor.id} (#{monitor.name}) is overdue")

      case Monitors.mark_down!(monitor) do
        {:ok, updated} ->
          Notifications.notify_monitor_down(updated)

        {:error, reason} ->
          Logger.error("[MonitorChecker] Failed to mark monitor down: #{inspect(reason)}")
      end
    end)

    {:ok, length(overdue)}
  end
end
