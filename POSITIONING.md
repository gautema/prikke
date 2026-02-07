# Runlater Positioning Strategy

## Core Insight

Runlater is a **task queue with cron built in**, not a cron scheduler with a queue feature. The landing page and messaging should reflect this.

## Why Queues > Crons

### Cron is a commodity
- Cron-job.org is free. FastCron is $7/mo. EasyCron has been around forever.
- Developers set up crons once and forget. Low engagement, little reason to upgrade.
- Natural ceiling: a typical user has 5-20 cron jobs. They hit Free or Pro and stay forever.
- Usage doesn't grow with the business.

### Queues grow with the business
- Every user action can generate a queued task: signups, purchases, webhooks received.
- A small app queues 1,000 tasks/month. A growing app queues 100,000. A successful one queues millions.
- Usage scales with their traffic, not their configuration.
- Higher engagement (calling the API on every request, not configuring a job once).
- Natural path to higher revenue (usage-based pricing works).
- Stickier product (in the hot path, not a background utility).
- Harder to rip out and replace.

### The competitive gap
- QStash: tied to Upstash ecosystem, US-based.
- Inngest/Trigger.dev: powerful but complex, want you to adopt their framework. Pivoted to AI.
- Building it yourself: Redis/SQS/whatever — infrastructure overhead.
- **Gap**: Simple, standalone, EU-hosted task queue with a clean REST API.

## Positioning Statement

> **Runlater — Async task infrastructure for Europe.**
> Queue delayed tasks, schedule recurring jobs, and monitor everything. One API, zero infrastructure, fully GDPR-native.

## Homepage Flow

1. **Lead with queue/delay** — this is the hook, solves an immediate painful problem
2. **Show cron as "and we do recurring jobs too"** — a feature, not the product
3. **Show monitoring as "and we alert you when things break"** — operational confidence
4. **Show production features** — signatures, idempotency, callbacks, custom headers
5. **Show EU/GDPR** — the differentiator

## What We Already Built (that proves this positioning)

| Feature | Status | Why it matters for queue positioning |
|---------|--------|--------------------------------------|
| Queue API (immediate execution) | Built | Core product |
| Delayed tasks (schedule for future) | Built | Core product |
| `delay` parameter ("30s", "5m", "2h") | Built | Makes queue API ergonomic |
| Cron jobs | Built | Feature within the product |
| Retries with exponential backoff | Built | Production-grade queues need this |
| Execution callbacks | Built | Async workflows, queue completion hooks |
| Webhook signatures (HMAC-SHA256) | Built | Security for production use |
| Idempotency keys | Built | Safe retries, exactly-once semantics |
| Custom headers and payloads | Built | Flexible webhook forwarding |
| Heartbeat monitoring | Built | Operational confidence |
| Notifications (email/Slack/Discord) | Built | Alerting when things break |
| Full execution history | Built | Debugging and audit trail |
| Team workspaces with API keys | Built | Multi-tenant, org-scoped |
| OpenAPI/Swagger docs | Built | Developer experience |

## Risk: Different Buyer

Queue-first positioning attracts a different buyer than cron:
- **Cron users**: Solo devs, small teams, simple utility needs.
- **Queue users**: Building production systems. Care about reliability, latency, SLAs.

Queue users expect:
- Better uptime guarantees
- Faster support
- More detailed docs
- Lower latency

This is good for revenue but raises the bar on operations.

## Pricing Implications

Current pricing (job-count based) fits crons. For queues, consider:
- Usage-based pricing (per execution) in a future tier
- Higher-volume plans (500k, 1M executions/month)
- The free tier's 5k requests/month is fine for trying queues, but a growing app will hit Pro quickly

## Key Competitors to Track

| Competitor | Positioning | Weakness for us |
|------------|-------------|-----------------|
| QStash (Upstash) | Message queue for serverless | US-based, tied to Upstash ecosystem |
| Inngest | Event-driven workflows | Complex, framework-heavy, pivoted to AI |
| Trigger.dev | Background jobs for TS | Framework-heavy, pivoted to AI |
| Cronitor | Cron monitoring | Monitoring only, no execution |
| FastCron | Cron scheduling | Cron only, no queues |
| Cron-job.org | Free cron | Free = hard to compete on price |
