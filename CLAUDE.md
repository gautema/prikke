# CLAUDE.md - Runlater Project Guide

## Product Overview

**Runlater** is async task infrastructure for Europe. Queue delayed tasks, schedule recurring jobs, receive inbound webhooks, and monitor everything. The domain is runlater.eu.

### Value Proposition
- One API for task queues, cron scheduling, inbound webhooks, and monitoring
- EU-hosted (GDPR-native, data never leaves Europe)
- No AI hype - just reliable task execution
- Competitor gap: Inngest and Trigger.dev pivoted to AI, leaving simple use cases underserved

### Target Customers
- EU SaaS startups needing GDPR compliance
- Developers who want simple cron without complexity
- Agencies managing multiple client projects
- Regulated industries (healthcare, finance, legal)

## Tech Stack

| Component | Technology | Rationale |
|-----------|------------|-----------|
| Backend | Elixir + Phoenix | Fault-tolerant, built for concurrent jobs |
| Jobs | GenServer pool + Postgres | Custom scheduler, no external dependencies |
| Database | PostgreSQL | FOR UPDATE SKIP LOCKED for job queue, advisory locks for clustering |
| Frontend | Phoenix LiveView + Tailwind | Real-time dashboard with minimal JS |
| HTTP Client | Req (uses Finch) | Modern, connection pooling |
| Auth | phx.gen.auth + API keys | Sessions for dashboard, API keys for programmatic access |
| Hosting | VPS + Kamal | Single server, full control, EU region |
| Database | PostgreSQL 18 (self-hosted) | Same server, managed via Kamal accessories |
| Payments | Manual (MVP) / Lemon Squeezy (future) | Manual upgrade + sales contact for MVP |
| Email | Mailjet | French company, good free tier |
| Domain + DNS | Porkbun | Cheap domains, free DNS hosting |

### Why Elixir?
- BEAM VM designed for systems that run forever
- Lightweight processes (millions concurrent)
- Fault tolerance built-in (supervisors)
- GenServer + Postgres handles job scheduling natively
- LiveView gives real-time UI for free
- Developer has 2 years Elixir experience

### Job Execution Architecture
No external job libraries - just GenServers and Postgres:

```
┌─────────────────────────────────────────────────────────────────────┐
│                              Overview                                │
│                                                                      │
│  ┌───────────┐   creates    ┌────────────┐   claimed by  ┌────────┐ │
│  │ Scheduler │ ──────────▶  │ Executions │ ◀──────────── │Workers │ │
│  │ (1 leader)│   pending    │  (queue)   │   SKIP LOCKED │ (2-20) │ │
│  └───────────┘              └────────────┘               └────────┘ │
│       │                                                       │     │
│       │ advisory lock                              HTTP requests    │
│       ▼                                                       ▼     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                        PostgreSQL                            │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

**Scheduler GenServer** (`lib/app/scheduler.ex`):
- Ticks every 10 seconds for timely job execution
- Uses Postgres advisory lock for leader election (only one node schedules)
- Finds jobs where `enabled = true AND next_run_at <= now`
- Creates pending executions and advances `next_run_at`
- Enforces monthly execution limits before scheduling

```elixir
# Scheduler flow:
1. Acquire advisory lock (pg_try_advisory_lock)
2. Query due jobs: SELECT * FROM jobs WHERE enabled AND next_run_at <= now
3. For each job:
   a. Check monthly limit (count_current_month_executions)
   b. Insert execution with status='pending', scheduled_for=next_run_at
   c. Update job: next_run_at = next_cron_time (or nil for one-time)
```

**PubSub Wake-up:**
- Scheduler subscribes to "scheduler" topic
- `Jobs.notify_scheduler/0` broadcasts `:wake` when job enabled/updated
- Reduces latency for one-time jobs (no 60s wait)

**Worker Pool (GenServer pool or Task.Supervisor):**
- Workers claim pending executions: `FOR UPDATE SKIP LOCKED`
- Execute HTTP request with Req
- Update execution status (success/failed/timeout)
- Handle retries for one-time jobs (re-insert with backoff delay)

**Postgres Features Used:**
- `FOR UPDATE SKIP LOCKED` - concurrent job claiming without conflicts
- `pg_try_advisory_lock` - non-blocking leader election for scheduler
- `pg_advisory_unlock` - release lock on scheduler shutdown

```elixir
# Claim next pending execution with priority
SELECT e.* FROM executions e
JOIN jobs j ON e.job_id = j.id
JOIN organizations o ON j.organization_id = o.id
WHERE e.status = 'pending' AND e.scheduled_for <= now()
ORDER BY
  o.tier DESC,            -- Pro customers first
  j.interval_minutes ASC, -- Minute crons before hourly/daily
  e.scheduled_for ASC     -- Oldest first within same priority
