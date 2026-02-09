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

- [ ] **Encryption at rest (per-organization)** — Encrypt all sensitive customer data using per-org keys (`cloak_ecto`, AES-256-GCM envelope encryption). Each org gets a unique DEK encrypted by a master KEK. Transparent to application code. Fields: Task (url, headers, body, callback_url), Execution (response_body, error_message), InboundEvent (headers, body), Endpoint (forward_url), Organization (webhook_secret, notification_webhook_url), AuditLog (changes, metadata), IdempotencyKey (response_body). Future: enterprise BYOK.
- [ ] **Scheduled email reports** — Weekly digest email with execution stats. Keeps users engaged.
- [ ] **Usage alerts** — Email when approaching 80%/100% of monthly execution limit, before jobs silently stop.

## Priority 2 — Growth & Engagement

- [ ] **Per-job notification overrides** — Override org-level notification settings on individual jobs.
- [ ] **Job versioning / change history** — Track edits to a job (who changed what, when).
- [ ] **Bulk job export/import** (JSON/YAML) — Back up configs or move between orgs.
- [ ] **Rate limiting per endpoint** — Limit how fast inbound events are forwarded, for target APIs with rate limits.

## Priority 3 — Revenue & Adoption

- [ ] **Payment integration** (Lemon Squeezy) — Replace manual upgrades with real checkout. They handle EU VAT as Merchant of Record.
- [ ] **SDK / client libraries** — Node.js/Python wrappers around the API to lower adoption barrier.
- [ ] **Customer-facing status pages** — Let users create public status pages for their own services, powered by monitors and job health.

## Priority 4 — Advanced Features

- [ ] **Workflows** — Multi-step jobs with dependencies (output of one becomes input of the next).
- [ ] **Bulk push API** — Queue multiple jobs in a single API call (transaction-safe).
- [ ] **Per-org worker fairness** — Limit each org to one concurrent worker so slow endpoints can't monopolize the pool.

## Priority 5 — Infrastructure

- [ ] **Degraded mode (Postgres resilience)** — Keep running jobs from ETS cache when Postgres is down, buffer results in DETS, flush on reconnect. At-least-once delivery during outage.
- [ ] **Multi-server with load balancing** — HAProxy + Keepalived with Hetzner Floating IP, or Hetzner Load Balancer (~$5/mo).
- [ ] **Postgres high availability** — Dedicated PG server with hourly backups and offsite sync. Future: `pg_auto_failover` when downtime cost justifies complexity.

## Competitors

| Competitor | Positioning | Our edge |
|------------|-------------|----------|
| QStash (Upstash) | Message queue for serverless | US-based, tied to ecosystem |
| Inngest | Event-driven workflows | Complex, pivoted to AI |
| Trigger.dev | Background jobs for TS | Framework-heavy, pivoted to AI |
| Cronitor | Cron monitoring | Monitoring only, no execution |
| FastCron | Cron scheduling | Cron only, no queues |
| Cron-job.org | Free cron | Free = hard to compete on price |
