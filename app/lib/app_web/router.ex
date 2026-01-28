defmodule PrikkeWeb.Router do
  use PrikkeWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PrikkeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", PrikkeWeb do
    pipe_through :browser

    get "/", PageController, :home

    # Documentation
    get "/docs", DocsController, :index
    get "/docs/getting-started", DocsController, :getting_started
    get "/docs/api", DocsController, :api
    get "/docs/cron", DocsController, :cron
    get "/docs/webhooks", DocsController, :webhooks
    get "/use-cases", DocsController, :use_cases
  end

  # Health check endpoint for Koyeb
  scope "/health", PrikkeWeb do
    pipe_through :api

    get "/", HealthController, :check
  end

  # Other scopes may use custom stacks.
  # scope "/api", PrikkeWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:app, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PrikkeWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