LIMIT 1
FOR UPDATE SKIP LOCKED
```

**Priority logic:**
- Pro tier jobs always run before Free tier
- Minute-interval crons are more time-sensitive than hourly/daily
- Within same priority: oldest (most overdue) first

**Adaptive Worker Pool:**
Workers scale based on queue depth - no thundering herd, no idle resources:

```elixir
# Pool Manager checks queue every 5 seconds:
# - queue_depth = count pending executions
# - active_workers = current worker count
# - target = min(max_workers, queue_depth)
# - spawn/terminate workers to match target

# Bounds:
# - min_workers: 2 (always ready)
# - max_workers: 20 (limit concurrent HTTP)
# - scale_up: spawn immediately when queue > workers
# - scale_down: let idle workers terminate after 30s no work
```

Using `DynamicSupervisor`:
- Spawn workers on demand with `start_child`
- Workers exit normally when no work found (after idle timeout)
- Supervisor handles crashes/restarts automatically
- Each worker: claim → execute → loop → exit if idle

Simple, no dependencies, full control.

## Features

### MVP (v1)
- [x] User registration and login (magic link auth)
- [x] Create/edit/delete scheduled jobs (LiveView UI)
- [x] Cron expressions + simple intervals (hourly, daily, weekly)
- [x] One-time scheduled jobs (run once at specific time)
- [x] HTTP GET/POST webhook delivery (scheduler + worker pool)
- [x] Custom headers and request body for webhooks
- [x] Execution history with status, duration, response
- [x] Project-level notifications (email + webhook URL, Slack/Discord auto-detection)
- [x] Public status page for Runlater itself
- [x] Basic dashboard

### v2
- [x] Job queues (on-demand via API + LiveView UI, immediate execution)
- [x] Team/organization support (orgs, memberships, invites)
- [x] Job duplication (clone button on job show page)
- [x] Recovery notifications (notify when job succeeds after failure)
- [x] API keys (org-scoped, hashed storage)
- [x] OpenAPI/Swagger docs (`/api/v1/docs`)
- [x] Webhook signatures (HMAC-SHA256)
- [x] Execution callbacks (POST results to a URL on completion)
- [x] Audit logging (user + API key actions)
- [x] HTTP uptime monitors with ping endpoints
- [ ] Per-job notification overrides
- [ ] Customer-facing status pages

### v3
- [ ] Workflows (multi-step jobs)
- [ ] Rate limiting per endpoint
- [ ] Cron monitoring (expect ping, alert if missing)
- [ ] Per-org worker fairness (limit each org to 1 concurrent worker so slow endpoints can't starve other orgs)

### Ops & Monitoring
- [x] Error tracking (ErrorTracker, built-in)
- [x] Performance monitoring (response times, queue depth, duration percentiles)
- [x] System health dashboard (superadmin with CPU, memory, disk, BEAM metrics)
- [x] Uptime monitoring (HTTP monitors with configurable intervals)
- [x] Email logging (email_logs table, superadmin view)
- [ ] Infrastructure alerts (external alerting)

## Database Schema (Core)

```sql
-- Users
create table users (
    id uuid primary key,
    email text unique not null,
    hashed_password text,            -- nullable for magic link only users
    confirmed_at timestamptz,
    inserted_at timestamptz not null,
    updated_at timestamptz not null
);

-- API Keys (organization-scoped)
create table api_keys (
    id uuid primary key,
    organization_id uuid references organizations(id) on delete cascade,
    created_by_id uuid references users(id),
    key_id text unique not null,      -- pk_live_xxx (public)
    key_hash text not null,           -- hashed secret
    name text,
    last_used_at timestamptz,
    inserted_at timestamptz not null
);

-- Organizations
create table organizations (
    id uuid primary key,
    name text not null,
    slug text unique not null,
    tier text default 'free',         -- 'free' or 'pro'
    inserted_at timestamptz not null,
    updated_at timestamptz not null
);

