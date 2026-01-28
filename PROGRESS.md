# Prikke Implementation Progress

## Current Status: Phase 3 - In Progress

Last updated: 2026-01-28

---

## What's Done

### Phase 1: Project Setup (Complete)
- [x] Phoenix 1.8.3 with Elixir 1.19.5, Erlang 28.3
- [x] PostgreSQL 18 via Docker Compose
- [x] UUID primary keys throughout
- [x] Health check endpoint `/health`
- [x] Dockerfile for Koyeb deployment
- [x] Landing page with pricing section
- [x] Documentation pages (API, Cron, Webhooks, Getting Started)
- [x] Deployed to Koyeb Frankfurt

### Phase 2: Authentication & Organizations (Complete)
- [x] User auth via `mix phx.gen.auth` (magic link)
- [x] Organizations with name, slug, tier
- [x] Memberships linking users to orgs (owner/admin/member roles)
- [x] Organization invites via email
- [x] Pending invites UI with accept/decline
- [x] Organization switcher in header
- [x] API Keys (`pk_live_xxx.sk_live_yyy` format)
- [x] API Auth Plug for bearer token authentication

### Phase 3: Core Domain (In Progress)
- [x] Jobs schema with validations
  - Organization-scoped
  - Cron expression validation (via `crontab` library)
  - One-time scheduled jobs support
  - URL validation, method, headers, body, timeout
  - `interval_minutes` computed from cron for priority
- [x] Jobs context with CRUD operations
- [x] Jobs UI (LiveView)
  - List page with toggle, edit, delete
  - Show page with job details
  - New job full page form
  - Edit job full page form
  - Real-time updates via PubSub
- [ ] **Executions schema** - Next up
- [ ] Executions context

### Phase 4: Job Execution Engine (Not Started)
- [ ] Scheduler GenServer (ticks every 60s, advisory lock)
- [ ] Worker Pool Manager (scales 2-20 workers)
- [ ] Worker GenServer (claims with SKIP LOCKED)
- [ ] HTTP Executor (Req library)

### Phase 5: REST API (Not Started)
- [ ] API routes for jobs CRUD
- [ ] Declarative sync endpoint (`PUT /api/sync`)
- [ ] Trigger endpoint (`POST /api/jobs/:id/trigger`)
- [ ] Execution history endpoint

### Phase 6: Dashboard (Partial)
- [x] Basic dashboard with stats cards
- [x] Jobs list with real-time updates
- [x] Job detail page
- [x] Create/edit job forms
- [x] Footer component (app + marketing variants)
- [ ] Real execution stats (today's runs, success rate)
- [ ] Recent executions list on dashboard
- [ ] Execution history on job detail page

### Phase 7: Notifications (Partial)
- [x] Mailjet configured for production email
- [x] Configurable from_email/from_name
- [ ] Notification worker (on job failure)
- [ ] Webhook notifications
- [ ] Slack/Discord auto-detection

### Phase 8: Billing (Not Started)
- [ ] Lemon Squeezy integration
- [ ] Usage tracking (monthly executions)
- [ ] Limit enforcement (jobs, requests)

---

## Immediate Next Steps

### 1. Executions Schema & Context
```elixir
schema "executions" do
  belongs_to :job, Job
  field :status, :string        # pending, running, success, failed, timeout
  field :scheduled_for, :utc_datetime
  field :started_at, :utc_datetime
  field :finished_at, :utc_datetime
  field :status_code, :integer
  field :duration_ms, :integer
  field :response_body, :string
  field :error_message, :string
  field :attempt, :integer, default: 1
  timestamps()
end
```

### 2. Scheduler GenServer
- Acquire advisory lock (only one node schedules)
- Tick every 60 seconds
- Query due jobs (cron: next_run <= now, once: scheduled_at <= now)
- Insert pending executions

### 3. Worker Pool
- DynamicSupervisor with 2-20 workers
- Workers claim executions: `FOR UPDATE SKIP LOCKED`
- Execute HTTP request with Req
- Update execution status
- Handle retries (one-time jobs only)

### 4. Dashboard Polish
- Show real stats from executions table
- Recent executions list
- Execution history on job detail

---

## File Structure (Current)

```
app/lib/app/
├── accounts/
│   ├── user.ex
│   ├── user_token.ex
│   ├── user_notifier.ex
│   ├── organization.ex
│   ├── membership.ex
│   ├── organization_invite.ex
│   └── api_key.ex
├── accounts.ex
├── jobs/
│   └── job.ex
├── jobs.ex
├── mailer.ex
└── repo.ex

app/lib/app_web/
├── components/
│   ├── core_components.ex      # Includes footer component
│   └── layouts/
│       ├── app.html.heex
│       └── root.html.heex
├── controllers/
│   ├── page_controller.ex
│   ├── page_html/
│   │   ├── home.html.heex
│   │   └── dashboard.html.heex
│   ├── docs_controller.ex
│   ├── user_*.ex               # Auth controllers
│   └── organization_controller.ex
├── live/
│   ├── dashboard_live.ex
│   └── job_live/
│       ├── index.ex
│       ├── show.ex
│       ├── new.ex
│       └── edit.ex
├── plugs/
│   └── api_auth.ex
└── router.ex
```

---

## Environment & Deployment

### Local Development
```bash
cd app
docker compose up -d          # Start PostgreSQL
mix setup                     # Install deps, create DB, migrate
mix phx.server               # Start server at localhost:4000
mix test                     # Run tests (142 passing)
```

### Koyeb Production
```
GitHub repo: gautema/prikke
Root directory: app
Builder: Dockerfile
Port: 8000
Health check: /health
Region: Frankfurt

Environment variables:
- DATABASE_URL (Koyeb managed Postgres)
- SECRET_KEY_BASE
- PHX_HOST=prikke.whitenoise.no
- MAILJET_API_KEY
- MAILJET_SECRET_KEY
```

### URLs
- Production: https://prikke.whitenoise.no
- Register: https://prikke.whitenoise.no/users/register
- Dashboard: https://prikke.whitenoise.no/dashboard
- Jobs: https://prikke.whitenoise.no/jobs

---

## Test Coverage

- **142 tests passing**
- Accounts: user auth, organizations, memberships, invites, API keys
- Jobs: CRUD, validations, cron parsing
- API Auth Plug: bearer token validation
- LiveView: basic rendering tests

---

## Dependencies Added

```elixir
{:crontab, "~> 1.1"},      # Cron expression parsing
{:req, "~> 0.5"},          # HTTP client (for job execution)
```

---

## Known Issues / TODOs

1. **Mailjet not configured in Koyeb** - Need to set MAILJET_API_KEY and MAILJET_SECRET_KEY
2. **No actual job execution** - Scheduler and workers not built yet
3. **Dashboard stats are placeholders** - Need executions table to show real data
4. **No API endpoints** - Only LiveView UI currently
