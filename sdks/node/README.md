# runlater

Delayed tasks, cron jobs, and reliable webhooks for any Node.js app. No Redis. No infrastructure. Just HTTP.

[Documentation](https://runlater.eu/docs) | [Dashboard](https://runlater.eu)

## Install

```bash
npm install runlater
```

## Quick start

```js
import { Runlater } from "runlater"

const rl = new Runlater({ apiKey: process.env.RUNLATER_KEY })

// Fire-and-forget with retries
await rl.send("https://myapp.com/api/process-order", {
  body: { orderId: 123 },
  retries: 5,
})

// Run in 10 minutes
await rl.delay("https://myapp.com/api/send-reminder", {
  delay: "10m",
  body: { userId: 456 },
})

// Run at a specific time
await rl.schedule("https://myapp.com/api/trial-expired", {
  at: "2026-03-15T09:00:00Z",
  body: { userId: 789 },
})

// Recurring cron job
await rl.cron("daily-report", {
  url: "https://myapp.com/api/report",
  schedule: "0 9 * * *",
})
```

## Why Runlater?

- **No infrastructure** — no Redis, no SQS, no cron containers
- **Works everywhere** — Vercel, Netlify, Cloudflare Workers, Express, any Node.js app
- **EU-hosted** — GDPR-native, data never leaves Europe
- **Reliable** — automatic retries with exponential backoff
- **Observable** — execution history, status codes, and error logs in the dashboard

## API

### `rl.send(url, options?)`

Execute a request immediately with reliable delivery.

```js
const result = await rl.send("https://myapp.com/api/webhook", {
  method: "POST",         // default: "POST"
  headers: { "X-Custom": "value" },
  body: { key: "value" }, // automatically JSON-serialized
  retries: 5,             // default: server default
  timeout: 30000,         // ms, default: 30000
  queue: "emails",        // optional: serialize execution within a queue
  callback: "https://myapp.com/api/on-complete", // optional: receive result
})
// => { task_id, execution_id, status, scheduled_for }
```

### `rl.delay(url, options)`

Execute a request after a delay.

```js
await rl.delay("https://myapp.com/api/remind", {
  delay: "10m",           // "30s", "5m", "2h", "1d", or seconds as number
  body: { userId: 123 },
})
```

### `rl.schedule(url, options)`

Execute a request at a specific time.

```js
await rl.schedule("https://myapp.com/api/expire", {
  at: new Date("2026-03-15T09:00:00Z"), // Date object or ISO string
  body: { subscriptionId: "sub_123" },
})
```

### `rl.cron(name, options)`

Create or update a recurring cron task.

```js
await rl.cron("weekly-digest", {
  url: "https://myapp.com/api/digest",
  schedule: "0 9 * * MON",  // every Monday at 9am
  method: "POST",
  enabled: true,
})
```

### Task management

```js
// List all tasks
const { data, has_more } = await rl.tasks.list({ limit: 20 })

// Get a specific task
const task = await rl.tasks.get("task-id")

// Trigger a task manually
await rl.tasks.trigger("task-id")

// View execution history
const executions = await rl.tasks.executions("task-id")

// Delete a task
await rl.tasks.delete("task-id")
```

### Monitors (dead man's switch)

```js
// Create a monitor — alerts you if a ping is missed
const monitor = await rl.monitors.create({
  name: "nightly-backup",
  schedule: "0 2 * * *",
  grace: 600,  // 10 min grace period
})

// Ping it from your cron job
await fetch(monitor.ping_url)
```

### Declarative sync

Push your task configuration from code. Matched by name.

```js
await rl.sync({
  tasks: [
    {
      url: "https://myapp.com/api/report",
      schedule: "0 9 * * *",
    },
  ],
  deleteRemoved: true, // remove tasks not in this list
})
```

## Frameworks

### Next.js (App Router)

```js
// app/api/orders/route.ts
import { Runlater } from "runlater"

const rl = new Runlater({ apiKey: process.env.RUNLATER_KEY })

export async function POST(req: Request) {
  const order = await req.json()

  // Process immediately, return fast
  await rl.send("https://myapp.com/api/fulfill-order", {
    body: order,
    retries: 5,
  })

  return Response.json({ status: "queued" })
}
```

### Express

```js
import express from "express"
import { Runlater } from "runlater"

const app = express()
const rl = new Runlater({ apiKey: process.env.RUNLATER_KEY })

app.post("/orders", async (req, res) => {
  // Send confirmation email in 5 minutes
  await rl.delay("https://myapp.com/api/send-confirmation", {
    delay: "5m",
    body: { orderId: req.body.id },
  })

  res.json({ status: "ok" })
})
```

## Requirements

- Node.js 18+ (uses native `fetch`)
- [Runlater account](https://runlater.eu) (free tier: 10k requests/month)

## License

MIT
