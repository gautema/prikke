# Prikke Build Plan

## Overview
Build the Prikke MVP: EU-hosted cron scheduling and webhook delivery service using Elixir/Phoenix with custom GenServer job execution.

## Phase 1: Project Setup (Foundation)

### 1.1 Initialize Phoenix Project
```bash
cd /Users/gautema/src/prikke
mix phx.new app --database postgres --live
cd app
```

### 1.2 Configure for Koyeb Deployment
- `config/runtime.exs` - DATABASE_URL, SECRET_KEY_BASE from env
- `Dockerfile` for release build
- Health check endpoint at `/health`

### 1.3 Database Setup
- Configure Ecto for Postgres
- Add UUID primary keys as default
- Set up Flyway-style migrations

**Files:**
- `app/config/config.exs`
- `app/config/runtime.exs`
- `app/Dockerfile`
- `app/lib/prikke/repo.ex`

---

## Phase 2: Authentication & Organizations

### 2.1 User Auth (phx.gen.auth)
```bash
mix phx.gen.auth Accounts User users
```

### 2.2 Organizations
Users belong to organizations. Jobs and API keys belong to organizations.

```elixir
schema "organizations" do
  field :name, :string
  field :slug, :string          # URL-friendly, unique
  field :tier, :string, default: "free"  # billing at org level
  has_many :memberships, Membership
  has_many :users, through: [:memberships, :user]
  has_many :jobs, Job
  has_many :api_keys, ApiKey
  timestamps()
end

schema "memberships" do
  belongs_to :user, User
  belongs_to :organization, Organization
  field :role, :string, default: "member"  # "owner", "admin", "member"
  timestamps()
end
```

- User can belong to multiple organizations
- Org owner can invite others via email
- Billing/tier is per organization

### 2.3 API Key System (Organization Level)
- API keys belong to organization, not user
- Generate `pk_live_xxx` public ID + secret
- Store hashed secret only
- Track which user created the key
- Plug for API authentication → resolves to organization

```elixir
schema "api_keys" do
  belongs_to :organization, Organization
  belongs_to :created_by, User
  field :key_id, :string        # pk_live_xxx (public)
  field :key_hash, :string      # hashed secret
  field :name, :string
  field :last_used_at, :utc_datetime
  timestamps()
end
```

**Files:**
- `app/lib/prikke/accounts/user.ex`
- `app/lib/prikke/accounts/organization.ex`
- `app/lib/prikke/accounts/membership.ex`
- `app/lib/prikke/accounts/api_key.ex`
- `app/lib/prikke_web/plugs/api_auth.ex`
- `app/priv/repo/migrations/*_create_organizations.exs`
- `app/priv/repo/migrations/*_create_memberships.exs`
- `app/priv/repo/migrations/*_create_api_keys.exs`

**Tests:**
- `app/test/prikke/accounts_test.exs` - org CRUD, membership management
- `app/test/prikke_web/plugs/api_auth_test.exs` - key validation, org resolution

---

## Phase 3: Core Domain (Jobs & Executions)

### 3.1 Jobs Schema
```elixir
schema "jobs" do
  belongs_to :organization, Organization
  field :key, :string           # user-defined, unique per org, for idempotent API
  field :name, :string
  field :url, :string
  field :method, :string, default: "GET"
  field :headers, :map, default: %{}
  field :body, :string
  field :schedule_type, :string  # "cron" or "once"
  field :cron_expression, :string
  field :interval_minutes, :integer  # computed for priority
  field :scheduled_at, :utc_datetime
  field :timezone, :string, default: "UTC"
  field :enabled, :boolean, default: true
  field :timeout_ms, :integer, default: 30_000
  timestamps()
end
# Unique constraint: (organization_id, key)
```

### 3.2 Executions Schema
```elixir
schema "executions" do
  belongs_to :job, Job
  field :status, :string        # pending, running, success, failed, timeout
  field :scheduled_for, :utc_datetime
  field :started_at, :utc_datetime
  field :finished_at, :utc_datetime
  field :status_code, :integer
  field :duration_ms, :integer
  field :response_body, :string
  field :error_message, :string
  field :attempt, :integer, default: 1
  timestamps()
end
```

### 3.3 Job Context Functions
- `Jobs.create_job/2` - create job for organization
- `Jobs.update_job/2`
- `Jobs.delete_job/1`
- `Jobs.list_jobs_for_org/1`
- `Jobs.get_job_by_key/2` (org_id, key) - for idempotent API
- `Jobs.sync_jobs/2` (declarative PUT /sync)
- `Jobs.compute_interval_minutes/1` - parse cron, return interval

