# Runlater Roadmap

## Strategy

Runlater is a **task queue with cron built in**, not a cron scheduler with a queue feature.

**Why queues > crons for growth:**
- Cron is a commodity (cron-job.org is free, FastCron is $7/mo). Developers set up crons once and forget.
- Queues grow with the business — every user action can generate a task. Usage scales with traffic.
- Stickier product (in the hot path, not a background utility). Harder to rip out and replace.

**Competitive gap:** Simple, standalone, EU-hosted task queue with a clean REST API. Inngest/Trigger.dev pivoted to AI. QStash is US-based and tied to Upstash. Building it yourself means Redis/SQS infrastructure overhead.

**Positioning:** Async task infrastructure for Europe. Queue delayed tasks, schedule recurring jobs, receive inbound webhooks, and monitor everything. One API, zero infrastructure, fully GDPR-native.

**Principles:**
- Ship less, polish more. Be the best at one thing (EU task queue) rather than okay at five.
- Only add features users are asking for. No speculative roadmap items.
- Every new feature is code to maintain forever. The bar for inclusion is high.

## Priority 1 — Reliability

- [ ] **Postgres backups** — Hourly backups with offsite sync. Non-negotiable before scaling.
- [ ] **Multi-server** — Second app server behind Hetzner Load Balancer for redundancy. Architecture already supports it (SKIP LOCKED, advisory locks).

## Priority 2 — Growth

- [ ] **Content marketing** — dev.to/Hashnode articles targeting "next.js cron", "vercel background jobs", etc. Link back to guides and landing page. Zero maintenance cost, compounds over time.

## Parked

These are ideas that might make sense later, but only if users ask for them. Not actively planned.

- **Task chaining** (`on_success`) — Lightweight alternative to workflows. Only build if multiple users request multi-step task orchestration.
- **Python/Go SDKs** — The REST API + curl works everywhere. Only build SDKs for languages where users are actively struggling.
- **Scheduled email reports** — Weekly digest. Only if retention data shows users forgetting about their account.
- **Encryption at rest** — Per-org field encryption. Only if enterprise customers require it or BYOK.

## Done

- [x] **Bulk push API** — Queue multiple jobs in one call. Only if high-volume users need it.
- [x] **Usage alerts** — Email at 80% and 100% of monthly execution limit, with dashboard warnings.
- [x] **Job versioning / change history** — Covered by audit logging (tracks who changed what fields, when).
- [x] **Payment integration** (Creem) — Checkout with EU VAT handled as Merchant of Record.
- [x] **Node.js SDK** — Published as `runlater-js` on npm. Zero dependencies, native fetch, ESM + CJS.
- [x] **Customer-facing status pages** — Public status pages per org with uptime bars, uptime percentages, and visibility controls.
- [x] **Per-org worker fairness** — Max 3 concurrent executions per org so slow endpoints can't monopolize the pool.
- [x] **Per-job notification overrides** — Override org-level notification settings on individual tasks and monitors.
- [x] **Framework guide pages** — `/guides` with Next.js, Cloudflare Workers, Supabase, and Webhook Proxy guides. Linked from landing page and footer.

## Competitors

| Competitor | Positioning | Our edge |
|------------|-------------|----------|
| QStash (Upstash) | Message queue for serverless | US-based, tied to ecosystem |
| Inngest | Event-driven workflows | Complex, pivoted to AI |
| Trigger.dev | Background jobs for TS | Framework-heavy, pivoted to AI |
| Cronitor | Cron monitoring | Monitoring only, no execution |
| FastCron | Cron scheduling | Cron only, no queues |
| Cron-job.org | Free cron | Free = hard to compete on price |
