---
title: I built an async task API after implementing background jobs 3 times in 2 years
published: false
tags: webdev, productivity, opensource, showdev
---

Last year I built background job systems for three different projects. Twice in Kotlin, once in a Next.js app where another developer on the team implemented it with my guidance.

That last one is what pushed me over the edge.

## 10 commits, 3 weeks, and a Kubernetes deployment for notifications

On that Next.js project, we needed async notifications for a B2B application in a highly regulated domain. Data couldn't leave the EU — using a US-hosted queue service was not an option. So we built it ourselves. What started as "just send an email when something happens" turned into this:

- A **transactional outbox table** with status lifecycle (PENDING → PROCESSING → DONE → FAILED)
- A **standalone Node.js worker** deployed as a Kubernetes pod via Terraform
- `FOR UPDATE SKIP LOCKED` for safe concurrent job claiming
- OAuth authentication with token caching and refresh
- A circuit breaker, exponential backoff with jitter, and a metrics window
- Kubernetes secrets, HPA-compatible deployments, resource limits
- An API integration layer with timeout and abort controllers

10 commits over 3 weeks. Infrastructure code, Terraform files, a generic worker framework with injectable callbacks. All to reliably call an API and send an email.

And here's the thing — **it was well built**. The outbox pattern is solid. The idempotency guarantees are correct. The access-aware filtering respects permissions. She did a great job.

But it shouldn't have been necessary.

## The pattern repeats

Across all three projects, the core need was the same:

1. Something happens in the app
2. Call an HTTP endpoint later (now, in 5 minutes, or on a schedule)
3. Retry if it fails
4. Know if something went wrong

Every time, we built the queue, the worker, the retry logic, the monitoring. Every time, it took weeks. Every time, it worked — but it was custom infrastructure that someone now has to maintain.

In the Next.js project, I saw what I wanted the experience to be: everything just hooks up and works. You don't set up your own bundler. You don't configure your own router. Next.js handles it. I wanted that feeling for background jobs.

**Why isn't there an API where you just POST a task and it runs?**

## So I built one

[Runlater](https://runlater.eu) is async task infrastructure. No SDKs to install, no workers to deploy, no queues to manage. Just HTTP.

Queue a task:

```bash
curl -X POST https://runlater.eu/api/v1/queue \
  -H "Authorization: Bearer sk_live_..." \
  -H "Content-Type: application/json" \
  -d '{
    "url": "https://your-app.com/api/send-notification",
    "method": "POST",
    "body": "{\"user_id\": \"123\"}",
  }'
```

That's it. Runlater calls your endpoint, retries on failure, and logs the result. No outbox table, no Kubernetes worker, no Terraform.

Schedule a recurring job? Same simplicity — there's a cron UI or you can use the API. Need to know when things fail? Notifications go to email, Slack, or Discord.

## The interesting technical bits

Since this is dev.to, here's what's under the hood:

**Elixir + Phoenix + Postgres. No Redis. No external job library.**

The entire job queue runs on Postgres:

- **`FOR UPDATE SKIP LOCKED`** — workers claim jobs without conflicts. Same pattern the Next.js project used, but you don't have to build it yourself.
- **Advisory locks for leader election** — only one scheduler node creates executions, but any node can work them. Multi-server from day one.
- **GenServer worker pool** — Elixir's lightweight processes scale from 2 to 20 workers based on queue depth. No idle resources, no thundering herd.

```
Scheduler (1 leader)  →  creates pending executions
                              ↓
Worker pool (2-20)    →  claims via SKIP LOCKED  →  HTTP request  →  log result
                              ↓
                         PostgreSQL (the only dependency)
```

**Why no Redis?** Postgres handles everything. Job queue, advisory locks, execution history. One database to back up, one connection to manage. Simpler infra means fewer things break at 3am.

**Why Elixir?** The BEAM VM was designed for systems that run forever. Supervisors restart crashed workers automatically. A single node comfortably handles thousands of jobs per minute. And LiveView gives a real-time dashboard without writing JavaScript.

**Priority queue:** Pro tier jobs run before free tier. Minute-interval crons before hourly ones. Within the same priority, oldest first. All in one SQL query with `ORDER BY`.

## The EU angle

This is something I experienced firsthand. On that Next.js project, we couldn't use any US-hosted service for background jobs — the domain was too regulated. So we spent weeks building our own. That's a real cost teams pay when the only options are US-based.

Runlater is hosted in Europe. Your task payloads, execution logs, and webhook data never leave the EU. GDPR compliance without thinking about it — and without building your own infrastructure to get there.

## Where it's at

The core works:

- Cron scheduling (expressions + simple intervals)
- One-time scheduled jobs
- Immediate queue via API
- Execution history with status, duration, response
- Team/org support with API keys
- Webhook signatures (HMAC-SHA256)
- Notifications (email, Slack, Discord)
- HTTP uptime monitors
- Public status pages per organization

Free tier: 5 jobs, 10k requests/month, hourly minimum interval.
Pro tier: unlimited jobs, 1M requests/month, 1-minute intervals.

## What I'd love to hear

I built this because I was tired of reimplementing the same infrastructure. But I'm curious:

**How do you handle background jobs in your projects today?** Self-hosted queue? Inngest? Cron on a VM? Something else?

And honestly — **would you trust a small startup for your async tasks, or does that feel too risky?**

I'm at [runlater.eu](https://runlater.eu) if you want to try it. Free tier, no credit card.
