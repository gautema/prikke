# CLAUDE.md - Prikke Project Guide

## Product Overview

**Prikke** is a European-hosted background jobs and cron scheduling service. The name comes from the Norwegian expression "til punkt og prikke" (to the letter, precisely).

### Value Proposition
- Simple cron scheduling and webhook delivery
- EU-hosted (GDPR-native, data never leaves Europe)
- No AI hype - just reliable job execution
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
| Hosting | Koyeb (Frankfurt) | French company, managed containers, EU region |
| Database | Koyeb Managed Postgres | Same provider as compute, low latency |
| Payments | Lemon Squeezy | Merchant of Record, handles EU VAT |
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

**Scheduler GenServer:**
- Ticks every 60 seconds
- Queries jobs table for due cron/one-time jobs
- Inserts executions with `status = 'pending'`
- Uses Postgres advisory lock so only one node schedules in cluster

**Worker Pool (GenServer pool or Task.Supervisor):**
- Workers claim pending executions: `FOR UPDATE SKIP LOCKED`
- Execute HTTP request with Req
- Update execution status (success/failed/timeout)
- Handle retries for one-time jobs (re-insert with backoff delay)

**Postgres Features Used:**
- `FOR UPDATE SKIP LOCKED` - concurrent job claiming without conflicts
- `pg_advisory_lock` - leader election for scheduler
- `pg_notify` / LISTEN - optional: wake workers on new job

```elixir
# Claim next pending execution with priority
SELECT e.* FROM executions e
JOIN jobs j ON e.job_id = j.id
JOIN users u ON j.user_id = u.id
WHERE e.status = 'pending' AND e.scheduled_for <= now()
ORDER BY
  u.tier DESC,           -- Pro customers first
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
- [ ] User registration and login
- [ ] Create/edit/delete scheduled jobs
- [ ] Cron expressions + simple intervals (hourly, daily, weekly)
- [ ] One-time scheduled jobs (run once at specific time)
- [ ] HTTP GET/POST webhook delivery
- [ ] Custom headers and request body for webhooks
- [ ] Execution history with status, duration, response
- [ ] Project-level notifications (email + webhook URL)
- [ ] Public status page for Prikke itself
- [ ] Basic dashboard

### v2
- [ ] Job queues (on-demand via API, immediate execution)
- [ ] Team/organization support
- [ ] Per-job notification overrides
- [ ] Customer-facing status pages

### v3
- [ ] Workflows (multi-step jobs)
- [ ] Rate limiting per endpoint
- [ ] Cron monitoring (expect ping, alert if missing)

## Database Schema (Core)

```sql
-- Users
create table users (
    id uuid primary key,
    email text unique not null,
    hashed_password text not null,
    tier text default 'free',        -- 'free' or 'pro'
    confirmed_at timestamptz,
    inserted_at timestamptz not null,
    updated_at timestamptz not null
);

-- API Keys
create table api_keys (
    id uuid primary key,
    user_id uuid references users(id) on delete cascade,
    key_id text unique not null,      -- pk_live_xxx (public)
    key_hash text not null,           -- hashed secret
    name text,
    last_used_at timestamptz,
    inserted_at timestamptz not null
);