**Files:**
- `app/lib/prikke/jobs/job.ex`
- `app/lib/prikke/jobs/execution.ex`
- `app/lib/prikke/jobs.ex` (context)
- `app/priv/repo/migrations/*_create_jobs.exs`
- `app/priv/repo/migrations/*_create_executions.exs`

**Tests:**
- `app/test/prikke/jobs_test.exs` - CRUD, sync logic, interval computation
- `app/test/prikke/jobs/job_test.exs` - changeset validations, cron parsing

---

## Phase 4: Job Execution Engine

### 4.1 Scheduler GenServer
- Runs on one node only (advisory lock)
- Ticks every 60 seconds
- Queries due cron jobs, creates pending executions
- Handles one-time job scheduling

```elixir
defmodule Prikke.Scheduler do
  use GenServer

  # Try to acquire advisory lock on init
  # If acquired, start ticking every 60s
  # Query jobs where next_run <= now()
  # Insert executions with status: "pending"
  # Calculate and store next_run for cron jobs
end
```

### 4.2 Worker Pool Manager
- Monitors queue depth every 5 seconds
- Scales workers 2-20 based on pending count
- Uses DynamicSupervisor

### 4.3 Worker GenServer
- Claims execution with FOR UPDATE SKIP LOCKED
- Executes HTTP request with Req
- Updates execution status
- Handles retries for one-time jobs
- Exits after 30s idle

```elixir
defmodule Prikke.Worker do
  use GenServer

  # Loop: claim -> execute -> update -> repeat
  # Exit if no work for 30 seconds
end
```

### 4.4 HTTP Execution
- Use Req library for HTTP calls
- 30 second timeout
- Capture status, headers, body
- Sign requests with X-Prikke-Signature

**Files:**
- `app/lib/prikke/scheduler/scheduler.ex`
- `app/lib/prikke/workers/pool_manager.ex`
- `app/lib/prikke/workers/worker.ex`
- `app/lib/prikke/workers/http_executor.ex`
- `app/lib/prikke/application.ex` (add to supervision tree)

**Tests:**
- `app/test/prikke/scheduler/scheduler_test.exs` - scheduling logic, cron calculation
- `app/test/prikke/workers/worker_test.exs` - job claiming, execution flow
- `app/test/prikke/workers/http_executor_test.exs` - HTTP mocking, signature generation
- `app/test/prikke/workers/pool_manager_test.exs` - scaling logic

---

## Phase 5: REST API

### 5.1 API Routes
```elixir
scope "/api", PrikkeWeb.API do
  pipe_through [:api, :api_auth]

  # Declarative sync
  put "/sync", JobController, :sync

  # Individual CRUD
  get "/jobs", JobController, :index
  post "/jobs", JobController, :create
  get "/jobs/:id", JobController, :show
  get "/jobs/key/:key", JobController, :show_by_key
  patch "/jobs/:id", JobController, :update
  delete "/jobs/:id", JobController, :delete

  # Trigger immediate run
  post "/jobs/:id/trigger", JobController, :trigger

  # Execution history
  get "/jobs/:id/executions", ExecutionController, :index
end
```

### 5.2 API Response Format
```json
{
  "job": { ... },
  "changes": {
    "from": { ... },
    "to": { ... }
  }
}
```

**Files:**
- `app/lib/prikke_web/controllers/api/job_controller.ex`
- `app/lib/prikke_web/controllers/api/execution_controller.ex`
- `app/lib/prikke_web/router.ex`

**Tests:**
- `app/test/prikke_web/controllers/api/job_controller_test.exs` - CRUD, sync, auth
- `app/test/prikke_web/controllers/api/execution_controller_test.exs` - listing, filtering

---

## Phase 6: Dashboard (LiveView)

### 6.1 Design Principles
- **Clean and focused** - No clutter, show what matters
- **Real-time** - LiveView updates without refresh
- **Actionable** - Quick actions always visible
- **Mobile-friendly** - Works on phone for quick checks

### 6.2 Pages

#### Dashboard Home (`/dashboard`)
The first thing users see after login. At-a-glance health of their jobs.

