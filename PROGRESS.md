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
- [x] **Member limits enforcement** (Free: 2 members, Pro: unlimited)

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
- [x] **Tier limits enforcement**
  - Free: max 5 jobs, hourly minimum interval
  - Pro: unlimited jobs, per-minute intervals
  - Enforced on create and update
- [ ] **Executions schema** - Next up
- [ ] Executions context

### Phase 4: Job Execution Engine (Not Started)
- [ ] Scheduler GenServer (ticks every 60s, advisory lock)
- [ ] Worker Pool Manager (scales 2-20 workers)
- [ ] Worker GenServer (claims with SKIP LOCKED)
- [ ] HTTP Executor (Req library)
- [ ] **Monthly execution limits** (Free: 5k/mo, Pro: 250k/mo)

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
- [x] Branded HTML email templates (logo, emerald button, clean layout)
- [x] Email deliverability (noreply@whitenoise.no, SPF/DKIM)
- [x] **Notification settings UI** (org settings → Notifications tab)
  - Enable/disable failure notifications
  - Custom notification email
  - Webhook URL (Slack/Discord auto-detect ready)
- [ ] Notification worker (on job failure) - uses settings above
- [ ] Slack/Discord payload formatting

### Phase 8: Billing (MVP Approach)
- [x] Manual upgrade flow (user clicks upgrade → tier changes → "sales will contact you" message)
- [ ] Usage tracking (monthly executions) - enforced in Phase 4
- [ ] Lemon Squeezy integration (post-MVP, when ready to charge)

### Phase 9: Monitoring & Alerting (Not Started)
- [ ] Application error tracking (Sentry or AppSignal)
- [ ] Performance monitoring (response times, queue depth)
- [ ] Infrastructure alerts (high CPU, memory, disk)
- [ ] Public status page for Prikke itself
- [ ] Uptime monitoring (external ping service)
- [ ] Alert channels (email, Slack/Discord webhook)
- [ ] Dashboard for system health metrics

---

## Tier Limits

| | Free | Pro |
|---|------|-----|
| **Jobs** | 5 | Unlimited |
| **Requests** | 5k/mo | 250k/mo |
| **Min interval** | Hourly | 1 minute |
| **History** | 7 days | 30 days |
| **Team members** | 2 | Unlimited |

**Currently enforced:**
- [x] Max jobs per organization
- [x] Minimum cron interval
- [x] Max team members per organization (including pending invites)
- [ ] Monthly execution limit (needs executions table)
- [ ] History retention (needs executions table)

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
- **Check monthly execution limit before scheduling**

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
│   ├── user_notifier.ex      # Branded HTML emails
│   ├── organization.ex
│   ├── membership.ex
│   ├── organization_invite.ex
│   └── api_key.ex
├── accounts.ex
├── jobs/
│   └── job.ex
├── jobs.ex                    # Includes tier limit enforcement
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
│   ├── error_html/
│   │   ├── 403.html.heex
│   │   ├── 404.html.heex
│   │   └── 500.html.heex
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
mix test                     # Run tests (148 passing)
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
- PHX_HOST=prikke.whitenoise.no (without https://)
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

- **158 tests passing**
- Accounts: user auth, organizations, memberships, invites, API keys
- Jobs: CRUD, validations, cron parsing, tier limits
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

1. **No actual job execution** - Scheduler and workers not built yet
2. **Dashboard stats are placeholders** - Need executions table to show real data
3. **No API endpoints** - Only LiveView UI currently
4. **Monthly execution limits** - Enforce when scheduler is built (Free: 5k/mo, Pro: 250k/mo)

---

## Recently Completed

- [x] Manual upgrade to Pro (click to upgrade, sales contacts user)
- [x] Notification settings (org settings → Notifications tab)
- [x] Team member limits for organizations (Free: 2, Pro: unlimited)
- [x] Tier limits for jobs (max count, min interval)
- [x] Branded HTML email templates
- [x] Email deliverability (noreply@whitenoise.no)
- [x] Session cookie secure flag for HTTPS
- [x] 403 error page
- [x] PHX_HOST protocol stripping safeguard
