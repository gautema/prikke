# Fan-out on Inbound Webhooks

## Problem

Third-party services often only support configuring one webhook URL per tenant. When migrating between systems, you need the same webhook delivered to both old and new systems simultaneously.

## Solution

Endpoints get multiple forward URLs instead of one. When a webhook arrives, it's forwarded to all destinations independently (each gets its own task + execution with independent retries).

## Schema Changes

### Migration

```sql
-- 1. Endpoints: forward_url → forward_urls
ALTER TABLE endpoints ADD COLUMN forward_urls text[] NOT NULL DEFAULT '{}';
UPDATE endpoints SET forward_urls = ARRAY[forward_url] WHERE forward_url IS NOT NULL;
ALTER TABLE endpoints DROP COLUMN forward_url;

-- 2. Inbound events: execution_id → task_ids
ALTER TABLE inbound_events ADD COLUMN task_ids uuid[] NOT NULL DEFAULT '{}';
ALTER TABLE inbound_events DROP COLUMN execution_id;
```

### Endpoint schema (`endpoint.ex`)

- Replace `field :forward_url, :string` with `field :forward_urls, {:array, :string}, default: []`
- Changeset: cast `forward_urls`, validate required, validate each URL is valid HTTP(S)
- Tier limit on array length: free = 1 URL, pro = 10 URLs

### InboundEvent schema (`inbound_event.ex`)

- Remove `belongs_to :execution`
- Add `field :task_ids, {:array, Ecto.UUID}, default: []`
- Remove `execution_id` from `create_changeset` cast list

## Tier Limits

Update `@tier_limits` in `endpoints.ex`:

```elixir
@tier_limits %{
  "free" => %{max_endpoints: 3, max_forward_urls: 1},
  "pro" => %{max_endpoints: :unlimited, max_forward_urls: 10}
}
```

Free tier: 1 forward URL (same as today, no fan-out).
Pro tier: up to 10 forward URLs per endpoint.

Validated in `Endpoint.changeset/2` — check org tier and enforce max length of `forward_urls`.

## Receive Flow (changed)

Current: 1 webhook → 1 task → 1 execution
New: 1 webhook → N tasks → N executions (one per forward URL)

```elixir
def receive_event(%Endpoint{} = endpoint, attrs) do
  now = DateTime.utc_now() |> DateTime.truncate(:second)
  endpoint = Repo.preload(endpoint, :organization)
  org = endpoint.organization
  forward_headers = filter_forward_headers(attrs.headers || %{})

  result =
    Repo.transaction(fn ->
      # 1. Create inbound event (no task_ids yet)
      {:ok, event} = create_inbound_event(endpoint, attrs, now)

      # 2. For each forward URL, create task + execution
      task_ids =
        Enum.map(endpoint.forward_urls, fn url ->
          task_attrs = build_task_attrs(endpoint, event, attrs, forward_headers, url, now)
          {:ok, task} = Tasks.create_task(org, task_attrs, skip_next_run: true)
          {:ok, _execution} = Executions.create_execution_for_task(task, now)
          task.id
        end)

      # 3. Update event with task_ids
      event
      |> Ecto.Changeset.change(task_ids: task_ids)
      |> Repo.update!()
    end)

  # Notify workers once after transaction commits
  Tasks.notify_workers()
  result
end
```

Task naming includes destination index for clarity: `"Stripe webhooks · event a1b2c3d4 → 1/2"`.

## Replay

Replay creates new executions for ALL tasks linked to the event.

```elixir
def replay_event(%Endpoint{} = endpoint, %InboundEvent{} = event) do
  tasks = load_tasks_by_ids(event.task_ids)

  if Enum.empty?(tasks) do
    {:error, :no_tasks}
  else
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    executions =
      Enum.map(tasks, fn task ->
        {:ok, exec} = Executions.create_execution_for_task(task, now)
        exec
      end)

    Tasks.notify_workers()
    {:ok, executions}
  end
end
```

Returns `{:ok, [executions]}` instead of `{:ok, execution}`. Callers updated accordingly.

## Event Detail Page (LiveView)

Currently shows one execution. Changes to show a list of destinations.

### Preloading

`get_inbound_event!/2` loads tasks by `task_ids`, each with their latest execution:

```elixir
def get_inbound_event!(%Endpoint{} = endpoint, id) do
  event =
    InboundEvent
    |> where(endpoint_id: ^endpoint.id)
    |> Repo.get!(id)

  tasks = load_tasks_with_latest_execution(event.task_ids)
  Map.put(event, :tasks, tasks)
end
```