-- Memberships (users <-> organizations)
create table memberships (
    id uuid primary key,
    user_id uuid references users(id) on delete cascade,
    organization_id uuid references organizations(id) on delete cascade,
    role text default 'member',       -- 'owner', 'admin', 'member'
    inserted_at timestamptz not null,
    updated_at timestamptz not null
);

-- Jobs (organization-scoped scheduled jobs)
create table jobs (
    id uuid primary key,
    organization_id uuid references organizations(id) on delete cascade,
    name text not null,
    url text not null,
    method text default 'GET',
    headers jsonb default '{}',
    body text,
    schedule_type text not null,      -- 'cron' or 'once'
    cron_expression text,             -- for recurring jobs (null if once)
    interval_minutes integer,         -- computed from cron (1, 60, 1440, etc.) for priority
    scheduled_at timestamptz,         -- for one-time jobs (null if cron)
    timezone text default 'UTC',
    enabled boolean default true,
    timeout_ms integer default 30000,
    inserted_at timestamptz not null,
    updated_at timestamptz not null,

    constraint valid_schedule check (
        (schedule_type = 'cron' and cron_expression is not null) or
        (schedule_type = 'once' and scheduled_at is not null)
    )
);

-- Executions (job run history)
create table executions (
    id uuid primary key,
    job_id uuid references jobs(id) on delete cascade,
    started_at timestamptz not null,
    finished_at timestamptz,
    status text not null,             -- 'success', 'failed', 'timeout'
    status_code integer,
    duration_ms integer,
    response_body text,
    error_message text,
    attempt integer default 1,
    inserted_at timestamptz not null
);

create index executions_job_id_started_at_idx on executions(job_id, started_at desc);
create index jobs_organization_id_idx on jobs(organization_id);
create index jobs_enabled_idx on jobs(enabled) where enabled = true;
```

## Pricing Model

Two simple tiers to start:

| | Free | Pro |
|---|------|-----|
| **Price** | €0 | €29/mo |
| **Jobs** | 5 | Unlimited |
| **Requests** | 10k/mo | 1M/mo |
| **Min interval** | Hourly | 1 minute |
| **History** | 7 days | 30 days |
| **Team members** | 2 | Unlimited |
| **One-time jobs** | Yes | Yes |
| **Precision** | Minute | Minute |

Notes:
- Minute precision for all tiers (no second-level scheduling)
- Free tier math: 5 jobs × hourly × 30 days = 3,600 requests, so 10k is comfortable
- Team member limit includes pending invites
- Add more tiers later based on real usage patterns

### Technical Limits

| Limit | Value | Notes |
|-------|-------|-------|
| Request body | 256 KB | Max size of webhook payload sent to target |
| Response storage | 256 KB | Responses truncated in execution history |
| Timeout | 1s - 5min | Configurable per job (default: 30s) |
| Retry attempts | 0 - 10 | For one-time jobs only (default: 5) |

## Infrastructure

### Production Stack

```
┌─────────────────────────────────────────┐
│    Domain: runlater.eu                  │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│        VPS (EU) 🇪🇺                      │
│  ┌─────────────────────────────────┐    │
│  │  kamal-proxy (TLS termination)  │    │
│  └───────────────┬─────────────────┘    │
│                  │                       │
│  ┌───────────────▼─────────────────┐    │
│  │  Phoenix app container          │    │
│  │  (ghcr.io/gautema/runlater)     │    │
│  └───────────────┬─────────────────┘    │
│                  │                       │
│  ┌───────────────▼─────────────────┐    │
│  │  PostgreSQL 18 container        │    │
│  │  (Kamal accessory)              │    │
│  └─────────────────────────────────┘    │
└─────────────────────────────────────────┘
```

### Deployment with Kamal

Kamal is used for zero-downtime deployments. Config in `app/config/deploy.yml`.

```bash
# Deploy (from app/ directory)
cd app && kamal deploy

