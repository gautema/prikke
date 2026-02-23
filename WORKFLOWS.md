# Workflows

Workflows are multi-step HTTP pipelines modeled after GitHub Actions. A workflow contains named tasks connected by dependencies (`needs`) and conditions (`if`). Tasks run in parallel by default and only wait when explicitly depending on another task's result.

## Mental Model

```
GitHub Actions    →  Runlater Workflows
─────────────────────────────────────────
Workflow          →  Workflow
on: (trigger)     →  trigger (cron, api, webhook)
Jobs              →  Steps (defined on workflow_tasks)
needs:            →  needs (dependency DAG)
if:               →  if (conditional execution)
Job outputs       →  Task response (status_code, body, headers)
workflow_dispatch →  POST /workflows/:id/trigger
```

Workflows reuse the existing worker infrastructure but store their own step definitions. Each step in a workflow lives in the `workflow_tasks` table, which holds both the HTTP config (url, method, headers, body) and the DAG metadata (step name, dependencies, conditions). At runtime, the engine resolves templates and creates transient task+execution pairs for the worker pool to claim — the same `FOR UPDATE SKIP LOCKED` flow used by standalone tasks.

## Step Types

Workflow steps come in three types:

| Type | Purpose | Example |
|------|---------|---------|
| **HTTP task** | Make an HTTP request | `"url": "https://..."` |
| **Sleep** | Pause for a duration | `"sleep": "3d"` |
| **Wait for webhook** | Pause until an external webhook arrives | `"wait_for_webhook": { "timeout": "1h" }` |

A step is an HTTP task by default (has a `url`). Adding `sleep` or `wait_for_webhook` makes it a different type. These are mutually exclusive — a step can only be one type.

## Examples

### Basic: Parallel HTTP tasks with conditions

```json
{
  "name": "order-processing",
  "trigger": "api",
  "tasks": {
    "charge": {
      "url": "https://myapp.com/api/charge",
      "method": "POST",
      "body": { "order_id": "{{trigger.body.order_id}}" }
    },
    "send-receipt": {
      "needs": ["charge"],
      "if": "tasks.charge.status_code == 200",
      "url": "https://myapp.com/api/send-receipt",
      "method": "POST",
      "body": {
        "order_id": "{{trigger.body.order_id}}",
        "amount": "{{tasks.charge.body.amount}}"
      }
    },
    "notify-warehouse": {
      "needs": ["charge"],
      "if": "tasks.charge.status_code == 200",
      "url": "https://myapp.com/api/ship",
      "method": "POST"
    },
    "handle-failure": {
      "needs": ["charge"],
      "if": "tasks.charge.status_code != 200",
      "url": "https://myapp.com/api/payment-failed",
      "method": "POST"
    }
  }
}
```

**What happens:**
1. `POST /workflows/order-processing/trigger` with `{"order_id": 123}`
2. Engine creates a workflow run, finds tasks with no `needs` → `charge`
3. Creates step run for `charge` — worker picks it up (same pool, same code)
4. `charge` completes → engine evaluates dependents:
   - `send-receipt` and `notify-warehouse` both need `charge` and have `status_code == 200` → run in parallel
   - `handle-failure` has `status_code != 200` → skipped
5. All tasks done → workflow run marked `completed`

### Sleep: Delayed follow-up

```json
{
  "name": "trial-expiry",
  "trigger": "api",
  "tasks": {
    "start-trial": {
      "url": "https://myapp.com/api/activate-trial",
      "method": "POST",
      "body": { "user_id": "{{trigger.body.user_id}}" }
    },
    "wait-13-days": {
      "needs": ["start-trial"],
      "sleep": "13d"
    },
    "send-reminder": {
      "needs": ["wait-13-days"],
      "url": "https://myapp.com/api/send-email",
      "method": "POST",
      "body": { "template": "trial-ending-soon", "user_id": "{{trigger.body.user_id}}" }
    },
    "wait-1-day": {
      "needs": ["send-reminder"],
      "sleep": "1d"
    },
    "expire-trial": {
      "needs": ["wait-1-day"],
      "url": "https://myapp.com/api/expire-trial",
      "method": "POST",
      "body": { "user_id": "{{trigger.body.user_id}}" }
    }
  }
}
```

**Sleep accepts:** `"30s"`, `"5m"`, `"2h"`, `"1d"`, or seconds as a number.

### Wait for webhook: Payment flow with external callback

```json
{
  "name": "checkout-flow",
  "trigger": "api",
  "tasks": {
    "create-checkout": {
      "url": "https://myapp.com/api/create-checkout",
      "method": "POST",
      "body": {
        "amount": "{{trigger.body.amount}}",
        "callback_url": "{{wait.payment-result.url}}"
      }
    },
    "payment-result": {
      "needs": ["create-checkout"],
      "wait_for_webhook": { "timeout": "1h" }
    },
    "fulfill-order": {
      "needs": ["payment-result"],
      "if": "tasks.payment-result.body.status == 'paid'",
      "url": "https://myapp.com/api/fulfill",
      "method": "POST",
      "body": {
        "order_id": "{{trigger.body.order_id}}",
        "payment_id": "{{tasks.payment-result.body.payment_id}}"
      }
    },
    "handle-timeout": {
      "needs": ["payment-result"],
      "if": "tasks.payment-result.status == 'timeout'",
      "url": "https://myapp.com/api/checkout-expired",
      "method": "POST"
    }
  }
}
```

