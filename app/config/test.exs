import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :argon2_elixir,
  t_cost: 1,
  m_cost: 8

# CI mode - skip database for Docker builds
config :app, :ci_mode, System.get_env("CI") == "true"

# Don't auto-start scheduler in tests (tests start it manually with test_mode: true)
config :app, :start_scheduler, false

# Higher rate limits to not interfere with other tests
# Rate limit tests override these via ETS manipulation
config :app, PrikkeWeb.RateLimit,
  limit_per_minute: 1000,
  limit_per_hour: 5000

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :app, Prikke.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "app_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :app, PrikkeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "6xDQ1hyXX/mkEOdxpRd4FelOTn8fqUxmiew6VJczHzBZ4P3DoLVAx7BYsCCIlFdf",
  server: false

# In test we don't send emails
config :app, Prikke.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Suppress all logs during test
config :logger, level: :none

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Configure Creem payments (test mode - Bypass will mock HTTP)
config :app, Prikke.Billing.Creem,
  api_key: "test_api_key",
  webhook_secret: "test_webhook_secret",
  product_id: "prod_test_123",
  base_url: "http://localhost:0"