### UI

The "Forwarding" section becomes a list:

```
Forwarding (2 destinations)
┌──────────────────────────────────────────────┐
│ https://old-system.com/webhook               │
│ Status: success  │  200  │  124ms            │
│ [View Task] [View Execution]                 │
├──────────────────────────────────────────────┤
│ https://new-system.com/webhook               │
│ Status: pending  │  —    │  —                │
│ [View Task] [View Execution]                 │
└──────────────────────────────────────────────┘
```

For old events with empty `task_ids`: show "No forwarding data available".

### Events list (`show.ex`)

The events list on the endpoint show page currently shows one status badge per event. With fan-out, show aggregated status:
- All success → green "success"
- Any failed → red "failed"
- Any pending/running → blue "pending"
- Mixed → show count like "1/2 success"

## Endpoint Form (LiveView)

### Single URL (Free tier)

No change — one text input like today.

### Multiple URLs (Pro tier)

Dynamic list of URL inputs with add/remove buttons:

```
Forward URLs
┌─────────────────────────────────────────┐
│ https://old-system.com/webhook     [✕]  │
├─────────────────────────────────────────┤
│ https://new-system.com/webhook     [✕]  │
└─────────────────────────────────────────┘
[+ Add URL]
```

Form stores URLs as `forward_urls[]` params. The changeset handles the array.

## API Changes

### Endpoint Controller

**Create/Update:** Accept both for backward compat:
- `forward_urls` (array of strings) — primary field
- `forward_url` (string) — wraps in single-element array

Controller normalizes before passing to context:
```elixir
defp normalize_forward_urls(params) do
  cond do
    is_list(params["forward_urls"]) -> params
    is_binary(params["forward_url"]) -> Map.put(params, "forward_urls", [params["forward_url"]])
    true -> params
  end
end
```

**Response:** Always return `forward_urls` (array). Drop `forward_url` from response.

```json
{
  "data": {
    "id": "...",
    "name": "Stripe webhooks",
    "forward_urls": ["https://old.com/hook", "https://new.com/hook"],
    "inbound_url": "https://runlater.eu/in/ep_xxx",
    ...
  }
}
```

**Events response:** Replace `execution_id`/`execution_status` with `task_ids` and aggregated status:
```json
{
  "id": "...",
  "method": "POST",
  "source_ip": "1.2.3.4",
  "received_at": "...",
  "task_ids": ["uuid1", "uuid2"],
  "status": "success"
}
```

**Replay response:** Returns array of executions:
```json
{
  "data": {
    "executions": [
      {"execution_id": "...", "status": "pending", "scheduled_for": "..."},
      {"execution_id": "...", "status": "pending", "scheduled_for": "..."}
    ]
  },
  "message": "Event replayed to 2 destinations"
}
```

### OpenAPI Schemas

Update `EndpointSchema`:
- Replace `forward_url` (string) with `forward_urls` (array of strings)

Update `EndpointRequest`:
- Replace `forward_url` required field with `forward_urls` (array, required)

Update `InboundEvent` schema:
- Replace `execution_id`/`execution_status` with `task_ids` and `status`

Update `ReplayResponse`:
- Return array of executions

## SDK Changes (`runlater-js`)

Add `endpoints` sub-resource to the Runlater client:

```typescript
// Types
export interface Endpoint {
  id: string
  name: string
  slug: string
  inbound_url: string
  forward_urls: string[]
  enabled: boolean
  retry_attempts: number
  use_queue: boolean
  notify_on_failure: boolean | null
  notify_on_recovery: boolean | null
  inserted_at: string
  updated_at: string
}

export interface CreateEndpointOptions {
  name: string
  forward_urls: string[]
  retry_attempts?: number
  use_queue?: boolean
  enabled?: boolean
  notify_on_failure?: boolean | null
  notify_on_recovery?: boolean | null
}

export interface UpdateEndpointOptions {
  name?: string
  forward_urls?: string[]
  retry_attempts?: number
  use_queue?: boolean
  enabled?: boolean
  notify_on_failure?: boolean | null
  notify_on_recovery?: boolean | null
}

export interface InboundEvent {
  id: string
  method: string
  source_ip: string | null
  received_at: string
  task_ids: string[]
  status: string | null
}

export interface ReplayResponse {
  executions: Array<{
    execution_id: string
    status: string
    scheduled_for: string
  }>
}

// Client usage
const rl = new Runlater("sk_live_xxx")

// CRUD
const endpoint = await rl.endpoints.create({ name: "Stripe", forward_urls: ["https://..."] })
const endpoints = await rl.endpoints.list()
const endpoint = await rl.endpoints.get(id)
await rl.endpoints.update(id, { forward_urls: ["https://old.com", "https://new.com"] })
await rl.endpoints.delete(id)

// Events
const events = await rl.endpoints.events(endpointId)
const result = await rl.endpoints.replay(endpointId, eventId)
```

