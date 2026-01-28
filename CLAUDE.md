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
| Jobs | Oban Pro | Production-grade scheduling, clustering, dynamic cron |
| Database | PostgreSQL | Oban uses it for coordination, no Redis needed |
| Frontend | Phoenix LiveView + Tailwind | Real-time dashboard with minimal JS |
| HTTP Client | Req (uses Finch) | Modern, connection pooling |
| Auth | phx.gen.auth + API keys | Sessions for dashboard, API keys for programmatic access |
| Hosting | Koyeb (Frankfurt) | French company, managed containers, EU region |
| Database | Koyeb Managed Postgres | Same provider as compute, low latency |
| Payments | Lemon Squeezy | Merchant of Record, handles EU VAT |
| Email | Mailjet | French company, good free tier |
| DNS/CDN | Cloudflare | Free tier, fine for DNS/CDN |

### Why Elixir?
- BEAM VM designed for systems that run forever
- Lightweight processes (millions concurrent)
- Fault tolerance built-in (supervisors)
- Oban handles the hard parts of job scheduling
- LiveView gives real-time UI for free
- Developer has 2 years Elixir experience

### Why Oban Pro?
- Dynamic cron (users create schedules at runtime) - requires Pro
- Clustering works out of the box via Postgres
- Rate limiting, workflows, batching included
- Worth €99/year vs building it yourself

## Features

### MVP (v1)
- [ ] User registration and login
- [ ] Create/edit/delete scheduled jobs
- [ ] Cron expressions + simple intervals (hourly, daily, weekly)
- [ ] One-time scheduled jobs (run once at specific time)
- [ ] HTTP GET/POST webhook delivery
- [ ] Automatic retries (3 attempts, exponential backoff)
- [ ] Execution history with status, duration, response
- [ ] Email alerts on failure
- [ ] Basic dashboard

### v2
- [ ] Job queues (on-demand via API, immediate execution)
- [ ] Slack/webhook alerts
- [ ] Custom headers and auth for webhooks
- [ ] Request body for POST
- [ ] Team/organization support

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
│              Cloudflare                 │
│              DNS + CDN                  │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│        Koyeb (Frankfurt) 🇫🇷            │
│  ┌─────────────────────────────────┐    │
│  │  Container: Phoenix + Oban      │    │
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
| Container | Koyeb Small 🇫🇷 | ~€10/mo |
| Database | Koyeb Postgres 🇫🇷 | ~€7/mo |
| Email | Mailjet 🇫🇷 | Free tier (6k/mo) |
| Payments | Lemon Squeezy | % of revenue |
| DNS/CDN | Cloudflare | Free |
| Monitoring | Better Stack | Free tier |
| **Total** | | **~€17/mo** |

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
- Redis (Oban uses Postgres)
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
│                   Oban                           │
│  ┌─────────────┐  ┌─────────────┐               │
│  │ Cron Plugin │  │   Queues    │               │
│  │ (schedules) │  │ (webhooks)  │               │
│  └─────────────┘  └─────────────┘               │
└─────────────────────┬───────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────┐
│               PostgreSQL                         │
│  (Users, Jobs, Executions, Oban tables)         │
└─────────────────────────────────────────────────┘
```

### Clustering
- Oban uses Postgres for coordination (no Redis)
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

## Waitlist (Cloudflare Worker + D1)

Location: `/worker/`

Simple waitlist API using Cloudflare Worker and D1 database.

### Setup
```bash
cd worker
npm install

# Create D1 database
npm run db:create
# Copy the database_id to wrangler.toml

# Initialize schema
npm run db:init

# Deploy
npm run deploy
```

### Usage
```bash
# List signups
npm run db:list

# Local development
npm run db:init:local
npm run dev
```

### Update Landing Page
After deploying, update `WORKER_URL` in `site/index.html` with your worker URL.

## Landing Page

Location: `/site/index.html`

Simple static one-pager with:
- Hero with tagline
- Feature list
- Code example
- Pricing tiers
- Waitlist signup form

```bash
# Preview locally
cd site && python3 -m http.server 8000
# Then open http://localhost:8000
```

Deploy to Cloudflare Pages or any static host.

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

# Oban dashboard (if using Oban Web)
# Available at /oban in dev
```

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
├── site/
│   ├── index.html         # Landing page
│   └── favicon.svg
└── worker/                # Cloudflare Worker (waitlist API)
    ├── wrangler.toml      # Cloudflare config
    ├── package.json
    ├── schema.sql         # D1 database schema
    ├── tsconfig.json
    └── src/
        └── index.ts       # Worker code
```

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
│   ├── workers/            # Oban workers
│   │   ├── webhook_worker.ex
│   │   └── cron_scheduler.ex
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
2. **Oban Pro over OSS** - Need dynamic cron for user-defined schedules
3. **No Redis** - Postgres handles everything, simpler infra
4. **Koyeb over Scaleway/Hetzner** - Managed containers, no Linux management, EU company
5. **Lemon Squeezy over Stripe** - MoR handles EU VAT, simpler for solo founder
6. **Mailjet over Resend/Postmark** - French company, good free tier
7. **Two pricing tiers** - Simple: Free and Pro (€29/mo)
8. **API keys over OAuth** - Simpler for users, OAuth later if enterprise needs it
9. **Minute precision only** - No second-level scheduling (not needed, adds complexity)

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
