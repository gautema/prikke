# Prikke

> Background jobs, made simple. EU-hosted cron and webhook delivery.

**Live:** [prikke.whitenoise.no](https://prikke.whitenoise.no) (waitlist)

## What is Prikke?

Prikke is a European background jobs service. Simple cron scheduling and reliable webhook delivery, hosted entirely in the EU.

The name comes from the Norwegian expression "til punkt og prikke" - meaning to do something precisely, to the letter.

## Features

- **Cron scheduling** - Recurring jobs with standard cron expressions
- **One-time jobs** - Schedule a job to run once at a specific time
- **Webhook delivery** - HTTP GET/POST to your endpoints
- **Automatic retries** - Exponential backoff for one-time jobs
- **Execution history** - Status, duration, response for every run
- **Failure alerts** - Email + webhook notifications (Slack, Discord, custom)
- **EU-hosted** - Frankfurt region, GDPR-native, data never leaves Europe

## Pricing

| | Free | Pro |
|---|------|-----|
| **Price** | €0 | €29/mo |
| **Jobs** | 5 | Unlimited |
| **Requests** | 5k/mo | 250k/mo |
| **Min interval** | Hourly | 1 minute |
| **History** | 7 days | 30 days |

## Tech Stack

| Component | Technology |
|-----------|------------|
| Backend | Elixir + Phoenix |
| Jobs | GenServer pool + Postgres |
| Database | PostgreSQL |
| Frontend | Phoenix LiveView + Tailwind |
| Hosting | Koyeb (Frankfurt) |
| Payments | Lemon Squeezy |

## Project Structure

```
prikke/
├── brand/              # Logo, colors, brand guidelines
├── site/               # Landing page + docs (Bun)
│   ├── server.ts       # Bun server with templating
│   ├── static/         # Landing page, favicon
│   ├── pages/          # Documentation content
│   └── templates/      # Shared layout
└── app/                # Main app (Phoenix - coming soon)
```

## Development

### Landing Site

```bash
cd site
bun install
bun run server.ts
# Visit http://localhost:3000
```

### Main App (coming soon)

```bash
mix setup
mix phx.server
# Visit http://localhost:4000
```

## Documentation

- [Getting Started](https://prikke.whitenoise.no/docs/getting-started)
- [API Reference](https://prikke.whitenoise.no/docs/api)
- [Cron Syntax](https://prikke.whitenoise.no/docs/cron)
- [Webhooks](https://prikke.whitenoise.no/docs/webhooks)
- [Use Cases](https://prikke.whitenoise.no/use-cases)

## License

Proprietary - All rights reserved
