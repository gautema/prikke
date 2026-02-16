---
title: I built background jobs 3 times in 2 years, so I turned it into an API
published: false
tags: webdev, productivity, opensource, showdev
---

In the past two years I've built background job systems for three different projects. It was the third one that pushed me over the edge.

## It started with Kotlin

The first two projects were Kotlin backends. Kotlin has excellent coroutine support, so the async parts felt natural — spin up a coroutine, make the HTTP call, done. But the actual job *infrastructure* was still a grind. You need a queue, a way to claim work, retry logic with backoff, failure tracking, alerting when something goes wrong. Each time it took weeks and produced code that someone now has to maintain.

## Then came Next.js and a Kubernetes deployment for notifications

On the third project, another developer on the team built the system with my guidance. We needed async notifications for a B2B application in a highly regulated domain. Data couldn't leave the EU — using a US-hosted queue service was not an option. So we built it ourselves. What started as "just send an email when something happens" turned into this:

- A **transactional outbox table** with status lifecycle (PENDING → PROCESSING → DONE → FAILED)
- A **standalone Node.js worker** deployed as a Kubernetes pod via Terraform
- `FOR UPDATE SKIP LOCKED` for safe concurrent job claiming
- OAuth authentication with token caching and refresh
- A circuit breaker, exponential backoff with jitter, and a metrics window
- Kubernetes secrets, HPA-compatible deployments, resource limits
- An API integration layer with timeout and abort controllers

10 commits over 3 weeks. Infrastructure code, Terraform files, a generic worker framework with injectable callbacks. All to reliably call an API and send an email.

And here's the thing — **the implementation was solid**. The outbox pattern is correct. The idempotency guarantees work. The access-aware filtering respects permissions. Great engineering.

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
    "body": "{\"user_id\": \"123\"}"
  }'
```

That's it. Runlater calls your endpoint, retries on failure, and logs the result. No outbox table, no Kubernetes worker, no Terraform.

Schedule a recurring job? Same simplicity — there's a cron UI or you can use the API. Need to know when things fail? Notifications go to email, Slack, or Discord.

## The interesting technical bits

Since this is dev.to, here's what's under the hood:

**Elixir + Phoenix + Postgres. No Redis. No external job library.**

I have three years of Elixir experience from a previous job, and it felt like a perfect fit for this. The BEAM VM was literally designed for systems that run forever — supervisors restart crashed processes automatically, and lightweight processes make a worker pool trivial.

The entire job queue runs on Postgres:

- **`FOR UPDATE SKIP LOCKED`** — workers claim jobs without conflicts. Same pattern the Next.js project used, but you don't have to build it yourself.
- **Advisory locks for leader election** — only one scheduler node creates executions, but any node can work them. Multi-server from day one.
- **No Redis** — Postgres handles the queue, the locks, and the execution history. One database, fewer things to break at 3am.

```
Scheduler (1 leader)  →  creates pending executions
                              ↓
Worker pool (2-20)    →  claims via SKIP LOCKED  →  HTTP request  →  log result
                              ↓
                         PostgreSQL (the only dependency)
```

## The EU angle

This is something I experienced firsthand. On that Next.js project, we couldn't use any US-hosted service for background jobs — the domain was too regulated. So we spent weeks building our own. That's a real cost teams pay when the only options are US-based.

Runlater is hosted in Europe. Your task payloads, execution logs, and webhook data never leave the EU. GDPR compliance without thinking about it — and without building your own infrastructure to get there.

## Where it's at

The core works: cron scheduling, one-time jobs, immediate queue via API, execution history, team support with API keys, and notifications to email, Slack, or Discord. Free tier available, pro at 29 EUR/month.

## What I'd love to hear

I'm a developer from Norway, building this solo. I built Runlater because I was tired of reimplementing the same infrastructure — and I figured other teams are too.

**How do you handle background jobs in your projects today?** Self-hosted queue? Inngest? Cron on a VM? I'd genuinely love to hear what works and what doesn't.

I'm at [runlater.eu](https://runlater.eu) if you want to try it. Free tier, no credit card.
