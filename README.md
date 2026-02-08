# Prikke (Runlater)

> Async task infrastructure for Europe. Queue delayed tasks, schedule recurring jobs, receive inbound webhooks, and monitor everything.

**Live:** [runlater.eu](https://runlater.eu)

## What is Prikke?

Prikke is a European background jobs service. Task queues, cron scheduling, inbound webhook forwarding, and heartbeat monitoring — hosted entirely in the EU.

The name comes from the Norwegian expression "til punkt og prikke" — meaning to do something precisely, to the letter.

## Features

### Task Execution
- **Cron scheduling** — Recurring jobs with standard cron expressions
- **One-time jobs** — Schedule a task to run once at a specific time
- **Task queues** — On-demand execution via API, immediate or delayed
- **Named queues** — Serial execution per queue (concurrency 1), for payments and rate-limited APIs
- **Webhook delivery** — HTTP GET/POST/PUT/PATCH/DELETE to your endpoints
- **Custom headers and payloads** — Send any method, headers, and body
- **Automatic retries** — Exponential backoff for one-time jobs, 429 Retry-After handling
- **Response assertions** — Fail tasks when response doesn't match expected status or body pattern
- **Execution callbacks** — POST results back to your endpoint on completion
- **Webhook signatures** — HMAC-SHA256 signed requests
- **Idempotency keys** — Exactly-once task creation, safe to retry

### Inbound Endpoints
- **Receive webhooks** — Give Stripe, GitHub, or any service a Runlater URL
- **Store & forward** — Every payload stored, then forwarded to your app with retries
- **In-order delivery** — Events per endpoint forwarded one at a time, in order
- **Event replay** — Reprocess any event from the dashboard or API

### Monitoring
- **Heartbeat monitoring** — Dead man's switch for your external cron jobs
- **Failure & recovery alerts** — Email + webhook notifications (Slack, Discord, custom)
- **Per-job/monitor muting** — Silence notifications for individual jobs or monitors

### Platform
- **Real-time dashboard** — Execution trends, uptime charts, stats
- **Full execution history** — Status, duration, response for every run
- **REST API** — Full CRUD, declarative sync, OpenAPI spec
- **Team workspaces** — Organizations with role-based access and API keys
- **Audit logging** — Track who changed what and when
- **EU-hosted** — Hetzner (Germany), GDPR-native, data never leaves Europe

## Pricing

| | Free | Pro |
|---|------|-----|
| **Price** | €0 | €29/mo |
| **Tasks** | Unlimited | Unlimited |
| **Monitors** | 3 | Unlimited |
| **Endpoints** | 3 | Unlimited |
| **Requests** | 5k/mo | 1M/mo |
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
├── CLAUDE.md               # AI context & project guide
├── ROADMAP.md              # Feature roadmap & strategy
├── brand/                  # Logo, colors, brand guidelines
└── app/                    # Phoenix application
    ├── Dockerfile
    ├── config/deploy.yml   # Kamal deployment config
    ├── lib/
    │   ├── app/            # Business logic
    │   │   ├── accounts/   # Users, orgs, memberships, API keys
    │   │   ├── tasks/      # Task schema
    │   │   ├── executions/ # Execution schema
    │   │   ├── endpoints/  # Inbound endpoint + event schemas
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
    └── test/               # 681 tests
```

## Development

```bash
cd app
docker compose up -d          # Start PostgreSQL
mix setup                     # Install deps, create DB, migrate
mix phx.server                # Start server at localhost:4000
mix test                      # Run tests (681 tests)
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
- [Inbound Endpoints](https://runlater.eu/docs/endpoints)
- [Monitors](https://runlater.eu/docs/monitors)
- [Use Cases](https://runlater.eu/use-cases)
- [Interactive API Docs](https://runlater.eu/api/v1/docs)

## License

Proprietary — All rights reserved
