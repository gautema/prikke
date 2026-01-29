defmodule Prikke.StatusMonitor do
  @moduledoc """
  GenServer that monitors system health every minute.

  Checks:
  - Scheduler: is the process alive?
  - Workers: is the worker supervisor alive?
  - API: always up if this process is running

  Updates status_checks table (3 rows total) and creates/resolves incidents
  when components go down or recover.
  """

  use GenServer
  require Logger

  alias Prikke.Status

  @check_interval 60_000  # 1 minute

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually trigger a status check.
  """
  def check_now do
    GenServer.call(__MODULE__, :check)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    test_mode = Keyword.get(opts, :test_mode, false)

    unless test_mode do
      # Initial check after a short delay
      Process.send_after(self(), :check, 5_000)
    end

    {:ok, %{test_mode: test_mode}}
  end

  @impl true
  def handle_info(:check, state) do
    perform_checks()

    # Schedule next check
    Process.send_after(self(), :check, @check_interval)

    {:noreply, state}
  end

  @impl true
  def handle_call(:check, _from, state) do
    perform_checks()
    {:reply, :ok, state}
  end

  ## Private Functions

  defp perform_checks do
    check_scheduler()
    check_workers()
    check_api()
  end

  defp check_scheduler do
    component = "scheduler"

    {status, message} =
      case Process.whereis(Prikke.Scheduler) do
        nil ->
          {"down", "Scheduler process not running"}

        pid when is_pid(pid) ->
          if Process.alive?(pid) do
            {"up", "Scheduler running"}
          else
            {"down", "Scheduler process dead"}
          end
      end

    handle_check_result(component, status, message)
  end

  defp check_workers do
    component = "workers"

    {status, message} =
      case Process.whereis(Prikke.WorkerSupervisor) do
        nil ->
          {"down", "Worker supervisor not running"}

        pid when is_pid(pid) ->
          if Process.alive?(pid) do
            {"up", "Workers operational"}
          else
            {"down", "Worker supervisor dead"}
          end
      end

    handle_check_result(component, status, message)
  end

  defp check_api do
    component = "api"
    # If this code is running, the API is up
    handle_check_result(component, "up", "API responding")
  end

  defp handle_check_result(component, status, message) do
    case Status.upsert_check(component, status, message) do
      {:ok, _check, :status_changed} ->
        handle_status_change(component, status, message)

      {:ok, _check, _} ->
        :ok

      {:error, reason} ->
        Logger.error("[StatusMonitor] Failed to update check for #{component}: #{inspect(reason)}")
    end
  end

  defp handle_status_change(component, status, message) do
    case status do
      "up" ->
        # Component recovered - resolve any open incident
        Logger.info("[StatusMonitor] #{component} recovered: #{message}")
        case Status.get_open_incident(component) do
          nil -> :ok
          incident -> Status.resolve_incident(incident)
        end

      status when status in ["down", "degraded"] ->
        # Component went down - create incident
        Logger.warning("[StatusMonitor] #{component} went #{status}: #{message}")
        Status.create_incident(component, status, message)
    end
  end
end
