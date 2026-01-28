# Prikke Implementation Progress

## Current Status: Phase 1 - Complete, Deploying to Koyeb

### What's Done

#### Local Development Environment
- Erlang 28.3 installed via asdf
- Elixir 1.19.5-otp-28 installed via asdf
- Phoenix 1.8.3 installed
- PostgreSQL 18 running via Docker Compose

#### Phoenix App (`/app`)
- Created with `Prikke`/`PrikkeWeb` modules
- UUID primary keys configured
- Health check endpoint at `/health`
- Dependencies added: crontab, tz, bypass, mox, req
- Release scripts generated (`bin/server`, `bin/migrate`)
- Landing page migrated from Bun to Phoenix
- Documentation pages (API, cron, webhooks, getting started, use cases)
- Custom branded 404 and 500 error pages

#### Koyeb Deployment
- Dockerfile using `hexpm/elixir:1.19.5-erlang-28.3.1-alpine-3.23.3`
- Build order fixed: `mix compile` before `mix assets.deploy`
- SSL enabled for database connection
- force_ssl disabled (Koyeb handles SSL termination)

### Koyeb Configuration
```
GitHub repo: gautema/prikke
Root directory: app
Builder: Dockerfile
Port: 8000
Health check: /health

Environment variables needed:
- DATABASE_URL (from Koyeb managed Postgres)
- SECRET_KEY_BASE=ShPV82PMvUep1obgsdOyPE9r+UwV7lWcViOscZ9MyNKfODVOQc3PgTz/nyAEDWaV
- PHX_HOST=prikke.whitenoise.no
```

### Local Development Commands
```bash
# Start PostgreSQL
cd app && docker compose up -d

# Start Phoenix server
cd app && mix phx.server
# Visit http://localhost:4000

# Run tests (ALWAYS do this before committing!)
cd app && mix compile && mix test

# Interactive console
cd app && iex -S mix
```

### Files Changed/Created
```
.tool-versions              # erlang 28.3, elixir 1.19.5-otp-28
app/
├── Dockerfile              # Production build (Elixir 1.19.5 + Erlang 28.3.1)
├── docker-compose.yml      # Local PostgreSQL 18
├── config/
│   ├── runtime.exs         # SSL enabled for prod database
│   └── prod.exs            # force_ssl disabled (Koyeb handles it)
├── lib/app_web/
│   ├── router.ex           # Routes: /health, /docs/*, /use-cases
│   └── controllers/
│       ├── health_controller.ex  # Database connectivity check
│       ├── page_html/
│       │   └── home.html.heex    # Landing page
│       ├── docs_controller.ex    # Docs routes
│       ├── docs_html.ex          # Docs layout component
│       ├── docs_html/            # Doc templates
│       │   ├── index.html.heex
│       │   ├── api.html.heex
│       │   ├── cron.html.heex
│       │   ├── webhooks.html.heex
│       │   ├── getting_started.html.heex
│       │   └── use_cases.html.heex
│       ├── error_html.ex         # Error page module
│       └── error_html/           # Custom error pages
│           ├── 404.html.heex
│           └── 500.html.heex
└── rel/overlays/bin/
    └── server              # Runs migrations then starts app
```

### Next Steps When Resuming

#### If Koyeb deploy succeeded:
1. Visit the app URL to verify it's running
2. Check `/health` endpoint returns `{"status":"ok","database":"connected"}`
3. Continue to Phase 2: Authentication & Organizations

#### If Koyeb deploy failed:
1. Check Koyeb logs for the specific error
2. Common issues:
   - Database connection: verify DATABASE_URL is correct
   - SSL issues: may need to adjust ssl_opts
   - Missing env vars: ensure SECRET_KEY_BASE and PHX_HOST are set

#### Phase 2: Authentication & Organizations
```bash
cd app
mix phx.gen.auth Accounts User users
mix ecto.migrate
```

Then create:
- Organizations schema (name, slug, tier)
- Memberships schema (user, org, role)
- API keys schema (org, key_id, key_hash)

### Architecture Reference
```
Production:
  Koyeb Container (Frankfurt) → Koyeb Managed Postgres

Local Dev:
  mix phx.server → Docker PostgreSQL 18
```

### Future Enhancements (Noted)
- **Swagger/OpenAPI docs** - Generate API documentation from code (Phase 9+)

### URL Configuration
- App URL: `prikke.whitenoise.no`
- API URL: `api.prikke.whitenoise.no`

### Important Development Notes
- **ALWAYS compile and run tests before committing**: `mix compile && mix test`
- **HEEx template escaping**: Use HTML entities `&#123;` and `&#125;` for curly braces in code blocks

---
Last updated: 2026-01-28
