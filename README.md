# Prikke (Runlater)

> Background jobs, made simple. EU-hosted cron scheduling, webhook delivery, and heartbeat monitoring.

**Live:** [runlater.eu](https://runlater.eu)

## What is Prikke?

Prikke is a European background jobs service. Simple cron scheduling, reliable webhook delivery, and heartbeat monitoring — hosted entirely in the EU.

The name comes from the Norwegian expression "til punkt og prikke" — meaning to do something precisely, to the letter.

## Features

- **Cron scheduling** — Recurring jobs with standard cron expressions
- **One-time jobs** — Schedule a job to run once at a specific time
- **Job queues** — On-demand execution via API or UI
- **Webhook delivery** — HTTP GET/POST/PUT/PATCH/DELETE to your endpoints
- **Response assertions** — Fail jobs when response doesn't match expected status code or body pattern
- **Automatic retries** — Exponential backoff for one-time jobs, 429 Retry-After handling
- **Heartbeat monitoring** — Dead man's switch for your external cron jobs
- **Execution history** — Status, duration, response for every run
- **Dashboard** — Real-time stats, execution trends, uptime charts
- **Failure & recovery alerts** — Email + webhook notifications (Slack, Discord, custom)
- **Per-job/monitor muting** — Silence notifications for individual jobs or monitors
- **REST API** — Full CRUD, declarative sync, OpenAPI spec
- **Webhook test button** — Test your URL before saving
- **EU-hosted** — Hetzner (Germany), GDPR-native, data never leaves Europe

## Pricing

| | Free | Pro |
|---|------|-----|
| **Price** | €0 | €29/mo |
| **Jobs** | 5 | Unlimited |
| **Monitors** | 3 | Unlimited |
| **Requests** | 5k/mo | 250k/mo |
| **Min interval** | Hourly | 1 minute |
| **History** | 7 days | 30 days |
| **Team members** | 2 | Unlimited |

## Tech Stack

| Component | Technology |
|-----------|------------|
| Backend | Elixir + Phoenix 1.8 |
| Jobs | GenServer pool + Postgres (SKIP LOCKED) |
| Database | PostgreSQL 18 |
| Frontend | Phoenix LiveView + Tailwind CSS v4 |
| HTTP Client | Req |
| Auth | phx.gen.auth + API keys |
| Hosting | Hetzner VPS + Kamal |
| Email | Mailjet |
| Domain | runlater.eu |

## Project Structure

```
prikke/
├── CLAUDE.md               # Project guide
├── PROGRESS.md             # Implementation progress
├── ROADMAP.md              # Feature roadmap
├── brand/                  # Logo, colors, brand guidelines
└── app/                    # Phoenix application
    ├── Dockerfile          # Production build
    ├── config/deploy.yml   # Kamal deployment config
    ├── lib/
    │   ├── app/            # Business logic (contexts)
    │   │   ├── accounts/   # Users, orgs, memberships, API keys
    │   │   ├── jobs/       # Job schema
    │   │   ├── executions/ # Execution schema
    │   │   ├── monitors/   # Monitor + ping schemas
    │   │   ├── status/     # Status checks + incidents
    │   │   ├── scheduler.ex
    │   │   ├── worker.ex
    │   │   ├── worker_pool.ex
    │   │   ├── monitor_checker.ex
    │   │   └── notifications.ex
    │   └── app_web/        # Web layer
    │       ├── controllers/
    │       │   └── api/    # REST API endpoints
    │       ├── live/       # LiveView pages
    │       └── router.ex
    └── test/
```

## Development

```bash
cd app
docker compose up -d          # Start PostgreSQL
mix setup                     # Install deps, create DB, migrate
mix phx.server                # Start server at localhost:4000
mix test                      # Run tests
```

## Deployment

Deployed to Hetzner VPS (Germany) via [Kamal](https://kamal-deploy.org/):

```bash
cd app && kamal deploy
```

## Documentation

- [Getting Started](https://runlater.eu/docs/getting-started)
- [API Reference](https://runlater.eu/docs/api)
- [Cron Syntax](https://runlater.eu/docs/cron)
- [Webhooks](https://runlater.eu/docs/webhooks)
- [Monitors](https://runlater.eu/docs/monitors)

## License

Proprietary — All rights reserved
