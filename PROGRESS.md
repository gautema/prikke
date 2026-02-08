# Prikke Implementation Progress

## Current Status: MVP Complete

Last updated: 2026-02-06

---

## What's Done

### Phase 1: Project Setup (Complete)
- [x] Phoenix 1.8.3 with Elixir 1.19.5, Erlang 28.3
- [x] PostgreSQL 18 via Docker Compose
- [x] UUID primary keys throughout
- [x] Health check endpoint `/health`
- [x] Dockerfile for production deployment
- [x] Landing page with pricing section
- [x] Documentation pages (API, Cron, Webhooks, Monitors, Getting Started)
- [x] Deployed to Hetzner VPS via Kamal

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

### Phase 3: Core Domain (Complete)
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
- [x] **Executions schema**
  - status (pending, running, success, failed, timeout)
  - scheduled_for, started_at, finished_at
  - status_code, duration_ms, response_body, error_message
  - Indexes for job lookup and pending status
- [x] **Executions context**
  - create_execution, claim_next_execution (FOR UPDATE SKIP LOCKED)
  - complete_execution, fail_execution, timeout_execution
  - Stats functions (job, org, monthly counts)
  - Cleanup function for retention policy

### Phase 4: Job Execution Engine (Complete)
- [x] Scheduler GenServer
  - Ticks every 10 seconds for timely job execution
  - Advisory lock for leader election (only one node schedules)
  - Finds due jobs via `next_run_at` field
  - Creates pending executions
  - Advances `next_run_at` for cron jobs
  - Enforces monthly execution limits
- [x] Worker Pool Manager (scales 2-20 workers)
  - Checks queue depth every 5 seconds
  - Spawns workers when queue > current workers
  - Workers self-terminate after 5 min idle
- [x] Worker GenServer (claims with SKIP LOCKED)
  - Claims pending executions with FOR UPDATE SKIP LOCKED (in transaction)
  - Priority: Pro tier first, minute crons before hourly/daily
  - Self-terminates after max idle polls
  - Graceful shutdown: finishes current request before exiting (60s timeout)
- [x] Stale execution recovery
  - Cleanup runs hourly to find "running" executions stuck >5 min
  - Marks them as failed (worker crash/restart recovery)
- [x] HTTP Executor (Req library)
  - Respects job.timeout_ms
  - Handles success (2xx), failure (non-2xx), and timeouts
  - Retries one-time jobs with exponential backoff
  - Truncates large response bodies
- [x] Cleanup GenServer
  - Runs daily at 3 AM UTC
  - Advisory lock for clustering (only one node cleans)
  - Deletes executions older than retention period
  - Deletes completed one-time jobs older than retention period
  - Tier-based retention: Free 7 days, Pro 30 days

### Phase 5: REST API (Complete)
- [x] API routes for jobs CRUD (GET, POST, PUT, DELETE /api/jobs)
- [x] Declarative sync endpoint (`PUT /api/sync`)
- [x] Trigger endpoint (`POST /api/jobs/:id/trigger`)
- [x] Execution history endpoint (`GET /api/jobs/:id/executions`)
- [x] OpenAPI spec at `/api/openapi` (OpenApiSpex)

