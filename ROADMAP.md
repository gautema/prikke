# Runlater Roadmap

## Strategy

Runlater is a **task queue with cron built in**, not a cron scheduler with a queue feature.

**Why queues > crons for growth:**
- Cron is a commodity (cron-job.org is free, FastCron is $7/mo). Developers set up crons once and forget.
- Queues grow with the business — every user action can generate a task. Usage scales with traffic.
- Stickier product (in the hot path, not a background utility). Harder to rip out and replace.

**Competitive gap:** Simple, standalone, EU-hosted task queue with a clean REST API. Inngest/Trigger.dev pivoted to AI. QStash is US-based and tied to Upstash. Building it yourself means Redis/SQS infrastructure overhead.

**Positioning:** Async task infrastructure for Europe. Queue delayed tasks, schedule recurring jobs, receive inbound webhooks, and monitor everything. One API, zero infrastructure, fully GDPR-native.

## Priority 1 — Next Up

- [x] **Usage alerts** — Email at 80% and 100% of monthly execution limit, with dashboard warnings.

## Priority 2 — Reliability

- [ ] **Postgres high availability** — Dedicated PG server with hourly backups and offsite sync. Future: `pg_auto_failover` when downtime cost justifies complexity.
- [ ] **Multi-server with load balancing** — HAProxy + Keepalived with Hetzner Floating IP, or Hetzner Load Balancer (~$5/mo).
- [ ] **Degraded mode (Postgres resilience)** — Keep running jobs from ETS cache when Postgres is down, buffer results in DETS, flush on reconnect. At-least-once delivery during outage.

## Priority 3 — Growth & Engagement

- [x] **Per-job notification overrides** — Override org-level notification settings on individual tasks and monitors.
- [ ] **Framework guide pages** — SEO-targeted docs for Next.js, Express, Remix, Cloudflare Workers (e.g. "Background jobs in Next.js").
- [ ] **Docs section grouping** — Reorganize docs into sections: Getting Started, Guides, Features, API Reference.
- [ ] **Content marketing** — dev.to/Hashnode articles targeting "next.js cron", "vercel background jobs", etc. Link back to runlater.eu.

## Priority 4 — Advanced Features

- [ ] **Workflows** — Multi-step jobs with dependencies (output of one becomes input of the next).
- [ ] **Bulk push API** — Queue multiple jobs in a single API call (transaction-safe).
- [ ] **Bulk job export/import** (JSON/YAML) — Back up configs or move between orgs.
- [ ] **Python SDK** (`runlater` on PyPI) — Django/FastAPI crowd.
- [ ] **Go SDK** — For the infrastructure-minded.

## Priority 5 — Later

- [ ] **Scheduled email reports** — Weekly digest email with execution stats. Keeps users engaged.
- [ ] **Encryption at rest (per-organization)** — Per-org field encryption with `cloak_ecto`. Disk encryption covers current needs; add this if enterprise customers require it or BYOK.

## Done

- [x] **Usage alerts** — Email at 80% and 100% of monthly execution limit, with dashboard warnings.
- [x] **Job versioning / change history** — Covered by audit logging (tracks who changed what fields, when).
- [x] **Payment integration** (Creem) — Checkout with EU VAT handled as Merchant of Record.
- [x] **Node.js SDK** — Published as `runlater-js` on npm. Zero dependencies, native fetch, ESM + CJS.
- [x] **Customer-facing status pages** — Public status pages per org with uptime bars, uptime percentages, and visibility controls.
- [x] **Per-org worker fairness** — Max 3 concurrent executions per org so slow endpoints can't monopolize the pool.
- [x] **Per-job notification overrides** — Override org-level notification settings on individual tasks and monitors.

## Competitors

| Competitor | Positioning | Our edge |
|------------|-------------|----------|
| QStash (Upstash) | Message queue for serverless | US-based, tied to ecosystem |
| Inngest | Event-driven workflows | Complex, pivoted to AI |
| Trigger.dev | Background jobs for TS | Framework-heavy, pivoted to AI |
| Cronitor | Cron monitoring | Monitoring only, no execution |
| FastCron | Cron scheduling | Cron only, no queues |
| Cron-job.org | Free cron | Free = hard to compete on price |