```
┌─────────────────────────────────────────────────────────────┐
│  Prikke                              [Org Switcher ▼] [User]│
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐        │
│  │   12    │  │    3    │  │   847   │  │  99.2%  │        │
│  │ Active  │  │ Failed  │  │ Today   │  │ Success │        │
│  │  Jobs   │  │ (24hr)  │  │  Runs   │  │  Rate   │        │
│  └─────────┘  └─────────┘  └─────────┘  └─────────┘        │
│                                                             │
│  Recent Executions                          [View All →]   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ ✓ daily-backup      2 min ago     203ms    200 OK   │   │
│  │ ✓ sync-inventory    5 min ago     1.2s     200 OK   │   │
│  │ ✗ send-reports      12 min ago    30s      timeout  │   │
│  │ ✓ health-check      15 min ago    89ms     200 OK   │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  Jobs Needing Attention                                     │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ ⚠ send-reports - 3 failures in last 24h    [View]   │   │
│  │ ⚠ api-sync - Last success 2 days ago       [View]   │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Key elements:**
- Stats cards: Active jobs, recent failures, today's runs, success rate
- Recent executions: Live-updating list (via PubSub)
- Jobs needing attention: Failing jobs, jobs that haven't run

#### Jobs List (`/jobs`)
All jobs with quick actions and filtering.

```
┌─────────────────────────────────────────────────────────────┐
│  Jobs                                    [+ Create Job]     │
├─────────────────────────────────────────────────────────────┤
│  [Search...        ]  [All ▼] [Enabled ▼] [Sort: Recent ▼] │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ ● daily-backup                           [···]       │   │
│  │   https://api.myapp.com/backup                       │   │
│  │   0 0 * * *  (Daily at midnight)     Last: 2h ago ✓ │   │
│  ├─────────────────────────────────────────────────────┤   │
│  │ ● sync-inventory                         [···]       │   │
│  │   https://api.myapp.com/sync                         │   │
│  │   */5 * * * *  (Every 5 minutes)     Last: 3m ago ✓ │   │
│  ├─────────────────────────────────────────────────────┤   │
│  │ ○ send-reports (disabled)                [···]       │   │
│  │   https://api.myapp.com/reports                      │   │
│  │   0 9 * * 1  (Mondays at 9am)        Last: 5d ago ✗ │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  Showing 3 of 12 jobs                      [Load More]      │
└─────────────────────────────────────────────────────────────┘
```

**Quick actions menu [···]:**
- Run Now
- Edit
- Disable/Enable
- View History
- Delete

**Filtering:**
- Search by name, URL, or key
- Filter by status (enabled/disabled)
- Filter by health (healthy/failing)
- Sort by name, created, last run

#### Job Detail (`/jobs/:id`)
Everything about a single job.

```
┌─────────────────────────────────────────────────────────────┐
│  ← Back to Jobs                                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  daily-backup                    [Run Now] [Edit] [Delete]  │
│  ● Enabled                                                  │
│                                                             │
│  ┌──────────────────────┬──────────────────────────────┐   │
│  │ Schedule             │ 0 0 * * * (Daily at midnight)│   │
│  │ URL                  │ https://api.myapp.com/backup │   │
│  │ Method               │ POST                         │   │
│  │ Timeout              │ 30 seconds                   │   │
│  │ Next Run             │ Tomorrow at 00:00 UTC        │   │
│  │ Created              │ Jan 15, 2024                 │   │
│  └──────────────────────┴──────────────────────────────┘   │
│                                                             │
│  Execution History                                          │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Jan 28, 00:00    ✓ 200 OK     203ms    [Details]    │   │
│  │ Jan 27, 00:00    ✓ 200 OK     198ms    [Details]    │   │
│  │ Jan 26, 00:00    ✗ timeout    30.0s    [Details]    │   │
│  │ Jan 25, 00:00    ✓ 200 OK     210ms    [Details]    │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  Success Rate (30 days)                                     │
│  [████████████████████████████░░] 96.7% (29/30)            │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Execution details modal:**
- Request: method, URL, headers, body
- Response: status, headers, body (truncated)
- Timing: scheduled_for, started_at, duration
- Error message if failed

#### Create/Edit Job (`/jobs/new`, `/jobs/:id/edit`)
Form with helpful validation.