# Other useful commands
kamal app logs              # View app logs
kamal app exec -i 'bin/app remote'  # Remote IEx console
kamal accessory logs db     # View database logs
kamal rollback              # Rollback to previous version
```

**How it works:**
1. Builds Docker image on remote server (via SSH)
2. Pushes to GitHub Container Registry (ghcr.io)
3. Pulls image on production server
4. Starts new container, health checks pass
5. kamal-proxy routes traffic to new container
6. Old container is stopped and cleaned up

**Secrets:** Stored in `app/.kamal/secrets` (git-ignored). Contains:
- `KAMAL_REGISTRY_PASSWORD` - GitHub token for ghcr.io
- `SECRET_KEY_BASE` - Phoenix secret
- `DATABASE_URL` - Postgres connection string
- `POSTGRES_USER` / `POSTGRES_PASSWORD` - DB credentials
- `MAILJET_API_KEY` / `MAILJET_SECRET_KEY` - Email credentials

### Services Not Needed (Yet)
- Redis (Postgres handles job queue)
- SMS (email alerts are enough)
- Object storage (until log archival needed)
- CDN (static assets served from app)

## Payments

**MVP Approach (current):**
- Manual upgrade: user clicks "Upgrade to Pro" → tier changes immediately
- Flash message: "Our team will reach out to set up billing"
- Sales/founder contacts upgraded users manually
- No payment integration needed initially

**Post-MVP (when ready to charge):**
Using Lemon Squeezy (Merchant of Record):
- They are the seller, handle EU VAT
- No tax compliance headaches
- Higher fees (~5-8%) but worth the simplicity
- Simple checkout integration
- Webhook for subscription status

## Architecture

```
┌─────────────────────────────────────────────────┐
│              Phoenix LiveView                    │
│         (Dashboard, Job Management)              │
└─────────────────────┬───────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────┐
│              Phoenix API                         │
│      (REST endpoints for programmatic access)    │
└─────────────────────┬───────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────┐
│  Scheduler           Worker Pool                 │
│  ┌─────────────┐     ┌─────────────────────┐    │
│  │ GenServer   │     │ GenServer workers   │    │
│  │ ticks/min   │     │ claim + execute     │    │
│  │ (leader)    │     │ (SKIP LOCKED)       │    │
│  └─────────────┘     └─────────────────────┘    │
│       │                       │                  │
│       └───────────────────────┘                  │
│              advisory locks                      │
└─────────────────────┬───────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────┐
│               PostgreSQL                         │
│  (Users, Jobs, Executions - queue via SKIP LOCKED)│
└─────────────────────────────────────────────────┘
```

### Clustering
- Postgres SKIP LOCKED for job queue (no Redis)
- Multiple nodes can run, jobs won't duplicate
- Leader election via Postgres advisory locks

### Scaling Reference
| Jobs/minute | Nodes | Postgres |
|-------------|-------|----------|
| 1,000 | 1 | Basic |
| 10,000 | 2-3 | Basic |
| 100,000 | 5+ | Tune |

## Brand

- **Name:** Runlater
- **Tagline:** "Async tasks without the infrastructure."
- **Colors:** Slate 900 (#0f172a) + Emerald 500 (#10b981)
- **Font:** Inter
- **Logo:** Green dot + "runlater" wordmark
- **Domain:** runlater.eu

See `/brand/BRAND.md` for full guidelines.

## Development Commands

```bash
cd app

# Setup
mix setup                    # Install deps, create DB, migrate

# Start server
mix phx.server               # Runs at localhost:4000

# Interactive console
iex -S mix

# Run tests
mix test

# Database
mix ecto.create
mix ecto.migrate
mix ecto.reset
```

## Development Rules

**CRITICAL: All features must have unit tests:**
- Every new feature, module, or bug fix MUST include corresponding tests
- Tests prevent regressions and ensure code quality
- Failing code must NEVER be committed

**Testing guidelines:**
- **Unit tests**: Test individual functions and modules in isolation
  - Business logic (contexts like `Accounts`, `Jobs`, `Executions`)
  - Utility modules (like `WebhookSignature`, date formatting, etc.)
  - Schema validations and changesets
- **Integration tests**: Test controller actions and LiveViews
  - API endpoints (authentication, CRUD operations)
  - User flows (registration, login, job management)
- **Test location**: Tests go in `test/` mirroring the `lib/` structure
  - `lib/app/webhook_signature.ex` → `test/app/webhook_signature_test.exs`
  - `lib/app_web/controllers/api/job_controller.ex` → `test/app_web/controllers/api/job_controller_test.exs`
- **Test coverage expectations**:
  - All public functions should have tests
  - Edge cases and error conditions should be covered
  - Security-sensitive code (auth, signatures) needs thorough testing

**Pre-commit hook (enforces tests before commit):**
```bash
# One-time setup (already configured in this repo)
git config core.hooksPath .githooks
```

The pre-commit hook automatically runs `mix compile --warnings-as-errors` and `mix test` before each commit. If tests fail, the commit is blocked.

**HEEx Template Notes:**
- Curly braces `{` and `}` in code blocks (e.g., JSON examples) must be escaped
- Use HTML entities: `&#123;` for `{` and `&#125;` for `}`
- This applies to all `<pre><code>` blocks containing JSON or JavaScript

