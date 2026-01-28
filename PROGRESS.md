# Prikke Implementation Progress

## Current Status: Phase 1 - Complete, Deploying to Koyeb

### What's Done

#### Local Development Environment
- ✅ Erlang 28.3 installed via asdf
- ✅ Elixir 1.19.5-otp-28 installed via asdf
- ✅ Phoenix 1.8.3 installed
- ✅ PostgreSQL 18 running via Docker Compose

#### Phoenix App (`/app`)
- ✅ Created with `Prikke`/`PrikkeWeb` modules
- ✅ UUID primary keys configured
- ✅ Health check endpoint at `/health`
- ✅ Dependencies added: crontab, tz, bypass, mox
- ✅ Release scripts generated (`bin/server`, `bin/migrate`)

#### Koyeb Deployment
- ✅ Dockerfile using `hexpm/elixir:1.19.5-erlang-28.3.1-alpine-3.23.3`
- ✅ Build order fixed: `mix compile` before `mix assets.deploy`
- ✅ SSL enabled for database connection
- ⏳ **Waiting for deploy to complete** - last push enabled SSL

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
- PHX_HOST=<your-app>.koyeb.app
```

### Recent Commits
1. `803e2d1` - Add Phoenix app with Elixir 1.19.5
2. `524b8e4` - Fix Dockerfile: compile before assets.deploy
3. `ddf91ad` - Use Erlang 28.3.1 in Docker build
4. `53fc202` - Enable SSL for production database connection

### Local Development Commands
```bash
# Start PostgreSQL
cd app && docker compose up -d

# Start Phoenix server
cd app && mix phx.server
# Visit http://localhost:4000

# Run tests
cd app && mix test

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
│   └── prod.exs            # Force SSL, exclude health check
├── lib/app_web/
│   ├── router.ex           # Added /health endpoint
│   └── controllers/
│       └── health_controller.ex  # Database connectivity check
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

---
Last updated: 2026-01-28