```
┌─────────────────────────────────────────────────────────────┐
│  Create Job                                                 │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Name *                                                     │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ daily-backup                                         │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  Key (optional, for API)                                    │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ daily-backup                                         │   │
│  └─────────────────────────────────────────────────────┘   │
│  Used for idempotent API updates                            │
│                                                             │
│  URL *                                                      │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ https://api.myapp.com/backup                         │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  Method                                                     │
│  [GET ▼]  [POST]  [PUT]  [PATCH]  [DELETE]                 │
│                                                             │
│  Schedule                                                   │
│  ○ Recurring (cron)    ● One-time                          │
│                                                             │
│  Cron Expression *                                          │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ 0 0 * * *                                            │   │
│  └─────────────────────────────────────────────────────┘   │
│  → Runs daily at 00:00 UTC                                  │
│  → Next run: Tomorrow at 00:00 UTC                          │
│                                                             │
│  [Quick picks: Hourly | Daily | Weekly | Monthly]           │
│                                                             │
│  ▼ Advanced Options                                         │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Headers (JSON)                                       │   │
│  │ {"Authorization": "Bearer xxx"}                      │   │
│  │                                                      │   │
│  │ Body                                                 │   │
│  │ {"action": "full_backup"}                            │   │
│  │                                                      │   │
│  │ Timezone: [UTC ▼]                                    │   │
│  │ Timeout: [30] seconds                                │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│                              [Cancel]  [Create Job]         │
└─────────────────────────────────────────────────────────────┘
```

**Form features:**
- Live cron validation and next-run preview
- Quick pick buttons for common schedules
- JSON validation for headers/body
- Timezone selector with search

#### Settings (`/settings`)
Organization settings, API keys, notifications.

```
┌─────────────────────────────────────────────────────────────┐
│  Settings                                                   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  [Organization] [API Keys] [Notifications] [Team] [Billing] │
│                                                             │
│  ═══════════════════════════════════════════════════════   │
│                                                             │
│  API Keys                                                   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Production Key                                       │   │
│  │ pk_live_a1b2c3...  Created Jan 1   Last used: 2h ago│   │
│  │                                    [Reveal] [Delete]│   │
│  ├─────────────────────────────────────────────────────┤   │
│  │ CI/CD Key                                            │   │
│  │ pk_live_x9y8z7...  Created Jan 10  Last used: 1d ago│   │
│  │                                    [Reveal] [Delete]│   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  [+ Create New API Key]                                     │
│                                                             │
│  ───────────────────────────────────────────────────────   │
│                                                             │
│  Webhook Secret                                             │
│  Used to verify requests from Prikke to your endpoints      │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ whsec_••••••••••••••••          [Reveal] [Rotate]   │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 6.3 Components

**StatusBadge** - Colored indicator for job/execution status
```elixir
# ● green for success/enabled
# ○ gray for disabled
# ✗ red for failed
# ◐ yellow for running/pending
```

**CronPreview** - Shows human-readable cron + next runs
```elixir
# Input: "0 9 * * 1-5"
# Output: "Weekdays at 9:00 AM"
# Next: "Monday, Jan 29 at 9:00 AM UTC"
```

**ExecutionTimeline** - Vertical list of executions with status
**StatsCard** - Number + label with optional trend indicator
**QuickActions** - Dropdown menu for job actions
**EmptyState** - Friendly message when no jobs/executions

### 6.4 Real-time Updates
```elixir
# When execution completes, broadcast:
PrikkeWeb.Endpoint.broadcast("org:#{org_id}", "execution:completed", payload)

# LiveViews subscribe:
def mount(_params, _session, socket) do
  if connected?(socket) do
    PrikkeWeb.Endpoint.subscribe("org:#{socket.assigns.org.id}")
  end
end

def handle_info(%{event: "execution:completed"} = msg, socket) do
  # Update stats, prepend to recent executions list