**Future Enhancement (Phase 9+):**
- Swagger/OpenAPI docs - Generate API documentation from code

## Project Structure

```
prikke/
├── CLAUDE.md              # This file
├── ROADMAP.md             # Feature roadmap & strategy
├── README.md
├── brand/
│   ├── BRAND.md           # Brand guidelines
│   ├── colors.css         # CSS variables
│   ├── favicon.svg
│   ├── logo.svg           # Light background
│   └── logo-dark.svg      # Dark background
└── app/                   # Phoenix application
    ├── Dockerfile         # Production build
    ├── docker-compose.yml # Local PostgreSQL 18
    ├── lib/
    │   ├── app/           # Business logic
    │   │   ├── accounts/  # Users, orgs, memberships, API keys
    │   │   ├── accounts.ex
    │   │   ├── jobs/      # Job schema
    │   │   ├── jobs.ex    # Jobs context with tier limits
    │   │   ├── mailer.ex
    │   │   └── repo.ex
    │   └── app_web/       # Web layer
    │       ├── components/
    │       │   ├── core_components.ex
    │       │   └── layouts/
    │       ├── controllers/
    │       │   ├── page_html/home.html.heex  # Landing page
    │       │   ├── docs_html/                # Documentation
    │       │   └── ...
    │       ├── live/
    │       │   ├── dashboard_live.ex
    │       │   └── job_live/
    │       ├── plugs/
    │       │   └── api_auth.ex
    │       └── router.ex
    └── test/
```

### Planned additions (not yet built)
```
lib/app/
├── scheduler/          # Cron scheduler GenServer
├── workers/            # Worker pool for job execution
└── executions/         # Execution history
```

## Key Decisions

1. **Elixir over Kotlin/.NET** - Best fit for concurrent job execution
2. **No Oban, custom GenServer pool** - Postgres SKIP LOCKED for queue, advisory locks for clustering, no dependencies
3. **No Redis** - Postgres handles everything, simpler infra
4. **Kamal on VPS** - Full control, simple deployment, EU-hosted server
5. **Lemon Squeezy over Stripe** - MoR handles EU VAT, simpler for solo founder
6. **Mailjet over Resend/Postmark** - French company, good free tier
7. **Two pricing tiers** - Simple: Free and Pro (€29/mo)
8. **API keys over OAuth** - Simpler for users, OAuth later if enterprise needs it
9. **Minute precision only** - No second-level scheduling (not needed, adds complexity)
10. **Retries: one-time only** - One-time jobs retry (5x exponential backoff), cron jobs don't (next scheduled run is the retry)
11. **Notifications: webhook-first** - Email (default) + webhook URL; auto-detect Slack/Discord URLs and format payloads accordingly
12. **Project-level notifications** - Not per-job (simpler, covers 90% of use cases)
13. **Status page** - Public status page for Runlater itself (builds trust); execution history IS user monitoring
14. **Job priority** - Pro tier before Free; minute-interval crons before hourly/daily; one-time jobs lowest priority
15. **Monthly limit counting** - Currently uses COUNT query (fine for MVP). Future: cache in ETS with 5-minute TTL, invalidate on execution completion

## Competitors

| Competitor | Status | Gap |
|------------|--------|-----|
| Inngest | Pivoted to AI | Simple use cases abandoned |
| Trigger.dev | Pivoted to AI | Same |
| QStash | Basic, US-based | No cron UI, not EU |
| Zeplo | UK, minimal | Very basic |

## Go-to-Market

1. Launch on runlater.eu
2. Free tier to get users
3. Dev communities (Reddit, HN, Twitter/X)
4. Content: "EU alternative to Inngest"
5. Target EU indie hackers, SaaS founders

## Timeline (Rough)

| Phase | Duration | Goal |
|-------|----------|------|
| MVP | 2 weeks | Working cron + webhooks |
| Beta | 1 month | 10-20 free users |
| Launch | Month 2-3 | Paid tiers live |
| Iterate | Ongoing | Based on feedback |