### Phase 6: Dashboard (Complete)
- [x] Basic dashboard with stats cards
- [x] Jobs list with real-time updates
- [x] Job detail page
- [x] Create/edit job forms
- [x] Footer component (app + marketing variants)
- [x] Real execution stats (today's runs, success rate)
- [x] Recent executions list on dashboard
- [x] Execution history on job detail page (clickable rows)
- [x] 24-hour stats on job detail (total, success, failed, avg duration)
- [x] Execution detail page (`/jobs/:job_id/executions/:id`)
  - Shows timing, request details, response body, metadata
  - Color-coded status codes

### Phase 7: Notifications (Complete)
- [x] Mailjet configured for production email
- [x] Configurable from_email/from_name
- [x] Branded HTML email templates (logo, emerald button, clean layout)
- [x] Email deliverability (noreply@whitenoise.no, SPF/DKIM)
- [x] **Notification settings UI** (org settings → Notifications tab)
  - Enable/disable failure notifications
  - Custom notification email
  - Webhook URL (Slack/Discord auto-detect ready)
- [x] **Notification worker** (on job failure)
  - Async via Task.Supervisor (non-blocking)
  - Sends email to notification_email
  - Sends POST to notification_webhook_url
- [x] **Slack/Discord payload formatting**
  - Auto-detects `hooks.slack.com` and `discord.com/api/webhooks`
  - Formats messages with appropriate markdown (Slack: `:x:`, Discord: `❌`)
  - Generic JSON payload for other webhooks
- [x] **Recovery notifications**
  - Email + webhook when a job succeeds after a failure streak
  - Configurable toggle per organization (default: enabled)
  - Green "Job Recovered" email template
  - Slack/Discord/generic webhook payloads with `job.recovered` event

### Phase 7b: Cron Monitoring (Complete)
- [x] **Heartbeat / Dead Man's Switch monitoring** (Cronitor/Dead Man's Snitch style)
  - Monitors expect periodic HTTP pings from external cron jobs
  - Alert if ping doesn't arrive within expected window + grace period
  - Recovery notifications when pings resume after downtime
- [x] Monitor schema with ping tokens (`pm_` prefix), schedule types (cron/interval)
- [x] MonitorPing schema for ping history
- [x] Monitors context (CRUD, tier limits: Free 3, Pro unlimited)
- [x] Public ping endpoint (`GET/POST /ping/:token`) — no auth, token IS the auth
- [x] MonitorChecker GenServer — 60s tick, advisory lock for clustering
  - Detects overdue monitors (expected + grace < now)
  - Marks down, sends failure notifications
- [x] Monitor notifications (email + webhook for down/recovery)
  - Reuses org's existing notification channels
- [x] LiveView pages (index, show, new, edit)
  - Status dots (green=up, red=down, grey=new, yellow=paused)
  - Ping URL with copy button and cURL example
  - Recent pings history
- [x] Dashboard monitors summary card (total count, down count)
- [x] Monitor ping cleanup (30-day retention via Cleanup GenServer)
- [x] 44 tests covering context, checker, controller, LiveView

### Phase 8: Billing (MVP Approach)
- [x] Manual upgrade flow (user clicks upgrade → tier changes → "sales will contact you" message)
- [ ] Usage tracking (monthly executions) - enforced in Phase 4
- [ ] Lemon Squeezy integration (post-MVP, when ready to charge)

### Phase 9: Monitoring & Alerting (Partial)
- [x] **Admin email notifications** (via `ADMIN_EMAIL` env var)
  - New user signup notification
  - Pro upgrade notification
  - Works in dev (Swoosh mailbox) and production (Mailjet)
- [x] **Server monitoring** - CPU, memory, request metrics, logs
- [x] Application error tracking (Elixir ErrorTracker)
- [ ] Performance monitoring (response times, queue depth)
- [ ] Infrastructure alerts (high CPU, memory, disk)
- [x] **Public status page for Prikke itself** (`/status`)
  - StatusMonitor GenServer checks every 60 seconds
  - Monitors scheduler, workers, and API components
  - 3 rows in status_checks table (one per component, upsert pattern)
  - Automatic incident creation when components go down
  - Automatic incident resolution when components recover
  - Shows overall status, component health, active & past incidents
- [x] Uptime monitoring (status page + health checks sufficient)
- [ ] Alert channels (email, Slack/Discord webhook)
- [ ] Dashboard for system health metrics

---

## Tier Limits

| | Free | Pro |
|---|------|-----|
| **Jobs** | Unlimited | Unlimited |
| **Monitors** | Unlimited | Unlimited |
| **Requests** | 5k/mo | 250k/mo |
| **Min interval** | Hourly | 1 minute |
| **History** | 7 days | 30 days |
| **Team members** | 2 | Unlimited |