## Other Code References

### `get_last_event_status/1`

Used by badge controller. Currently preloads `execution`. Change to load tasks by `task_ids` from the latest event and aggregate status.

### `list_inbound_events/2`

Currently preloads `:execution`. Change to load tasks by `task_ids` for each event. Can use a single query to batch-load all tasks for all events in the list.

### `count_inbound_events/1`, `count_all_inbound_events/0`, `count_inbound_events_since/1`

No change — these just count events, not executions.

### Audit logging

`update_endpoint/4` currently tracks changes to `:forward_url`. Change to `:forward_urls`.

### Sync endpoint

If `/api/v1/sync` supports endpoints, update the sync body format to use `forward_urls`.

## Documentation Updates

All user-facing docs that reference `forward_url` or show endpoint examples need updating. Also add fan-out documentation.

| File | Changes |
|------|---------|
| `docs_html/endpoints.html.heex` | ~7 instances: update curl/Node.js examples, API field table, prose ("forwarded to your forward_url" → "forwarded to your forward URLs"). Add fan-out section explaining multiple URLs. |
| `docs_html/api.html.heex` | ~4 instances: update field docs in "Create Endpoint" section, curl/Node.js examples (Stripe webhook). |
| `docs_html/local_dev.html.heex` | 1 instance: update curl example creating a local endpoint. |
| `guides_html/webhook_proxy.html.heex` | ~5 instances: update JS fetch example, curl example, Stripe/GitHub setup scripts. |

### New documentation to add

In `docs_html/endpoints.html.heex`, add a **Fan-out** section covering:
- Use case: "Forward the same webhook to multiple destinations"
- Example: creating an endpoint with 2 forward URLs
- Behavior: each destination gets independent retries and status tracking
- Tier limits: Free = 1 URL, Pro = up to 10

## Files to Change

| File | Change |
|------|--------|
| Migration (new) | Add `forward_urls`, backfill, drop `forward_url`; add `task_ids`, drop `execution_id` |
| `lib/app/endpoints/endpoint.ex` | `forward_url` → `forward_urls`, changeset validation |
| `lib/app/endpoints/inbound_event.ex` | Remove `execution`, add `task_ids` field |
| `lib/app/endpoints.ex` | `receive_event` fan-out loop, `replay_event` multi-exec, query updates |
| `lib/app_web/controllers/api/endpoint_controller.ex` | Normalize `forward_url`→`forward_urls`, update JSON responses |
| `lib/app_web/controllers/inbound_controller.ex` | No change (calls `receive_event` which handles fan-out) |
| `lib/app_web/controllers/badge_controller.ex` | Update `get_last_event_status` usage if needed |
| `lib/app_web/live/endpoint_live/new.ex` | Multiple URL inputs for Pro |
| `lib/app_web/live/endpoint_live/edit.ex` | Multiple URL inputs for Pro |
| `lib/app_web/live/endpoint_live/show.ex` | Aggregated status in events list |
| `lib/app_web/live/endpoint_live/event_show.ex` | Show N destinations instead of 1 execution |
| `lib/app_web/schemas.ex` | Update OpenAPI schemas |
| `docs_html/endpoints.html.heex` | Update examples + add fan-out section |
| `docs_html/api.html.heex` | Update endpoint field docs and examples |
| `docs_html/local_dev.html.heex` | Update curl example |
| `guides_html/webhook_proxy.html.heex` | Update JS/curl/setup script examples |
| `runlater-sdks/src/types.ts` | Add endpoint types |
| `runlater-sdks/src/index.ts` | Add `Endpoints` class |
| Tests (new + updated) | Context, controller, LiveView tests |

## Verification

1. `mix test` — all existing tests pass
2. Create endpoint with 1 URL → same behavior as today
3. Create endpoint with 2 URLs (Pro) → webhook fans out to both
4. Event detail page shows both destinations with independent statuses
5. Replay resends to all destinations
6. API backward compat: `forward_url` string accepted, wrapped in array
7. Free tier rejects > 1 URL
8. SDK: `rl.endpoints.create(...)` works
9. `mix precommit` passes
