defmodule PrikkeWeb.Router do
  use PrikkeWeb, :router

  import PrikkeWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PrikkeWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "strict-transport-security" => "max-age=31536000; includeSubDomains",
      "permissions-policy" => "camera=(), microphone=(), geolocation=()"
    }

    plug :fetch_current_scope_for_user
    plug :fetch_current_organization
    plug PrikkeWeb.Plugs.TrackPageview
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug PrikkeWeb.RateLimit
  end

  scope "/", PrikkeWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/llms.txt", LlmsController, :index

    # Documentation
    get "/docs", DocsController, :index
    get "/docs/getting-started", DocsController, :getting_started
    get "/docs/api", DocsController, :api
    get "/docs/cron", DocsController, :cron
    get "/docs/webhooks", DocsController, :webhooks
    get "/docs/endpoints", DocsController, :endpoints
    get "/docs/monitors", DocsController, :monitors
    get "/docs/badges", DocsController, :badges
    get "/docs/status-pages", DocsController, :status_pages
    get "/docs/local-dev", DocsController, :local_dev
    get "/use-cases", DocsController, :use_cases

    # Framework guides
    get "/guides", GuidesController, :index
    get "/guides/nextjs-background-jobs", GuidesController, :nextjs
    get "/guides/cloudflare-workers-cron", GuidesController, :cloudflare_workers
    get "/guides/supabase-scheduled-tasks", GuidesController, :supabase
    get "/guides/webhook-proxy", GuidesController, :webhook_proxy

    # Public status page
    get "/status", StatusController, :index

    # Legal pages
    get "/terms", PageController, :terms
    get "/privacy", PageController, :privacy
    get "/legal/dpa", PageController, :dpa
    get "/legal/slo", PageController, :slo
    get "/legal/subprocessors", PageController, :subprocessors

    # Presentation
    get "/presentation", PageController, :presentation
  end

  # Public customer-facing status pages
  scope "/", PrikkeWeb do
    pipe_through :browser

    live_session :public_status_page,
      layout: {PrikkeWeb.Layouts, :root} do
      live "/s/:slug", PublicStatusLive, :show
    end
  end

  # Health check endpoint for Koyeb
  scope "/health", PrikkeWeb do
    pipe_through :api

    get "/", HealthController, :check
  end

  # Monitor ping endpoint (public, token is auth)
  scope "/ping", PrikkeWeb do
    pipe_through :api

    get "/:token", PingController, :ping
    post "/:token", PingController, :ping
  end

  # Creem payment webhook (public, signature verified in controller)
  scope "/webhooks", PrikkeWeb do
    pipe_through :api

    post "/creem", CreemWebhookController, :handle
  end

  # Public badge endpoints (token is auth)
  scope "/badge", PrikkeWeb do
    pipe_through :api

    get "/task/:token/status.svg", BadgeController, :task_status
    get "/task/:token/uptime.svg", BadgeController, :task_uptime
    get "/monitor/:token/status.svg", BadgeController, :monitor_status
    get "/monitor/:token/uptime.svg", BadgeController, :monitor_uptime
    get "/endpoint/:token/status.svg", BadgeController, :endpoint_status
    get "/endpoint/:token/uptime.svg", BadgeController, :endpoint_uptime
  end

  # Inbound webhook endpoint (public, slug is auth)
  scope "/in", PrikkeWeb do
    pipe_through :api

    match :*, "/:slug", InboundController, :receive
  end

  # API routes - authenticated via API keys
  pipeline :api_auth do
    plug PrikkeWeb.Plugs.ApiAuth
    plug PrikkeWeb.Plugs.Idempotency
  end

  # OpenAPI spec and Swagger UI (no auth required)
  scope "/api/v1" do
    pipe_through [:api]

    get "/openapi", PrikkeWeb.Api.OpenApiController, :spec
    get "/docs", OpenApiSpex.Plug.SwaggerUI, path: "/api/v1/openapi"
  end

  # API routes - authenticated via API keys
  scope "/api/v1", PrikkeWeb.Api do
    pipe_through [:api, :api_auth]

    # Tasks CRUD (unified: cron, delayed, scheduled, immediate)
    resources "/tasks", TaskController, except: [:new, :edit] do
      get "/executions", TaskController, :executions
      post "/trigger", TaskController, :trigger
    end

    # Monitors CRUD
    resources "/monitors", MonitorController, except: [:new, :edit] do
      get "/pings", MonitorController, :pings
    end

    # Endpoints CRUD
    resources "/endpoints", EndpointController, except: [:new, :edit] do
      get "/events", EndpointController, :events
      post "/events/:event_id/replay", EndpointController, :replay
    end

    # Declarative sync
    put "/sync", SyncController, :sync
  end

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

  ## Authentication routes

  scope "/", PrikkeWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    get "/users/register", UserRegistrationController, :new
    post "/users/register", UserRegistrationController, :create
  end

  scope "/", PrikkeWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{PrikkeWeb.UserAuth, :ensure_authenticated}],
      session: {__MODULE__, :live_session_data, []} do
      live "/dashboard", DashboardLive

      live "/tasks", TaskLive.Index, :index
      live "/tasks/new", TaskLive.New, :new
      live "/tasks/:id", TaskLive.Show, :show
      live "/tasks/:id/edit", TaskLive.Edit, :edit
      live "/tasks/:task_id/executions/:id", TaskLive.ExecutionShow, :show

      live "/monitors", MonitorLive.Index, :index
      live "/monitors/new", MonitorLive.New, :new
      live "/monitors/:id", MonitorLive.Show, :show
      live "/monitors/:id/edit", MonitorLive.Edit, :edit

      live "/endpoints", EndpointLive.Index, :index
      live "/endpoints/new", EndpointLive.New, :new
      live "/endpoints/:id", EndpointLive.Show, :show
      live "/endpoints/:id/edit", EndpointLive.Edit, :edit
      live "/endpoints/:endpoint_id/events/:event_id", EndpointLive.EventShow, :show

      live "/status-page", StatusLive.Index, :index
    end

    get "/users/settings", UserSettingsController, :edit
    put "/users/settings", UserSettingsController, :update
    get "/users/settings/confirm-email/:token", UserSettingsController, :confirm_email

    # Organizations
    get "/organizations", OrganizationController, :index
    get "/organizations/new", OrganizationController, :new
    post "/organizations", OrganizationController, :create
    post "/organizations/:id/switch", OrganizationController, :switch
    get "/organizations/settings", OrganizationController, :edit
    put "/organizations/settings", OrganizationController, :update
    get "/organizations/members", OrganizationController, :members
    put "/organizations/members/:id/role", OrganizationController, :update_member_role
    get "/organizations/notifications", OrganizationController, :notifications
    put "/organizations/notifications", OrganizationController, :update_notifications
    post "/organizations/upgrade", OrganizationController, :upgrade
    post "/organizations/switch-to-yearly", OrganizationController, :switch_to_yearly
    post "/organizations/billing-portal", OrganizationController, :billing_portal
    post "/organizations/cancel-subscription", OrganizationController, :cancel_subscription
    get "/organizations/api-keys", OrganizationController, :api_keys
    post "/organizations/api-keys", OrganizationController, :create_api_key
    delete "/organizations/api-keys/:id", OrganizationController, :delete_api_key

    post "/organizations/webhook-secret/regenerate",
         OrganizationController,
         :regenerate_webhook_secret

    get "/organizations/audit", OrganizationController, :audit

    # Invites (authenticated)
    get "/invites", InviteController, :index
    post "/invites", InviteController, :create
    post "/invites/:id/accept-direct", InviteController, :accept_direct
    delete "/invites/:id", InviteController, :delete
  end

  # Superadmin routes - requires superadmin role
  scope "/", PrikkeWeb do
    pipe_through [:browser, :require_authenticated_user, PrikkeWeb.Plugs.RequireSuperadmin]

    live_session :require_superadmin,
      on_mount: [{PrikkeWeb.UserAuth, :ensure_authenticated}],
      session: {__MODULE__, :live_session_data, []} do
      live "/superadmin", SuperadminLive, :index
    end
  end

  # Error tracker and LiveDashboard (superadmin only)
  scope "/" do
    pipe_through [:browser, :require_authenticated_user, PrikkeWeb.Plugs.RequireSuperadmin]

    import Phoenix.LiveDashboard.Router

    live_dashboard "/live-dashboard",
      metrics: PrikkeWeb.Telemetry,
      ecto_repos: [Prikke.Repo],
      live_session_name: :superadmin_live_dashboard

    import ErrorTracker.Web.Router
    error_tracker_dashboard("/errors")
  end

  # Invites (public - for viewing/accepting invites)
  scope "/", PrikkeWeb do
    pipe_through [:browser]

    get "/invites/:token", InviteController, :show
    post "/invites/:token/accept", InviteController, :accept
  end

  scope "/", PrikkeWeb do
    pipe_through [:browser]

    get "/users/log-in", UserSessionController, :new
    get "/users/log-in/:token", UserSessionController, :confirm
    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  @doc """
  Extracts session data for LiveView.
  """
  def live_session_data(conn) do
    %{
      "user_token" => Plug.Conn.get_session(conn, :user_token),
      "current_organization_id" => Plug.Conn.get_session(conn, :current_organization_id)
    }
  end
end