**Currently enforced:**
- [x] Max jobs per organization
- [x] Minimum cron interval
- [x] Max team members per organization (including pending invites)
- [x] History retention (Cleanup GenServer deletes old data daily)
- [x] Monthly execution limit (scheduler skips jobs when limit reached, dashboard shows usage)

---

## Planned

See [ROADMAP.md](ROADMAP.md) for the full feature roadmap.

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
├── executions/
│   └── execution.ex
├── executions.ex              # Claim with SKIP LOCKED, stats
├── status/
│   ├── status_check.ex        # Component health status
│   └── incident.ex            # Incident tracking
├── status.ex                  # Status context (upsert, incidents)
├── scheduler.ex               # Creates executions for due jobs
├── worker.ex                  # Job executor (HTTP requests)
├── worker_pool.ex             # Scales workers based on queue
├── worker_supervisor.ex       # DynamicSupervisor for workers
├── monitors/
│   ├── monitor.ex             # Monitor schema (heartbeat monitoring)
│   └── monitor_ping.ex        # MonitorPing schema
├── monitors.ex                # Monitors context (CRUD, pings, overdue)
├── monitor_checker.ex         # Overdue monitor detection GenServer
├── cleanup.ex                 # Daily cleanup of old data
├── notifications.ex           # Email and webhook alerts (jobs + monitors)
├── status_monitor.ex          # Health check GenServer
├── analytics/
│   └── pageview.ex            # Pageview tracking schema
├── analytics.ex               # Pageview analytics context
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
│   ├── status_controller.ex    # Public status page
│   ├── status_html.ex          # Status page helpers
│   ├── status_html/
│   │   └── index.html.heex     # Status page template
│   ├── error_html/
│   │   ├── 403.html.heex
│   │   ├── 404.html.heex
│   │   └── 500.html.heex
│   ├── ping_controller.ex     # Public ping endpoint (/ping/:token)
│   ├── user_*.ex               # Auth controllers
│   └── organization_controller.ex
├── live/
│   ├── dashboard_live.ex
│   ├── monitor_live/
│   │   ├── index.ex
│   │   ├── show.ex
│   │   ├── new.ex
│   │   └── edit.ex
│   └── job_live/
│       ├── index.ex
│       ├── show.ex
│       ├── new.ex
│       └── edit.ex
├── plugs/
│   ├── api_auth.ex
│   ├── rate_limit.ex           # API rate limiting (PlugAttack)
│   ├── require_superadmin.ex   # Superadmin route protection
│   └── track_pageview.ex       # Pageview tracking
├── live/
│   ├── superadmin_live.ex      # Platform-wide dashboard
│   └── ...
└── router.ex
```

---

## Environment & Deployment

### Local Development
```bash
cd app
docker compose up -d          # Start PostgreSQL
mix setup                     # Install deps, create DB, migrate
mix phx.server                # Start server at localhost:4000
mix test                      # Run tests
```

### Production (Hetzner VPS + Kamal)
```
GitHub repo: gautema/prikke
Root directory: app
Builder: Dockerfile
Deployment: Kamal (zero-downtime)
Region: Germany (Hetzner)