-- Jobs (user-defined scheduled jobs)
create table jobs (
    id uuid primary key,
    user_id uuid references users(id) on delete cascade,
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
    retry_attempts integer default 3,
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
create index jobs_user_id_idx on jobs(user_id);
create index jobs_enabled_idx on jobs(enabled) where enabled = true;
```

## Pricing Model

Two simple tiers to start:

| | Free | Pro |
|---|------|-----|
| **Price** | €0 | €29/mo |
| **Jobs** | 5 | Unlimited |
| **Requests** | 5k/mo | 250k/mo |
| **Min interval** | Hourly | 1 minute |
| **History** | 7 days | 30 days |
| **One-time jobs** | Yes | Yes |
| **Precision** | Minute | Minute |

Notes:
- Minute precision for all tiers (no second-level scheduling)
- Free tier math: 5 jobs × hourly × 30 days = 3,600 requests, so 5k is comfortable
- Add more tiers later based on real usage patterns

## Infrastructure

### Production Stack

```
┌─────────────────────────────────────────┐
│    Porkbun (domain + DNS)               │
│    prikke.dev or prikke.eu              │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│        Koyeb (Frankfurt) 🇫🇷            │
│  ┌─────────────────────────────────┐    │
│  │  Container: Bun (landing)       │    │
│  │  → later: Phoenix app           │    │
│  │  Small (1 vCPU, 1GB) - €10/mo   │    │
│  └───────────────┬─────────────────┘    │
│                  │ same network         │
│  ┌───────────────▼─────────────────┐    │
│  │  Managed Postgres               │    │
│  │  Starter (1GB) - €7/mo          │    │
│  └─────────────────────────────────┘    │
└─────────────────────────────────────────┘
```

### Monthly Costs

| Service | Provider | Price |
|---------|----------|-------|
| Domain | Porkbun | ~€10/yr |
| DNS | Porkbun | Free |
| Container | Koyeb Small 🇫🇷 | ~€10/mo |
| Database | Koyeb Postgres 🇫🇷 | ~€7/mo |
| Email | Mailjet 🇫🇷 | Free tier (6k/mo) |
| Payments | Lemon Squeezy | % of revenue |
| Monitoring | Better Stack | Free tier |
| **Total** | | **~€18/mo** |

### Why Koyeb?
- French company (EU data story)
- Container + Postgres on same network (low latency)
- No server management (push to deploy)
- Frankfurt region
- Simple pricing

### Deploy Flow
```bash
# Connect GitHub repo to Koyeb, auto-deploys on push
# Or manually push Docker image:
docker build -t prikke .
docker push registry.koyeb.com/your-org/prikke
```

### Services Not Needed (Yet)
- Redis (Postgres handles job queue)
- SMS (email alerts are enough)
- Object storage (until log archival needed)
- Load balancer (Koyeb handles this)

## Payments

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

- **Name:** Prikke
- **Meaning:** Norwegian for "dot", from "til punkt og prikke" (precisely)
- **Tagline:** "Jobs done, til punkt og prikke"
- **Colors:** Slate 900 (#0f172a) + Emerald 500 (#10b981)
- **Font:** Inter
- **Logo:** Green dot + "prikke" wordmark
- **Domains:** prikke.io (primary), prikke.eu (redirect)

See `/brand/BRAND.md` for full guidelines.

## Landing Page & Documentation

Location: `/app/lib/app_web/controllers/`

Landing page and documentation are served by Phoenix:
- Landing page: `/` (page_html/home.html.heex)
- Docs index: `/docs` (docs_html/index.html.heex)
- API docs: `/docs/api`
- Cron docs: `/docs/cron`
- Webhooks docs: `/docs/webhooks`
- Getting started: `/docs/getting-started`
- Use cases: `/use-cases`

All templates use Tailwind CSS with Prikke brand colors (slate + emerald).

## Development Commands

```bash
# Preview landing page
cd site && python3 -m http.server 8000

# Setup (after Phoenix is initialized)
mix setup

# Start server
mix phx.server

# Interactive console
iex -S mix

# Run tests
mix test

# Database
mix ecto.create
mix ecto.migrate
mix ecto.reset

# Generate auth
mix phx.gen.auth Accounts User users
```

## Development Rules

**CRITICAL: Always compile and run tests before committing:**
```bash
cd app && mix compile && mix test
```

Never commit code without verifying it compiles and tests pass. This is especially important for HEEx templates where syntax errors are not caught until compilation.

**HEEx Template Notes:**
- Curly braces `{` and `}` in code blocks (e.g., JSON examples) must be escaped
- Use HTML entities: `&#123;` for `{` and `&#125;` for `}`
- This applies to all `<pre><code>` blocks containing JSON or JavaScript

**Future Enhancement (Phase 9+):**
- Swagger/OpenAPI docs - Generate API documentation from code

## Current Project Structure

```
prikke/
├── .gitignore
├── CLAUDE.md              # This file
├── README.md
├── brand/
│   ├── BRAND.md           # Brand guidelines
│   ├── colors.css         # CSS variables
│   ├── favicon.svg
│   ├── logo.svg           # Light background
│   └── logo-dark.svg      # Dark background
└── app/                   # Main Phoenix app
    ├── Dockerfile         # Production build
    ├── docker-compose.yml # Local PostgreSQL 18
    ├── config/
    │   ├── runtime.exs    # SSL for prod database
    │   └── prod.exs       # Production config
    ├── lib/app_web/
    │   ├── router.ex      # Routes including /docs, /use-cases
    │   └── controllers/
    │       ├── page_html/home.html.heex      # Landing page
    │       ├── docs_controller.ex             # Docs routes
    │       ├── docs_html.ex                   # Docs layout component
    │       ├── docs_html/                     # Doc templates
    │       │   ├── index.html.heex
    │       │   ├── getting_started.html.heex
    │       │   ├── api.html.heex
    │       │   ├── cron.html.heex
    │       │   └── webhooks.html.heex
    │       │   └── use_cases.html.heex
    │       ├── error_html.ex                  # Error page module
    │       └── error_html/                    # Custom error pages
    │           ├── 404.html.heex
    │           └── 500.html.heex
    └── rel/overlays/bin/
        └── server         # Runs migrations then starts app
```

### Site Templating
Simple string replacement templating:
- `templates/layout.html` - shared HTML boilerplate, styles, nav, footer
- `pages/*.html` - content only with `<!-- title: Page Title -->` comment
- Server extracts title and injects content into layout at runtime
- Landing page (`static/index.html`) has its own design, not templated

## Planned App Structure (Phoenix)

```
lib/
├── prikke/
│   ├── accounts/           # User management
│   │   ├── user.ex
│   │   └── api_key.ex
│   ├── jobs/               # Job management
│   │   ├── job.ex
│   │   └── execution.ex
│   ├── scheduler/          # Cron scheduler
│   │   └── scheduler.ex    # GenServer, ticks every minute, uses advisory lock
│   ├── workers/            # Webhook execution
│   │   ├── worker_pool.ex  # Supervises worker GenServers
│   │   └── worker.ex       # Claims and executes jobs (SKIP LOCKED)
│   └── repo.ex
├── prikke_web/
│   ├── live/               # LiveView pages
│   │   ├── dashboard_live.ex
│   │   ├── jobs_live.ex
│   │   └── job_detail_live.ex
│   ├── controllers/        # API controllers
│   │   └── api/
│   │       └── job_controller.ex
│   └── router.ex
```

## Key Decisions

1. **Elixir over Kotlin/.NET** - Best fit for concurrent job execution
2. **No Oban, custom GenServer pool** - Postgres SKIP LOCKED for queue, advisory locks for clustering, no dependencies
3. **No Redis** - Postgres handles everything, simpler infra
4. **Koyeb over Scaleway/Hetzner** - Managed containers, no Linux management, EU company
5. **Lemon Squeezy over Stripe** - MoR handles EU VAT, simpler for solo founder
6. **Mailjet over Resend/Postmark** - French company, good free tier
7. **Two pricing tiers** - Simple: Free and Pro (€29/mo)
8. **API keys over OAuth** - Simpler for users, OAuth later if enterprise needs it
9. **Minute precision only** - No second-level scheduling (not needed, adds complexity)
10. **Retries: one-time only** - One-time jobs retry (5x exponential backoff), cron jobs don't (next scheduled run is the retry)
11. **Notifications: webhook-first** - Email (default) + webhook URL; auto-detect Slack/Discord URLs and format payloads accordingly
12. **Project-level notifications** - Not per-job (simpler, covers 90% of use cases)
13. **Status page** - Public status page for Prikke itself (builds trust); execution history IS user monitoring
14. **Job priority** - Pro tier before Free; minute-interval crons before hourly/daily (more time-sensitive)

## Competitors

| Competitor | Status | Gap |
|------------|--------|-----|
| Inngest | Pivoted to AI | Simple use cases abandoned |
| Trigger.dev | Pivoted to AI | Same |
| QStash | Basic, US-based | No cron UI, not EU |
| Zeplo | UK, minimal | Very basic |

## Go-to-Market

1. Launch on prikke.io with landing page
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
