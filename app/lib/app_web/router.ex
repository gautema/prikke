defmodule PrikkeWeb.Router do
  use PrikkeWeb, :router

  import PrikkeWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PrikkeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
    plug :fetch_current_organization
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

      live "/jobs", JobLive.Index, :index
      live "/jobs/new", JobLive.New, :new
      live "/jobs/:id", JobLive.Show, :show
      live "/jobs/:id/edit", JobLive.Edit, :edit
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

    # Invites (authenticated)
    get "/invites", InviteController, :index
    post "/invites", InviteController, :create
    post "/invites/:id/accept-direct", InviteController, :accept_direct
    delete "/invites/:id", InviteController, :delete
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
