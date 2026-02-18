defmodule PrikkeWeb.LlmsController do
  use PrikkeWeb, :controller

  def index(conn, _params) do
    conn
    |> put_resp_header("content-type", "text/plain; charset=utf-8")
    |> send_resp(200, content())
  end

  defp content do
    """
    # Runlater

    > Runlater is async task infrastructure for Europe. Queue delayed tasks, schedule recurring cron jobs, receive inbound webhooks, and monitor uptime — all from a single API. EU-hosted, GDPR-native, data never leaves Europe.

    Base URL: https://runlater.eu
    API Base URL: https://runlater.eu/api/v1

    ## Authentication

    All API requests require an API key passed via the Authorization header:

        Authorization: Bearer pk_live_xxx.sk_live_yyy

    API keys are organization-scoped. Create them in Settings > API Keys.

    ## Core Concepts

    ### Tasks

    A task is a scheduled HTTP request. Tasks can run:
    - **Immediately** — queued for instant execution
    - **After a delay** — e.g. "run in 30 minutes" (`delay: "30m"`)
    - **At a specific time** — e.g. "run at 2025-03-01T09:00:00Z" (`scheduled_at`)
    - **On a cron schedule** — e.g. "every day at 9am" (`cron: "0 9 * * *"`)

    Tasks send HTTP requests (GET, POST, PUT, PATCH, DELETE) to a target URL with optional headers and body. Responses are logged as executions.

    ### Monitors

    HTTP uptime monitors that ping a URL at a configurable interval and alert on failure. Support email and webhook notifications.

    ### Endpoints

    Inbound webhook receivers. Each endpoint gets a unique URL (`https://runlater.eu/in/:slug`). Incoming requests are logged and forwarded to a target URL. Useful as a webhook proxy with automatic retries and logging.

    ## Pricing

    | | Free | Pro (EUR 29/mo) |
    |---|------|-----------------|
    | Tasks | 5 | Unlimited |
    | Requests | 10,000/mo | 1,000,000/mo |
    | Min interval | Hourly | 1 minute |
    | History | 7 days | 30 days |
    | Team members | 2 | Unlimited |

    ## API Overview

    ### Tasks API

    - `GET /api/v1/tasks` — List all tasks
    - `POST /api/v1/tasks` — Create a task
    - `GET /api/v1/tasks/:id` — Get a task
    - `PUT /api/v1/tasks/:id` — Update a task
    - `DELETE /api/v1/tasks/:id` — Delete a task
    - `POST /api/v1/tasks/:id/trigger` — Trigger a task immediately
    - `GET /api/v1/tasks/:id/executions` — List executions for a task

    ### Monitors API

    - `GET /api/v1/monitors` — List all monitors
    - `POST /api/v1/monitors` — Create a monitor
    - `GET /api/v1/monitors/:id` — Get a monitor
    - `PUT /api/v1/monitors/:id` — Update a monitor
    - `DELETE /api/v1/monitors/:id` — Delete a monitor
    - `GET /api/v1/monitors/:id/pings` — List pings for a monitor

    ### Endpoints API

    - `GET /api/v1/endpoints` — List all endpoints
    - `POST /api/v1/endpoints` — Create an endpoint
    - `GET /api/v1/endpoints/:id` — Get an endpoint
    - `PUT /api/v1/endpoints/:id` — Update an endpoint
    - `DELETE /api/v1/endpoints/:id` — Delete an endpoint
    - `GET /api/v1/endpoints/:id/events` — List events for an endpoint
    - `POST /api/v1/endpoints/:id/events/:event_id/replay` — Replay an event

    ### Declarative Sync

    - `PUT /api/v1/sync` — Sync tasks and monitors from a declarative config

    ## Node.js SDK

    Install: `npm install runlater-js`

    ```javascript
    import { Runlater } from "runlater-js"

    const rl = new Runlater(process.env.RUNLATER_KEY)

    // Create a cron task
    await rl.tasks.create({
      name: "Daily report",
      url: "https://example.com/report",
      method: "POST",
      cron: "0 9 * * *",
      timezone: "Europe/Berlin"
    })

    // Queue an immediate task
    await rl.tasks.create({
      name: "Send welcome email",
      url: "https://example.com/welcome",
      method: "POST",
      body: JSON.stringify({ user_id: 123 }),
      headers: { "Content-Type": "application/json" }
    })

    // Create a monitor
    await rl.monitors.create({
      name: "API Health",
      url: "https://example.com/health",
      interval_seconds: 60
    })
    ```

    ## Documentation

    - [Getting Started](https://runlater.eu/docs/getting-started)
    - [API Reference](https://runlater.eu/docs/api)
    - [Cron Scheduling](https://runlater.eu/docs/cron)
    - [Webhooks & Signatures](https://runlater.eu/docs/webhooks)
    - [Inbound Endpoints](https://runlater.eu/docs/endpoints)
    - [Uptime Monitors](https://runlater.eu/docs/monitors)
    - [Status Badges](https://runlater.eu/docs/badges)
    - [Status Pages](https://runlater.eu/docs/status-pages)
    - [Local Development](https://runlater.eu/docs/local-dev)
    - [Interactive API Docs (Swagger)](https://runlater.eu/api/v1/docs)

    ## Optional

    - [Use Cases](https://runlater.eu/use-cases)
    - [Next.js Guide](https://runlater.eu/guides/nextjs-background-jobs)
    - [Cloudflare Workers Guide](https://runlater.eu/guides/cloudflare-workers-cron)
    - [Supabase Guide](https://runlater.eu/guides/supabase-scheduled-tasks)
    - [Webhook Proxy Guide](https://runlater.eu/guides/webhook-proxy)
    - [Privacy Policy](https://runlater.eu/privacy)
    - [Terms of Service](https://runlater.eu/terms)
    """
  end
end