end
```

### 6.5 Mobile Responsiveness
- Stats cards stack vertically on mobile
- Job list becomes card-based (not table)
- Sidebar becomes hamburger menu
- Touch-friendly action buttons

**Files:**
- `app/lib/prikke_web/live/dashboard_live.ex`
- `app/lib/prikke_web/live/jobs_live.ex`
- `app/lib/prikke_web/live/job_detail_live.ex`
- `app/lib/prikke_web/live/job_form_live.ex`
- `app/lib/prikke_web/live/settings_live.ex`
- `app/lib/prikke_web/components/job_components.ex`
- `app/lib/prikke_web/components/stats_components.ex`
- `app/lib/prikke_web/components/form_components.ex`

**Tests:**
- `app/test/prikke_web/live/dashboard_live_test.exs`
- `app/test/prikke_web/live/jobs_live_test.exs` - create, edit, delete flows
- `app/test/prikke_web/live/job_detail_live_test.exs`
- `app/test/prikke_web/live/settings_live_test.exs` - API key management

---

## Phase 7: Notifications

### 7.1 Project-Level Settings
- Email notifications (default)
- Webhook URL (optional)
- Auto-detect Slack/Discord

### 7.2 Notification Worker
- Triggered on job failure
- Sends email via Mailjet
- POSTs to webhook URL
- Formats for Slack/Discord if detected

**Files:**
- `app/lib/prikke/notifications/notifier.ex`
- `app/lib/prikke/notifications/email.ex`
- `app/lib/prikke/notifications/webhook.ex`

**Tests:**
- `app/test/prikke/notifications/notifier_test.exs` - routing to email/webhook
- `app/test/prikke/notifications/webhook_test.exs` - Slack/Discord detection, formatting

---

## Phase 8: Billing Integration

### 8.1 Lemon Squeezy Webhook
- Handle subscription created/cancelled
- Update user tier
- Track usage limits

### 8.2 Usage Tracking
- Count monthly executions per user
- Enforce limits (5k free, 250k pro)
- Enforce job limits (5 free, unlimited pro)

**Files:**
- `app/lib/prikke_web/controllers/webhook_controller.ex`
- `app/lib/prikke/billing/usage.ex`

**Tests:**
- `app/test/prikke_web/controllers/webhook_controller_test.exs` - signature validation
- `app/test/prikke/billing/usage_test.exs` - counting, limit enforcement

---

## Testing Strategy

### Principles
- Unit tests for all business logic
- Integration tests for API endpoints
- LiveView tests for critical user flows
- Use factories (ex_machina) for test data

### Test Helpers
```elixir
# test/support/fixtures/accounts_fixtures.ex
def organization_fixture(attrs \\ %{})
def user_fixture(attrs \\ %{})
def membership_fixture(org, user, role \\ "member")
def api_key_fixture(org)

# test/support/fixtures/jobs_fixtures.ex
def job_fixture(org, attrs \\ %{})
def execution_fixture(job, attrs \\ %{})
```

### Mocking HTTP
Use `Req.Test` or `Bypass` for mocking external HTTP calls in worker tests.

### Running Tests
```bash
mix test                    # All tests
mix test --cover            # With coverage
mix test test/prikke/       # Unit tests only
mix test test/prikke_web/   # Integration tests only
```

---

## Build Order (Suggested)

### Week 1: Foundation
1. Phoenix project setup + test config
2. User auth (phx.gen.auth)
3. Organizations + Memberships
4. Jobs + Executions schemas
5. Basic CRUD API + tests

### Week 2: Execution Engine
6. Scheduler GenServer + tests
7. Worker pool + workers + tests
8. HTTP executor with Req + tests
9. Retry logic for one-time jobs

### Week 3: Dashboard
10. Job list LiveView + tests
11. Job detail + execution history
12. Create/edit job forms
13. Settings page (API keys, org settings)

### Week 4: Polish & Deploy
14. Notifications (email + webhook) + tests
15. Lemon Squeezy integration + tests
16. Organization invites
17. Deploy to Koyeb

---

## Dependencies to Add

```elixir
# mix.exs
defp deps do
  [
    # HTTP client
    {:req, "~> 0.4"},

    # Cron parsing
    {:crontab, "~> 1.1"},

    # Email
    {:swoosh, "~> 1.0"},
    {:gen_smtp, "~> 1.0"},

    # JSON
    {:jason, "~> 1.4"},

    # Time zones
    {:tz, "~> 0.26"},

    # Testing
    {:ex_machina, "~> 2.7", only: :test},
    {:bypass, "~> 2.1", only: :test},
    {:mox, "~> 1.0", only: :test},

    # HMAC signatures
    # (built into Erlang :crypto)
  ]
end
```

---

## Verification

### Local Testing
```bash
cd app
mix setup
mix phx.server
# Visit http://localhost:4000
```

### Test Job Execution
1. Create user via dashboard
2. Create test job pointing to httpbin.org
3. Verify execution appears in history
4. Check scheduler logs

### API Testing
```bash
# Get API key from dashboard, then:
curl -X POST http://localhost:4000/api/jobs \
  -H "Authorization: Bearer pk_live_xxx" \
  -H "Content-Type: application/json" \
  -d '{"name": "Test", "url": "https://httpbin.org/post", "cron": "* * * * *"}'
```

### Production Checklist
- [ ] DATABASE_URL configured
- [ ] SECRET_KEY_BASE set
- [ ] Health check passing
- [ ] Scheduler acquiring lock
- [ ] Workers claiming jobs
- [ ] Emails sending via Mailjet
