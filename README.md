# Prikke

> Background jobs, done right. EU-hosted cron and webhook delivery.

## What is Prikke?

Prikke is a European background jobs service. Simple cron scheduling and reliable webhook delivery, hosted in the EU.

The name comes from the Norwegian expression "til punkt og prikke" - meaning to do something precisely, to the letter.

## Features (Planned)

- [ ] Cron scheduling (visual + expressions)
- [ ] HTTP webhook delivery
- [ ] Automatic retries with backoff
- [ ] Execution history and logs
- [ ] Failure alerts (email, Slack)
- [ ] EU-hosted (GDPR-native)

## Tech Stack

- **Backend:** Elixir + Phoenix
- **Jobs:** Oban Pro
- **Database:** PostgreSQL
- **Frontend:** Phoenix LiveView + Tailwind

## Development

```bash
# Setup
mix setup

# Run
mix phx.server

# Visit
open http://localhost:4000
```

## Project Structure

```
prikke/
├── brand/          # Logo, colors, brand guidelines
├── lib/            # Elixir application (coming soon)
├── priv/           # Static assets, migrations
└── test/           # Tests
```

## License

Proprietary - All rights reserved
