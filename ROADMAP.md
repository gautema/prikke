# Prikke Roadmap

## Recently Completed

- [x] **Webhook test button** — "Test URL" on job create/edit fires a test request and shows the response inline
- [x] **Execution charts & trends** — Dashboard with 14-day execution trend chart, 4 stat cards (active jobs, executions today, success rate, avg duration)
- [x] **Response assertions** — Mark an execution as failed if the response doesn't match expected status code or body pattern
- [x] **Per-job and per-monitor notification muting** — Mute failure/recovery notifications for individual jobs and monitors
- [x] **429 Retry-After handling** — Auto-retry on 429 responses with backoff from Retry-After header
- [x] **Monitor sync API** — `/api/v1/sync` now supports monitors alongside jobs
- [x] **Dashboard overhaul** — Unified jobs/monitors panes with inline trend charts, aggregate uptime visualization, monthly usage bar at top
- [x] **Run history lines** — Per-job execution status visualization on jobs index page
- [x] **Monitor uptime lines** — Per-monitor daily uptime status on monitors index and show pages (7d free / 30d pro)

## Priority 1 — Next Up

- [ ] **Scheduled email reports** — Weekly digest email with execution stats. Keeps users engaged.
- [ ] **Usage alerts** — Email when approaching 80%/100% of monthly execution limit, before jobs silently stop.

## Priority 2 — Growth & Engagement

- [ ] **Job versioning / change history** — Track edits to a job (who changed what, when).
- [ ] **Bulk job export/import** (JSON/YAML) — Back up configs or move between orgs.
- [ ] **Per-job notification overrides** — Override org-level notification settings on individual jobs.

## Priority 3 — Revenue & Adoption

- [ ] **Payment integration** (Lemon Squeezy) — Replace manual upgrades with real payments.
- [ ] **SDK / client libraries** — Node.js/Python wrappers around the API to lower adoption barrier.
- [ ] **Customer-facing status pages** — Let users create status pages for their own services.

## Priority 4 — Advanced

- [ ] **Workflows** — Multi-step jobs with dependencies.
- [ ] **Bulk push API** — Queue multiple jobs in a single API call (transaction-safe).
- [ ] **URL proxy API** — Prefix any URL to queue it (`POST /q/https://api.example.com/webhook`).