**What happens:**
1. Workflow is triggered with order details
2. `create-checkout` calls your API, passing the auto-generated callback URL (`{{wait.payment-result.url}}`)
3. Your API starts a payment session and gives the callback URL to the payment provider
4. Workflow pauses at `payment-result` — step run status is `waiting`
5. Payment provider POSTs to the callback URL when payment completes
6. The webhook payload is stored as the step's response body
7. `fulfill-order` reads `{{tasks.payment-result.body.payment_id}}` from the webhook payload
8. If nobody calls back within 1 hour → step completes with `status: "timeout"`

**How callback URLs work:** Each `wait_for_webhook` step gets a unique callback URL at `/wh/:callback_token`. This is a dedicated route — it does NOT use the existing endpoint infrastructure (since endpoints require a `forward_url` which wait steps don't have). The controller looks up the `workflow_step_run` by `callback_token`, stores the payload, and broadcasts a PubSub event. Simple, no endpoint creation needed.

## Database Schema

### New Tables

```sql
-- Workflow definitions
CREATE TABLE workflows (
    id uuid PRIMARY KEY,
    organization_id uuid REFERENCES organizations(id) ON DELETE CASCADE,
    name text NOT NULL,
    description text,
    trigger_type text NOT NULL DEFAULT 'api',  -- 'api', 'cron', 'webhook'
    cron_expression text,                       -- only if trigger_type = 'cron'
    max_duration_seconds integer DEFAULT 2592000, -- max run duration (default 30 days)
    enabled boolean DEFAULT true,
    deleted_at timestamptz,
    inserted_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    UNIQUE(organization_id, name) WHERE deleted_at IS NULL
);

-- Step definitions within a workflow
-- HTTP config is stored inline (not referencing the tasks table) because steps
-- contain template expressions like {{trigger.body.id}} that aren't valid task URLs.
-- At runtime, templates are resolved and a transient task+execution is created for the worker.
CREATE TABLE workflow_tasks (
    id uuid PRIMARY KEY,
    workflow_id uuid REFERENCES workflows(id) ON DELETE CASCADE,
    step_name text NOT NULL,                   -- e.g. "charge", "send-receipt"
    step_type text NOT NULL DEFAULT 'http',    -- 'http', 'sleep', 'wait_for_webhook'
    -- HTTP config (inline, only for step_type = 'http')
    url text,                                  -- may contain templates: {{trigger.body.id}}
    method text DEFAULT 'POST',
    headers jsonb DEFAULT '{}',
    body text,                                 -- may contain templates
    timeout_ms integer DEFAULT 30000,
    retry_attempts integer DEFAULT 5,
    -- DAG metadata
    needs jsonb DEFAULT '[]',                  -- e.g. ["charge"] — step names this depends on
    if_condition text,                         -- e.g. "tasks.charge.status_code == 200"
    -- Sleep config (only for step_type = 'sleep')
    sleep_duration text,                       -- e.g. "3d", "30s"
    -- Wait-for-webhook config (only for step_type = 'wait_for_webhook')
    webhook_timeout text,                      -- e.g. "1h"
    position integer NOT NULL DEFAULT 0,       -- for ordering in UI/API responses
    inserted_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    UNIQUE(workflow_id, step_name)
);

-- Workflow runs (one per trigger)
CREATE TABLE workflow_runs (
    id uuid PRIMARY KEY,
    workflow_id uuid REFERENCES workflows(id) ON DELETE CASCADE,
    organization_id uuid,
    status text NOT NULL DEFAULT 'running',  -- 'running', 'completed', 'failed', 'cancelled', 'timeout'
    trigger_body jsonb,                       -- the input payload
    expires_at timestamptz,                   -- started_at + max_duration_seconds
    started_at timestamptz NOT NULL,
    finished_at timestamptz,
    inserted_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL
);

-- Step executions within a workflow run
-- This is separate from the main executions table — workflows have their own execution tracking
CREATE TABLE workflow_step_runs (
    id uuid PRIMARY KEY,
    workflow_run_id uuid REFERENCES workflow_runs(id) ON DELETE CASCADE,
    workflow_task_id uuid REFERENCES workflow_tasks(id) ON DELETE CASCADE,
    execution_id uuid REFERENCES executions(id) ON DELETE SET NULL, -- severed when GC deletes transient tasks
    status text NOT NULL DEFAULT 'pending',  -- 'pending', 'running', 'success', 'failed', 'timeout', 'skipped',
                                              -- 'sleeping', 'waiting', 'template_error'
    scheduled_for timestamptz NOT NULL,
    started_at timestamptz,
    finished_at timestamptz,
    wake_at timestamptz,                      -- for sleeping steps: when to wake up
    callback_token text,                      -- for wait_for_webhook steps: unique token in callback URL
    status_code integer,
    duration_ms integer,
    response_body text,                       -- for HTTP: response body; for wait_for_webhook: webhook payload
    is_truncated boolean DEFAULT false,        -- true if response_body exceeded 256KB and was truncated
    error_message text,                       -- includes template resolution errors
    attempt integer DEFAULT 1,
    inserted_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL
);
```

### Changes to Existing Tables

**Minimal.** The workflow engine uses its own tables and communicates with core through context functions and PubSub events.

| Table | Change | Reason |
|-------|--------|--------|
| `tasks` | New `schedule_type` value: `"workflow"` | Transient tasks created by the engine at runtime. Filtered from user-facing queries (dashboard, API list, metrics). |
| `executions` | None | |
| `endpoints` | None | |

The engine creates transient task+execution rows at runtime so the worker can claim and execute them via the existing `FOR UPDATE SKIP LOCKED` flow. These tasks have `schedule_type: "workflow"` and are hidden from user-facing views.

**Garbage collection:** When a workflow run transitions to a terminal state (`completed`, `failed`, `timeout`, `cancelled`), the tick timer bulk-deletes its transient task rows. The GC query joins through `workflow_step_runs.execution_id` → `executions.task_id` to find the task IDs, then deletes them in a single atomic operation:

```sql
DELETE FROM tasks WHERE id IN (
  SELECT e.task_id FROM executions e
  JOIN workflow_step_runs wsr ON wsr.execution_id = e.id
  JOIN workflow_runs wr ON wsr.workflow_run_id = wr.id
  WHERE wr.status IN ('completed', 'failed', 'cancelled', 'timeout')
  AND wr.finished_at < now() - interval '1 minute'
) AND schedule_type = 'workflow'
```

The 1-minute grace period prevents race conditions with in-flight PubSub events. This query is idempotent — safe to run repeatedly by any tick on any node. The GC must run **before** `ON DELETE SET NULL` severs the `execution_id` link (which happens as part of the same cascade), so it's a single atomic `DELETE`.

**Cascade chain:** Deleting the transient task cascades to delete its execution row (existing `ON DELETE CASCADE` on `executions.task_id`). The `workflow_step_runs.execution_id` FK uses `ON DELETE SET NULL`, so the link is severed cleanly instead of blocking or cascading further. After GC, `workflow_step_runs` becomes the **sole source of truth** for step history — which is fine, since it already stores `status_code`, `duration_ms`, `response_body`, and `is_truncated`. The `execution_id` column is only needed during the step's active lifetime (for PubSub correlation); once the run is complete, it's null and unused.

This prevents table bloat — a 10-step workflow running 1,000 times/day won't accumulate 10,000 stale task rows.

### Indexes

```sql
CREATE INDEX workflows_org_id_idx ON workflows(organization_id);
CREATE INDEX workflows_trigger_cron_idx ON workflows(trigger_type, enabled) WHERE trigger_type = 'cron' AND enabled = true;
CREATE INDEX workflow_tasks_workflow_id_idx ON workflow_tasks(workflow_id);
CREATE INDEX workflow_runs_workflow_id_idx ON workflow_runs(workflow_id);
CREATE INDEX workflow_runs_status_idx ON workflow_runs(status) WHERE status = 'running';
CREATE INDEX workflow_runs_expires_idx ON workflow_runs(expires_at) WHERE status = 'running';
CREATE INDEX workflow_step_runs_run_id_idx ON workflow_step_runs(workflow_run_id);
CREATE INDEX workflow_step_runs_execution_id_idx ON workflow_step_runs(execution_id) WHERE execution_id IS NOT NULL;
CREATE INDEX workflow_step_runs_active_idx ON workflow_step_runs(status, wake_at) WHERE status IN ('running', 'waiting', 'sleeping');
CREATE UNIQUE INDEX workflow_step_runs_callback_token_idx ON workflow_step_runs(callback_token) WHERE callback_token IS NOT NULL;
```

## Architecture

### Design Principle: Event-Driven, Loosely Coupled, Concurrency-Safe

The workflow engine lives in the same Elixir app but is **event-driven** — it reacts to events from the worker and inbound controller via PubSub, never directly coupling to their internals. This means:

- Core Runlater (tasks, workers, scheduler, endpoints) stays simple with minimal workflow awareness
- Worker and scheduler changes are tiny — just broadcasting events they already have the data for
- Extractable later if needed (replace PubSub with HTTP callbacks)

**Concurrency safety:** PubSub broadcasts to all nodes in a cluster. To prevent duplicate DAG evaluations, the engine uses a **blocking** Postgres advisory lock (`pg_advisory_xact_lock`) inside a transaction on the `workflow_run_id`. If two parallel steps complete simultaneously, the second event **blocks and waits** rather than being dropped. When the first evaluation commits and releases the lock, the second acquires it, sees the updated state (both steps complete), and correctly advances the DAG. This avoids artificial 5-second latency spikes from falling back to the tick timer for standard parallel flows.

**Reliability:** PubSub is fire-and-forget. If the engine misses an event (crash, restart), the tick timer acts as a safety net — it scans for orphaned step runs (status `running` with a completed execution, or `waiting` past timeout, or expired workflow runs). The tick is a **fallback for crashes only**, not for normal parallel execution.

```
┌─────────────────────────────────┐       ┌──────────────────────────────┐
│  Workflow Engine                 │       │  Runlater Core               │
│  (own DB tables, GenServer)      │       │                              │
│                                  │       │                              │
│  ┌─────────────┐                │       │                              │
│  │ DAG engine  │  HTTP steps:   │       │  Worker completes execution  │
│  │ evaluates   │  creates tasks │──────▶│  with schedule_type:workflow │
│  │ needs + if  │  via context   │       │                              │
│  └──────┬──────┘  function      │       │  Worker broadcasts event:    │
│         │                       │◀──────│  PubSub "execution_completed"│
│         │   blocking xact lock  │       │  (includes execution_id,     │
│         │   on workflow_run_id  │       │   status_code, response_body)│
│         │   (waits, never skips)│       │                              │
│         │                       │       │  Webhook callback controller: │
│         │         wait steps:   │       │  POST /wh/:callback_token    │
│         │         dedicated     │◀──────│  broadcasts "webhook_received│
│         │         route         │       │  (includes payload)          │
│         │                       │       │                              │
│  ┌──────▼──────┐                │       └──────────────────────────────┘
│  │ Tick timer  │  every 5s:     │
│  │ (GenServer) │  - wake sleeps │
│  │             │  - recover     │
│  │             │    orphans     │
│  │             │  - expire runs │
│  │             │  - GC tasks    │
│  └─────────────┘                │
│                                  │
│  DB tables:                      │
│  - workflows                     │
│  - workflow_tasks                │
│  - workflow_runs                 │
│  - workflow_step_runs            │
└─────────────────────────────────┘
```

### How HTTP Steps Work (transient tasks + PubSub events)

1. (During DAG evaluation, inside blocking advisory lock transaction)
2. Engine resolves `{{...}}` templates in url, headers, body — **strict mode: fail the step if any template variable is missing**
3. Engine creates a transient task (`schedule_type: "workflow"`) + execution via the `Tasks` context
4. Engine stores the `execution_id` on the `workflow_step_run` row (for correlation)
5. Transaction commits, releasing the lock
6. Worker claims and executes the task (existing flow, unchanged)
7. Worker broadcasts `{:execution_completed, execution_id, result}` on PubSub **only on final outcome** (success, or failure after all retries exhausted — NOT on intermediate retry failures)
8. Engine receives event, looks up `workflow_step_run` by `execution_id`
9. Engine begins new transaction with blocking advisory lock, stores result, evaluates DAG for next steps

### How Sleep Steps Work (internal timer)

No core Runlater involvement:

1. Engine creates a `workflow_step_run` with `status: "sleeping"` and `wake_at: now + duration`
2. Engine has an internal timer (GenServer tick every 5 seconds) that checks for due sleeping steps
3. Tick acquires advisory lock (same as scheduler — only one node processes sleeps at a time)
4. When `wake_at` passes, the step completes and the engine evaluates the DAG

### How Wait-for-Webhook Steps Work (dedicated route + PubSub events)

Uses a dedicated `/wh/:callback_token` route (not the endpoint system — endpoints require `forward_url` which wait steps don't have):

1. When a workflow run reaches a wait step, the engine generates a unique `callback_token` and stores it on the `workflow_step_run`
2. The callback URL `/wh/:callback_token` is available via `{{wait.<name>.url}}` (pre-generated at run creation time)
3. External service POSTs to `/wh/:callback_token`
4. The webhook controller looks up the `workflow_step_run` by `callback_token`, stores the payload, broadcasts PubSub event
5. Engine listens, evaluates the DAG

### Changes to Core

| File | Change | Size |
|------|--------|------|
| `worker.ex` | Broadcast PubSub event on **final** execution outcome only (not retries) | ~5 lines |
| `task.ex` | Add `"workflow"` to `@schedule_types`; add changeset branch that skips cron/scheduled_at validation | ~5 lines |
| `tasks.ex` | Filter `schedule_type != "workflow"` from user-facing list queries | ~2 lines |
| `dashboard_live.ex` | Exclude workflow tasks from dashboard counts | ~1 line |
| `router.ex` | Add `/wh/:callback_token` route | 1 line |

**New files (not modifications):**

| File | Purpose |
|------|---------|
| `webhook_callback_controller.ex` | Handle `POST /wh/:callback_token` — look up step_run, store payload, broadcast PubSub (~20 lines) |

The inbound controller (`inbound_controller.ex`) is **not modified**. Wait-for-webhook uses its own dedicated route.

Everything else is new code in the workflow engine — no modifications to existing logic.

### Why This Design

| Benefit | How |
|---------|-----|
| **Core stays simple** | Worker/scheduler changes are just PubSub broadcasts |
| **Event-driven** | Engine reacts to events, never polls or reaches into core internals |
| **Testable in isolation** | Send PubSub events in tests, verify engine behavior |
| **Extractable** | Could move to its own service later — replace PubSub with HTTP callbacks |

### Relationship Model

```
workflow
  │
  ├── workflow_tasks (step definitions with inline HTTP config)
  │     ├── step_name: "charge"              step_type: "http"
  │     │   url: "https://myapp.com/api/charge"   (may contain {{...}} templates)
  │     │   method: "POST", timeout_ms: 30000
  │     │   needs: []
  │     │
  │     ├── step_name: "wait-3-days"         step_type: "sleep"
  │     │   sleep_duration: "3d"
  │     │   needs: ["charge"]
  │     │
  │     ├── step_name: "payment-result"      step_type: "wait_for_webhook"
  │     │   webhook_timeout: "1h"
  │     │   needs: ["create-checkout"]
  │     │
  │     └── step_name: "handle-failure"      step_type: "http"
  │         url: "https://myapp.com/api/payment-failed"
  │         needs: ["charge"]
  │         if_condition: "tasks.charge.status_code != 200"
  │
  └── workflow_runs
        └── workflow_step_runs
              ├── step run for "charge"           status: success, execution_id: → executions row
              ├── step run for "wait-3-days"      status: sleeping, wake_at: 2026-02-25T10:00:00Z
              ├── step run for "payment-result"   status: waiting, callback_token: "wsr_abc123"
              └── step run for "handle-failure"   status: skipped
```

HTTP config lives directly on `workflow_tasks` — no foreign key to the tasks table. This avoids two problems:
1. **No phantom tasks** — template expressions like `{{trigger.body.id}}` in URLs would create invalid task rows
2. **No table pollution** — 10,000 workflow runs don't create 50,000 "template" task rows

At runtime, the engine resolves templates and creates transient task+execution pairs (`schedule_type: "workflow"`) for the worker to claim. The `execution_id` is stored on `workflow_step_runs` for correlation.

This means:
- The tasks table gets one new `schedule_type` value (`"workflow"`) — filtered from user-facing queries
- The executions table needs zero changes
- The endpoints table needs zero changes (wait steps use a dedicated `/wh/:token` route, not endpoints)
- The worker adds a PubSub broadcast on final outcomes (~5 lines)
- The scheduler needs zero changes
- Existing standalone tasks, executions, and endpoints are completely unaffected

### Workflow Engine (new GenServer)

The workflow engine subscribes to PubSub events and manages its own sleep/recovery timer:

```elixir
defmodule Prikke.WorkflowEngine do
  use GenServer

  def init(_) do
    Phoenix.PubSub.subscribe(Prikke.PubSub, "workflow_events")
    schedule_tick()  # every 5 seconds
    {:ok, %{}}
  end

  # PubSub event: worker completed an execution that belongs to a workflow
  # Looks up workflow_step_run by execution_id for correlation
  def handle_info({:execution_completed, execution_id, result}, state)

  # PubSub event: webhook arrived for a waiting step
  def handle_info({:webhook_received, callback_token, payload}, state)

  # Internal tick (5 seconds):
  # 1. Wake sleeping steps past their wake_at
  # 2. Recover orphaned step runs (status=running but execution completed)
  # 3. Timeout waiting steps past their webhook_timeout
  # 4. Expire workflow runs past their expires_at
  def handle_info(:tick, state)
end
```

**Concurrency control:** Every path that evaluates the DAG runs inside a Postgres transaction with a **blocking** advisory lock (`pg_advisory_xact_lock(workflow_run_id)`). If two events arrive simultaneously, the second blocks until the first commits — it then sees the fully updated state and evaluates correctly. This is critical: a non-blocking "skip if locked" approach would silently drop events when parallel steps complete at the same time.

To prevent connection pool exhaustion during bursts (e.g., a workflow with 20 parallel steps all completing), PubSub handlers push DAG evaluation into a local `Task.Supervisor` with bounded concurrency. The tick timer also uses a separate advisory lock (like the scheduler) so only one node processes sleeps/recovery at a time.

**All three event paths converge on the same DAG evaluation (inside a transaction):**

1. Begin transaction + acquire blocking advisory lock (`pg_advisory_xact_lock(workflow_run_id)`)
2. Mark the completed step_run with the result
3. Load all workflow_tasks for this workflow (the DAG definition)
4. Load all step_runs for this run (completed results so far)
5. Build result map: `%{"charge" => %{status_code: 200, body: %{...}, ...}}`
6. **Cascade skip:** For each step with no `if` condition whose `needs` include a `skipped` dependency → mark as `skipped`
7. Find workflow_tasks whose `needs` are now all in terminal states (completed, failed, skipped, etc.)
8. For steps with `if` conditions → evaluate condition (skipped deps expose `status: "skipped"`, `status_code: null`) → run or skip
9. For steps without `if` conditions → run (all needs succeeded — cascade skip already handled failed/skipped deps)
10. For each step to run, based on `step_type`:
    - **`http`:** resolve `{{...}}` templates (strict — fail on missing variables), create transient task (`schedule_type: "workflow"`, `enabled: false`, `next_run_at: nil`) + execution, store `execution_id` on step_run → worker executes it
    - **`sleep`:** create step_run with `status: "sleeping"`, `wake_at: now + duration` → tick timer wakes it
    - **`wait_for_webhook`:** create step_run with `status: "waiting"`, `callback_token` → dedicated `/wh/:token` route
11. If all steps in terminal states → mark workflow run as `completed` (or `failed` if no step succeeded and run is stuck)
12. Commit transaction (releases advisory lock automatically)

### Template Expression Resolution

Templates are resolved at execution time (when the engine creates the step run), not at workflow definition time.

**Available variables:**
```
{{trigger.body.*}}              -- the trigger payload
{{trigger.headers.*}}           -- trigger request headers (webhook triggers)
{{tasks.<name>.status_code}}    -- HTTP response status code
{{tasks.<name>.body.*}}         -- parsed JSON response body
{{tasks.<name>.headers.*}}      -- response headers
{{tasks.<name>.status}}         -- step status: "success", "failed", "timeout", "received" (for wait steps)
{{wait.<name>.url}}             -- callback URL for a wait_for_webhook step (available before the step runs)
```

**`{{wait.<name>.url}}`** is special — it's resolved at workflow run creation time (not when the step executes), because upstream HTTP steps need the callback URL before the wait step starts. When a workflow run is triggered, the engine pre-generates callback tokens for all `wait_for_webhook` steps and makes their URLs immediately available as `https://runlater.eu/wh/:callback_token`.

**Implementation:** Simple regex-based replacement. Parse `{{...}}` patterns, look up values from the workflow run's stored results. No need for a full expression engine — just dot-notation path traversal on JSON.

**Strict resolution:** If a template variable cannot be found in the context (e.g., an upstream API changed its response shape from `order_id` to `orderId`), the step **fails immediately** with `status: "template_error"` and an error message like `Failed to resolve {{tasks.charge.body.order_id}}`. This prevents silently sending empty/null values to downstream APIs, which could cause dangerous side effects (refunding an empty order, emailing a null address).

**Cascade skip rule:** If a step has no `if` condition and any of its `needs` was skipped, the step is **cascade-skipped** — template resolution never runs. If the step HAS an `if` condition, the condition is always evaluated (even with skipped dependencies), and template resolution only runs if the condition passes. This prevents false `template_error` failures on steps that were never supposed to run.

### Condition Evaluation (`if`)

Conditions are simple expressions evaluated against task results:

```
tasks.charge.status_code == 200
tasks.charge.status_code != 200
tasks.charge.body.approved == true
tasks.charge.status_code >= 400
```

**Implementation:** Parse into `{left, operator, right}`. Left side is always a path (dot notation). Right side is a literal (number, string, boolean). Operators: `==`, `!=`, `>`, `>=`, `<`, `<=`.

No complex expressions (no `&&`, `||`, nested parens). Keep it simple for v1. If the `if` field is null/omitted, the task runs unconditionally (just needs its `needs` satisfied).

### Execution Result Storage

When an HTTP step completes, the worker broadcasts the result (execution_id, status_code, response_body, duration_ms) via PubSub. The engine looks up the `workflow_step_run` by `execution_id` and stores the result. All workflow state lives in the workflow tables — the engine never reads from the executions table.

**Payload limits:** `response_body` is truncated to 256 KB before storage. If truncated, `is_truncated` is set to `true` on the step run and the body is **not parsed as JSON** for templating. Downstream steps referencing `{{tasks.X.body.field}}` will get a specific error: `Cannot read 'body.field' because the response from 'X' exceeded the 256KB limit and was truncated`. This prevents massive payloads from bloating the database while giving users an actionable error message pointing to the root cause.

For template resolution, the engine parses `response_body` as JSON. If it's not valid JSON, `{{tasks.X.body}}` returns the raw string and `{{tasks.X.body.field}}` fails with `template_error`.

## API Design

### Create Workflow

```
POST /api/v1/workflows
```

```json
{
  "name": "order-processing",
  "trigger": "api",
  "tasks": {
    "charge": {
      "url": "https://myapp.com/api/charge",
      "method": "POST",
      "headers": { "Authorization": "Bearer {{trigger.body.token}}" },
      "body": { "order_id": "{{trigger.body.order_id}}" },
      "retries": 3,
      "timeout": 30000
    },
    "send-receipt": {
      "needs": ["charge"],
      "if": "tasks.charge.status_code == 200",
      "url": "https://myapp.com/api/send-receipt",
      "method": "POST",
      "body": { "email": "{{trigger.body.email}}" }
    }
  }
}
```

**Response (201):**
```json
{
  "data": {
    "id": "wf_abc123",
    "name": "order-processing",
    "trigger": "api",
    "task_count": 2,
    "enabled": true,
    "inserted_at": "2026-02-22T10:00:00Z"
  }
}
```

### Update Workflow

```
PUT /api/v1/workflows/:id
```

Same body as create. Replaces all tasks (delete old, insert new). Doesn't affect in-flight runs.

### Trigger Workflow

```
POST /api/v1/workflows/:id/trigger
```

```json
{
  "order_id": 123,
  "email": "alice@example.com",
  "token": "sk_live_xxx"
}
```

**Response (201):**
```json
{
  "data": {
    "run_id": "run_abc123",
    "workflow_id": "wf_abc123",
    "status": "running",
    "started_at": "2026-02-22T10:05:00Z"
  }
}
```

### Get Workflow

```
GET /api/v1/workflows/:id
```

Returns workflow definition with all tasks.

### List Workflows

```
GET /api/v1/workflows
```

### List Workflow Runs

```
GET /api/v1/workflows/:id/runs
```

### Get Workflow Run

```
GET /api/v1/workflows/:id/runs/:run_id
```

Returns run status with per-task execution results:

```json
{
  "data": {
    "id": "run_abc123",
    "status": "completed",
    "started_at": "2026-02-22T10:05:00Z",
    "finished_at": "2026-02-22T10:05:03Z",
    "tasks": {
      "charge": {
        "status": "success",
        "status_code": 200,
        "duration_ms": 450,
        "started_at": "2026-02-22T10:05:00Z",
        "finished_at": "2026-02-22T10:05:00Z"
      },
      "send-receipt": {
        "status": "success",
        "status_code": 200,
        "duration_ms": 120,
        "started_at": "2026-02-22T10:05:01Z",
        "finished_at": "2026-02-22T10:05:01Z"
      }
    }
  }
}
```

### Delete Workflow

```
DELETE /api/v1/workflows/:id
```

Soft delete. In-flight runs continue to completion.

### Cancel Workflow Run

```
POST /api/v1/workflows/:id/runs/:run_id/cancel
```

Marks run as cancelled, deletes any pending (not yet started) executions.

## Implementation Plan

### Phase 1: Core Schema & Context

**Files:**

| File | Change |
|------|--------|
| `lib/app/workflows/workflow.ex` | New — Ecto schema (with `max_duration_seconds`) |
| `lib/app/workflows/workflow_task.ex` | New — Ecto schema (inline HTTP config + DAG metadata) |
| `lib/app/workflows/workflow_run.ex` | New — Ecto schema (with `expires_at`) |
| `lib/app/workflows/workflow_step_run.ex` | New — Ecto schema (with `execution_id` for correlation) |
| `lib/app/workflows.ex` | New — context module |
| `lib/app/tasks/task.ex` | Add `"workflow"` to `@schedule_types`; add changeset branch for workflow (skips cron_expression/scheduled_at validation, sets `next_run_at: nil`, `enabled: false`) |
| `lib/app/tasks.ex` | Filter `schedule_type != "workflow"` from `list_tasks` default query; add `create_workflow_task/2` using workflow-specific changeset |
| Migration | New tables + add "workflow" schedule_type |

**Validation in `create_workflow/3`:**
- Validate DAG has no cycles (topological sort)
- Validate all `needs` references point to actual step names in the workflow
- Validate step_type constraints (http steps require url, sleep steps require duration, etc.)
- Validate response_body template references don't create impossible dependency chains

**Context functions (`Prikke.Workflows`):**
- `create_workflow/3` — create workflow + workflow_tasks rows in transaction (with DAG validation)
- `update_workflow/3` — replace workflow_tasks, update workflow fields (re-validates DAG)
- `delete_workflow/2` — soft delete
- `get_workflow/2` — with tasks preloaded
- `list_workflows/2` — for org, paginated
- `trigger_workflow/3` — create run, create first executions
- `get_run/2` — with task execution results
- `list_runs/3` — for workflow, paginated
- `cancel_run/2` — cancel pending executions

### Phase 2: Workflow Engine

**Files:**

| File | Change |
|------|--------|
| `lib/app/workflow_engine.ex` | New — GenServer, subscribes to PubSub, manages tick timer |
| `lib/app/template_resolver.ex` | New — strict `{{...}}` template resolution (fails on missing vars) |
| `lib/app/condition_evaluator.ex` | New — `if` condition evaluation |
| `lib/app/application.ex` | Add WorkflowEngine to supervision tree |
| `lib/app/worker.ex` | Broadcast PubSub event on **final** execution outcome only (~5 lines) |
| `lib/app_web/controllers/webhook_callback_controller.ex` | New — handle `POST /wh/:callback_token`, store payload, broadcast PubSub (~20 lines) |
| `lib/app_web/router.ex` | Add `/wh/:callback_token` route (1 line) |

**Engine flow (all three event sources → same DAG logic, inside transaction):**
1. Event: PubSub `:execution_completed` / tick finds sleeping step due / PubSub `:webhook_received`
2. Begin transaction + acquire blocking advisory lock (`pg_advisory_xact_lock(workflow_run_id)`)
3. Engine loads workflow_tasks for the workflow (the DAG) + all step_runs for this run
4. Maps each completed step_run to its `workflow_task.step_name`
5. Builds result map: `%{"charge" => %{status_code: 200, body: %{...}, ...}}`
6. Cascade skip: steps with no `if` whose `needs` include a `skipped` dep → mark `skipped`
7. For steps with `if` → evaluate condition (skipped deps have `status_code: null`) → run or skip
8. For steps without `if` → run if all needs succeeded
9. For each step to run, by `step_type`:
   - `http` → resolve templates (strict), create transient task (`schedule_type: "workflow"`, `enabled: false`, `next_run_at: nil`) + execution, store `execution_id` → worker executes it
   - `sleep` → create sleeping step_run with `wake_at` → tick wakes it
   - `wait_for_webhook` → create waiting step_run with `callback_token` → `/wh/:token` route
10. All steps terminal → `completed` (or `failed` if stuck with no progress possible)
11. Commit transaction (releases lock)

**Tick timer responsibilities (every 5 seconds, with advisory lock):**
- Wake sleeping steps past their `wake_at`
- Recover orphaned step runs (status `running`, execution already completed)
- Timeout waiting steps past their webhook timeout
- Expire workflow runs past their `expires_at`
- GC transient task rows for completed/failed/cancelled workflow runs

### Phase 3: API & Routes

**Files:**

| File | Change |
|------|--------|
| `lib/app_web/controllers/api/workflow_controller.ex` | New |
| `lib/app_web/router.ex` | Add workflow routes |
| `lib/app_web/schemas.ex` | Add workflow OpenAPI schemas |

**Routes (inside authenticated API scope):**
```elixir
resources "/workflows", WorkflowController, only: [:index, :show, :create, :update, :delete] do
  post "/trigger", WorkflowController, :trigger
  get "/runs", WorkflowController, :list_runs
  get "/runs/:run_id", WorkflowController, :show_run
  post "/runs/:run_id/cancel", WorkflowController, :cancel_run
end
```

### Phase 4: Cron-Triggered Workflows

Extend the existing scheduler to handle workflows with `trigger_type: "cron"`:
- Scheduler finds workflows where `trigger_type = 'cron' AND enabled = true AND next_run_at <= now`
- Calls `Workflows.trigger_workflow/3` with empty trigger body
- Advances `next_run_at` to next cron time

This is a small addition to the scheduler — same pattern as regular cron tasks.

### Phase 5: Dashboard UI

LiveView pages for managing workflows:
- Workflow list (with status, last run, next run for cron)
- Workflow detail (visual DAG of tasks, edit form)
- Workflow run list (status, duration, per-task breakdown)
- Workflow run detail (step-by-step execution timeline)

### Phase 6: SDK & Docs

- Add `workflows` namespace to `runlater-js` SDK
- API documentation page
- Getting started guide

## Tier Limits

| | Free | Pro |
|---|------|-----|
| Workflows | 3 | Unlimited |
| Tasks per workflow | 5 | 20 |
| Concurrent runs | 1 | 10 |
| Execution limits | Shared with tasks (10k/mo) | Shared with tasks (1M/mo) |
| Cron triggers | No | Yes |

Workflow task executions count toward the org's monthly execution limit (same pool as standalone tasks).

**Per-org fairness:** Workflow HTTP steps go through the same worker pool and are subject to the existing 5-concurrent-executions-per-org fairness limit. A workflow with 10 parallel HTTP steps will have 5 execute immediately and 5 queue behind the limit. This is intentional — prevents workflows from starving standalone tasks.

## Edge Cases

### Task Failure in a Workflow
- Failed task: dependents are cascade-skipped (unless they have an `if` condition — see Cascade Skipping)
- Individual task retries work normally (retry_attempts on the transient task) — the PubSub event only fires on the **final** outcome (success or last retry exhausted), so the DAG doesn't advance prematurely during retries

### Workflow Run Terminal Status
A workflow run reaches a terminal status when all steps are in terminal states (success, failed, skipped, template_error, timeout):
- **`completed`** — all steps reached terminal states (regardless of individual step outcomes). The per-step statuses tell the full story. A workflow where `charge` failed but `handle-failure` succeeded is `completed` — the user designed the failure path and it worked.
- **`failed`** — reserved for when the engine itself can't make progress (e.g., all remaining steps are blocked by a failed step with no `if` handler). This means no step can advance and the run is stuck.
- **`timeout`** — `expires_at` reached before all steps completed.
- **`cancelled`** — user explicitly cancelled via API.

### Circular Dependencies
- Validated at workflow creation time
- Topological sort of the DAG — reject if cycle detected

### Template Resolution Failures
- If a template path doesn't exist (e.g., `{{tasks.charge.body.missing_field}}`), the step fails with `status: "template_error"`
- If the target step's response was truncated (over 256 KB), the error message explicitly says so: `Cannot read 'body.amount' because the response from 'charge' exceeded the 256KB limit and was truncated`
- This is strict by design — silently sending empty values to external APIs is far more dangerous than failing visibly

### Cascade Skipping
Simple rule:
- Step has **no `if` condition** and any dependency is `skipped` → **cascade skip** (no template resolution, no execution)
- Step **has an `if` condition** → **always evaluate the condition** (never cascade skip), even if dependencies were skipped

During condition evaluation, skipped steps expose: `status: "skipped"`, `status_code: null`, `body: null`
- `tasks.charge.status_code == 200` where charge was skipped → `null == 200` → false → step skipped normally
- `tasks.charge.status == 'skipped'` → true → step runs (this is how you build "handle skip" paths)

This avoids the complexity of parsing conditions to detect what they reference. The `if` field acts as an opt-in to explicit routing — if you add it, you're saying "I know what I'm doing, evaluate me regardless."

Cascade skipping propagates through the DAG: if A is skipped → B (needs A, no `if`) is cascade-skipped → C (needs B, no `if`) is cascade-skipped.

### Concurrent Runs
- Multiple runs of the same workflow can execute simultaneously
- Each run has its own set of executions (linked by `workflow_run_id`)
- No cross-run interference

### Long-Running Workflows
- Workflows have a `max_duration_seconds` (default 30 days, configurable per workflow)
- Sleep steps and wait steps can make a workflow last days/weeks — this is expected
- The tick timer expires runs that exceed their `max_duration_seconds`, preventing silent stalls

### Wait Step Timeouts
- If a webhook doesn't arrive within `timeout`, the step completes with `status: "timeout"`
- Downstream steps can branch on this: `"if": "tasks.payment-result.status == 'timeout'"`
- The scheduler checks for expired waiting steps alongside sleeping steps

### Sleep Step Precision
- Sleep durations are converted to a `wake_at` timestamp at creation time
- Precision depends on scheduler tick interval (currently 5 seconds)
- "sleep 30s" will wake within 30-35 seconds — same precision as cron tasks

### Workflow Run Timeout
- Every workflow run gets an `expires_at` timestamp (`started_at + max_duration_seconds`)
- Default max duration: 30 days (configurable per workflow)
- The tick timer checks for expired runs and marks them as `timeout`
- Prevents workflows from silently sitting forever if a step stalls

### Response Payload Limits
- `workflow_step_runs.response_body` is truncated to 256 KB (same limit as regular executions)
- If truncated, `is_truncated` is set to `true` on the step run — the body is stored but **not parsed as JSON** for templating
- Downstream steps referencing `{{tasks.X.body.field}}` will get a specific error: `Cannot read 'body.field' because the response from 'X' exceeded the 256KB limit and was truncated`
- This gives the user an immediate, actionable root cause instead of a generic "failed to resolve" message

### Orphaned Needs Validation
- During workflow creation, every string in a step's `needs` array must match an actual step name in the workflow
- A typo like `"needs": ["chrage"]` instead of `"charge"` is rejected at creation time with a clear error
- Without this, a misspelled dependency would cause the step to wait forever in `pending` state

### Multi-Node Concurrency
- PubSub broadcasts to all nodes — without protection, parallel step completions trigger duplicate DAG evaluations
- **Blocking** advisory lock (`pg_advisory_xact_lock`) on `workflow_run_id` ensures exactly one node evaluates at a time — the second node **waits** rather than skipping, so no events are lost
- If two parallel steps (A and B) complete simultaneously: Node 1 locks, evaluates A's completion, commits. Node 2 unblocks, sees both A and B complete, correctly advances the DAG
- The tick timer uses a separate advisory lock (like the scheduler) so only one node processes sleeps/recovery

### Engine Recovery (Safety Net)
- PubSub is fire-and-forget — events can be lost during crashes or restarts
- The tick timer (every 5 seconds) acts as a safety net by scanning for:
  - Step runs with status `running` whose `execution_id` points to a completed execution
  - Step runs with status `waiting` past their webhook timeout
  - Workflow runs past their `expires_at`
- This ensures workflows never stall permanently, even if PubSub events are lost

## What We're NOT Building (v1)

- **Loops / iteration** — no `for-each` over a list of items (use batch API instead)
- **Complex expressions** — no `&&`, `||`, nested conditions (simple comparison only)
- **Sub-workflows** — no workflow calling another workflow
- **Retry at workflow level** — only individual task retries (workflow-level retry = re-trigger)
- **Visual workflow builder** — code/API first, visual editor later
- **Lenient template mode** — templates are strict (fail on missing). No opt-in to empty-string fallback for v1
