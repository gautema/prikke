defmodule Prikke.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        PrikkeWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:app, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Prikke.PubSub},
        # Rate limiting storage
        {PlugAttack.Storage.Ets, name: PrikkeWeb.RateLimit.Storage, clean_period: 60_000},
        # Buffered execution counter (flushes to DB every 5s)
        Prikke.ExecutionCounter,
        # Task supervisor for async notifications
        {Task.Supervisor, name: Prikke.TaskSupervisor},
        # Start to serve requests, typically the last entry
        PrikkeWeb.Endpoint
      ]
      |> maybe_add_repo()
      |> maybe_add_scheduler()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Prikke.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Don't start Repo in CI mode (no database available)
  defp maybe_add_repo(children) do
    if Application.get_env(:app, :ci_mode, false) do
      children
    else
      [Prikke.Repo | children]
    end
  end

  # Don't start Scheduler/Workers in CI or test mode, and they need PubSub so add at the end
  # Uses compile_env because Mix.env() is not available in production releases
  @start_scheduler Application.compile_env(:app, :start_scheduler, true)

  defp maybe_add_scheduler(children) do
    if Application.get_env(:app, :ci_mode, false) or not @start_scheduler do
      children
    else
      children ++
        [
          Prikke.Scheduler,
          Prikke.WorkerSupervisor,
          Prikke.WorkerPool,
          Prikke.Cleanup,
          Prikke.StatusMonitor,
          Prikke.MonitorChecker,
          Prikke.Metrics
        ]
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PrikkeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
