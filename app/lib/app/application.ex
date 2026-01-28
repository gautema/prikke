defmodule Prikke.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PrikkeWeb.Telemetry,
      Prikke.Repo,
      {DNSCluster, query: Application.get_env(:app, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Prikke.PubSub},
      # Start a worker by calling: Prikke.Worker.start_link(arg)
      # {Prikke.Worker, arg},
      # Start to serve requests, typically the last entry
      PrikkeWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Prikke.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PrikkeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