Environment variables:
- DATABASE_URL (self-hosted Postgres 18)
- SECRET_KEY_BASE
- PHX_HOST=runlater.eu
- MAILJET_API_KEY
- MAILJET_SECRET_KEY
- ADMIN_EMAIL (optional, for signup/upgrade notifications)
```

### URLs
- Production: https://runlater.eu
- Status: https://runlater.eu/status
- Register: https://runlater.eu/users/register
- Dashboard: https://runlater.eu/dashboard
- Jobs: https://runlater.eu/jobs
- Monitors: https://runlater.eu/monitors
- API Docs: https://runlater.eu/docs/api
- Swagger UI: https://runlater.eu/api/v1/docs

---

## Test Coverage

- **568 tests passing**
- Accounts: user auth, organizations, memberships, invites, API keys
- Jobs: CRUD, validations, cron parsing, tier limits
- Executions: creation, claiming, completion, stats
- Notifications: email and webhook delivery (jobs + monitors)
- Status: health checks, incidents, status page
- Monitors: CRUD, tier limits, ping handling, overdue detection, checker
- API Auth Plug: bearer token validation
- LiveView: basic rendering tests (jobs + monitors)

---

## Dependencies Added

```elixir
{:crontab, "~> 1.1"},      # Cron expression parsing
{:req, "~> 0.5"},          # HTTP client (for job execution)
{:plug_attack, "~> 0.4"},  # Rate limiting
```

---

## Known Issues / TODOs

_None currently — error tracking (Elixir ErrorTracker) and uptime monitoring (status page) are in place._

---

## Recently Completed

- [x] **Form validation feedback** - Added `phx-feedback-for` to all input components in core_components.ex for proper real-time validation display
- [x] **Queue page validation** - Implemented schemaless Ecto changeset for URL validation on `/queue` form
- [x] **URL whitespace trimming** - URLs are now trimmed before validation to prevent "invalid URL" errors from accidental whitespace
- [x] **One-time job datetime fix** - Server-side default for scheduled_at when switching to "once" schedule type (no more "can't be blank" errors)
- [x] **Landing page tagline** - Updated "Set it and sleep" to "Set it and sleep well"
- [x] **Rebrand to Runlater** - Changed from Cronly to Runlater (runlater.eu)
  - All branding, emails, headers (X-Runlater-*), cookies updated
  - Deployed to Hetzner via Kamal
- [x] **API Rate Limiting** - PlugAttack-based IP throttling
  - 300 requests/minute per IP
  - 5000 requests/hour per IP
  - Returns 429 with JSON error when exceeded
  - Configurable limits via app config
- [x] **Monthly Limit Notifications** - Email alerts for execution limits
  - Warning at 80%: "Approaching monthly limit"
  - Alert at 100%: "Monthly limit reached, jobs will be skipped"
  - Tier-appropriate messaging (free: upgrade, pro: contact us)
  - Tracked to avoid spam (once per threshold per month)
- [x] **Landing Page Updates** - Focused on deferred jobs messaging
  - New headline: "Defer anything. We'll make sure it runs."
  - Problem section rewritten for async background tasks
  - Swagger UI linked from API docs page
- [x] **Superadmin Dashboard** (`/superadmin`) - Platform-wide analytics and monitoring
  - is_superadmin flag on users, set via migration for designated admins
  - RequireSuperadmin plug for route protection
  - Platform stats: total users, organizations, jobs, Pro customers
  - Execution stats: today, 7d, 30d, monthly with success/failed/missed breakdown
  - Execution trend chart (14-day visual)
  - Pageview tracking: anonymous session-based tracking with privacy (IP hashing)
  - Analytics: pageviews, unique visitors, top pages
  - Pro Organizations list with owner email and upgrade date
  - Recent activity: signups, jobs, active organizations
  - Auto-refresh every 30 seconds
- [x] **Pageview Analytics** - Custom analytics system
  - Pageview schema (path, session_id, referrer, user_agent, ip_hash, user_id)
  - TrackPageview plug runs on all browser GET requests
  - Async tracking (non-blocking)
  - Privacy-preserving IP hashing
- [x] **Retry button** - Retry failed/timeout/missed executions from the UI
- [x] **Smart failure notifications** - Only email on first failure (not repeated failures)
- [x] **Admin notifications** - Email alerts for new signups and Pro upgrades (`ADMIN_EMAIL` env var)
- [x] **Prominent enabled toggle** - Moved to top of job form with large toggle switch
- [x] **Authorization security fix** - `get_organization_for_user/2` verifies membership before accessing org data
- [x] **Execution status dots** - colored dots on jobs list and dashboard showing latest execution status
- [x] **UI improvements** - wider job forms, larger textareas for headers/body, full-width cron input
- [x] **Navigation improvements** - back to dashboard links throughout job pages
- [x] **Execution detail page** - view full request/response details for any execution
- [x] **Graceful shutdown** - workers finish current request during deploys (60s timeout)
- [x] **Stale execution recovery** - hourly cleanup of stuck "running" executions
- [x] **Scheduler tick 10s** - reduced from 60s to prevent jobs being marked as missed
- [x] **Accurate duration tracking** - uses monotonic clock instead of timestamps
- [x] **Claim race condition fix** - FOR UPDATE SKIP LOCKED now wrapped in transaction
- [x] **Public Status Page** (`/status`) - shows component health, incidents, auto-creates/resolves incidents
- [x] **StatusMonitor GenServer** - checks scheduler, workers, API every 60 seconds
- [x] **Notification Worker** - sends failure alerts via email and webhook (async via Task.Supervisor)
- [x] **Slack/Discord auto-detection** - formats webhook payloads appropriately
- [x] **Argon2id password hashing** - replaced bcrypt for better security
- [x] **Missed execution tracking** - detects scheduler downtime and logs missed jobs
- [x] **REST API** - Full CRUD for jobs, trigger, executions, declarative sync
- [x] **OpenAPI spec** - Auto-generated via OpenApiSpex at `/api/openapi`
- [x] **UUID v7** - Time-ordered UUIDs for better index performance
- [x] **Monthly execution limit visibility** - usage bar on dashboard and org settings, warnings at 80%/100%
- [x] **Cleanup GenServer** - deletes old executions and completed one-time jobs based on tier retention
- [x] **"Completed" status for one-time jobs** - shows in UI, hides toggle button
- [x] **Dashboard Stats** - real execution data (today's runs, success rate, recent executions)
- [x] **Job Execution History** - 24h stats and execution table on job detail page
- [x] **Worker Pool** - scales 2-20 workers based on queue depth
- [x] **Worker** - claims and executes jobs with HTTP, handles retries
- [x] **HTTP Execution** - full request/response handling with Req
- [x] Scheduler GenServer (ticks every 60s, advisory lock, creates pending executions)
- [x] Executions schema & context (claim with SKIP LOCKED, stats, monthly counts)
- [x] Manual upgrade to Pro (click to upgrade, sales contacts user)
- [x] Notification settings (org settings → Notifications tab)
- [x] **Job duplication (Clone)** - Clone button on job show page creates a copy with all settings
  - Copies name (with "(copy)" suffix), URL, method, headers, body, schedule, settings
  - One-time jobs with past scheduled_at adjusted to 1 hour from now
  - Respects tier limits (job count, interval restrictions)
- [x] **Recovery notifications** - Get notified when a job succeeds after a failure
  - Toggle in org notification settings (default: enabled)
  - Email + webhook delivery (reuses existing channels)
  - Only triggers on status change (failed → success)
- [x] Team member limits for organizations (Free: 2, Pro: unlimited)
- [x] Tier limits for jobs (max count, min interval)
- [x] Branded HTML email templates
- [x] Email deliverability (noreply@whitenoise.no)
- [x] Session cookie secure flag for HTTPS
- [x] 403 error page
- [x] PHX_HOST protocol stripping safeguard
- [x] **Webhook test button** — "Test URL" on job create/edit fires a test request and shows the response inline
- [x] **Response assertions** — Mark an execution as failed if the response doesn't match expected status code or body pattern
- [x] **Per-job and per-monitor notification muting** — Mute failure/recovery notifications for individual jobs and monitors
- [x] **429 Retry-After handling** — Auto-retry on 429 responses with backoff from Retry-After header
- [x] **Monitor sync API** — `/api/v1/sync` now supports monitors alongside jobs
- [x] **Dashboard overhaul** — Unified jobs/monitors panes with inline trend charts, aggregate uptime visualization, monthly usage bar
- [x] **Run history lines** — Per-job execution status visualization on jobs index page
- [x] **Monitor uptime lines** — Per-monitor daily uptime status on monitors index and show pages (7d free / 30d pro)
