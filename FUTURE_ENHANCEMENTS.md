# Future Enhancements

## Degraded Mode: Postgres Resilience

### Goal
Keep the app running jobs even when Postgres is down, with at-least-once delivery semantics.

### Architecture

```
Normal operation:
  Postgres ←→ App (full features, SKIP LOCKED, etc.)
       ↓
      ETS (read cache, kept in sync)

Degraded mode (Postgres down):
  ETS (jobs cache) → Scheduler → Workers → DETS (buffered results)

Recovery:
  Postgres back → flush DETS → re-sync ETS
```

### Components

#### 1. Jobs Cache GenServer (`lib/app/jobs/cache.ex`)

- ETS table for job schedule (in-memory, fast reads)
- DETS file for buffered execution results (survives restart)
- Detects Postgres failures on query errors (not polling)
- Reconnect attempts with backoff while down
- Flushes buffer and re-syncs on reconnect

```elixir
defmodule App.Jobs.Cache do
  use GenServer
  require Logger

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(_) do
    :ets.new(:jobs, [:named_table, :set, :public, read_concurrency: true])
    :dets.open_file(:pending_results, file: ~c"priv/pending_results.dets")

    sync_from_db()

    {:ok, %{postgres_up: true}}
  end

  # Public API
  def all_enabled_jobs do
    :ets.match_object(:jobs, {:_, %{enabled: true}})
    |> Enum.map(fn {_id, job} -> job end)
  end

  def get_job(id) do
    case :ets.lookup(:jobs, id) do
      [{^id, job}] -> job
      [] -> nil
    end
  end

  def put_job(job) do
    :ets.insert(:jobs, {job.id, job})
  end

  def buffer_result(execution) do
    :dets.insert(:pending_results, {execution.id, execution})
  end

  def postgres_up? do
    GenServer.call(__MODULE__, :postgres_up?)
  end

  # Called by Repo wrapper when query fails
  def mark_postgres_down do
    GenServer.cast(__MODULE__, :postgres_down)
  end

  # Called by Repo wrapper when query succeeds after being down
  def mark_postgres_up do
    GenServer.cast(__MODULE__, :postgres_up)
  end

  # Callbacks
  def handle_call(:postgres_up?, _from, state) do
    {:reply, state.postgres_up, state}
  end

  def handle_cast(:postgres_down, %{postgres_up: true} = state) do
    Logger.warning("Postgres down, entering degraded mode")
    schedule_reconnect()
    {:noreply, %{state | postgres_up: false}}
  end

  def handle_cast(:postgres_down, state), do: {:noreply, state}

  def handle_cast(:postgres_up, %{postgres_up: false} = state) do
    Logger.info("Postgres back, flushing buffer")
    flush_pending_results()
    sync_from_db()
    {:noreply, %{state | postgres_up: true}}
  end

  def handle_cast(:postgres_up, state), do: {:noreply, state}

  def handle_info(:try_reconnect, %{postgres_up: false} = state) do
    case App.Repo.query("SELECT 1") do
      {:ok, _} ->
        Logger.info("Postgres reconnected")
        flush_pending_results()
        sync_from_db()
        {:noreply, %{state | postgres_up: true}}
      _ ->
        schedule_reconnect()
        {:noreply, state}
    end
  end

  def handle_info(:try_reconnect, state), do: {:noreply, state}

  def handle_info(:sync_from_db, state) do
    if state.postgres_up, do: sync_from_db()
    Process.send_after(self(), :sync_from_db, :timer.seconds(30))
    {:noreply, state}
  end

  defp schedule_reconnect do
    Process.send_after(self(), :try_reconnect, :timer.seconds(5))
  end

  defp sync_from_db do
    try do
      App.Jobs.list_enabled_jobs()
      |> Enum.each(&put_job/1)
    rescue
      _ -> :ok
    end
  end

  defp flush_pending_results do
    :dets.foldl(fn {id, execution}, acc ->
      case App.Executions.insert_execution(execution) do
        {:ok, _} -> :dets.delete(:pending_results, id)
        _ -> :ok
      end
      acc
    end, :ok, :pending_results)
  end
end
```

#### 2. Resilient Repo Wrapper (`lib/app/repo/resilient.ex`)

Wraps Repo calls to detect failures:

```elixir
defmodule App.Repo.Resilient do
  def query(sql, params \\ []) do
    case App.Repo.query(sql, params) do
      {:ok, result} ->
        App.Jobs.Cache.mark_postgres_up()
        {:ok, result}
      {:error, _} = error ->
        App.Jobs.Cache.mark_postgres_down()
        error
    end
  end
end
```

#### 3. Scheduler Modifications

```elixir
defp get_due_jobs do
  if App.Jobs.Cache.postgres_up?() do
    # Normal: use Postgres with FOR UPDATE SKIP LOCKED
    App.Jobs.claim_due_jobs()
  else
    # Degraded: run from cache, accept possible duplicates
    Logger.warning("Running in degraded mode - Postgres unavailable")
    App.Jobs.Cache.all_enabled_jobs()
    |> Enum.filter(&job_is_due?/1)
  end
end

defp save_execution(execution) do
  if App.Jobs.Cache.postgres_up?() do
    App.Executions.create(execution)
  else
    App.Jobs.Cache.buffer_result(execution)
    {:ok, execution}
  end
end
```

#### 4. Supervision Tree

```elixir
# lib/app/application.ex
children = [
  App.Repo,
  App.Jobs.Cache,  # Start after Repo
  App.Scheduler,
  # ...
]
```

### Trade-offs

| Aspect | Behavior |
|--------|----------|
| Normal operation | Full Postgres features, SKIP LOCKED deduplication |
| During outage | Jobs run from ETS, at-least-once delivery |
| After recovery | Results flush, cache re-syncs |
| Server restart during outage | DETS preserves buffered results |

### Accepted Limitations

- No deduplication during degraded mode (at-least-once, not exactly-once)
- New jobs via API during outage might be lost on restart (ETS is memory-only)
- Brief window of stale cache if Postgres changes while healthy

### Uptime Impact

With 99.7% per-service uptime:

| Configuration | Effective Uptime |
|---------------|------------------|
| 2 app + 1 PG (no degraded mode) | 99.69% (~26 hrs/year down) |
| 2 app + 1 PG (with degraded mode) | ~99.999% (~5 min/year down) |

---

## Multi-Server Setup with Load Balancing

### DIY Learning Setup

For learning infrastructure concepts, set up:

1. **HAProxy + Keepalived** on two servers
2. **Hetzner Floating IP** for failover
3. **Manual failover testing**

```
         Floating IP
              ↓
    ┌─────────────────────┐
    │    Keepalived       │  (VRRP, moves IP between LBs)
    └──────────┬──────────┘
               ↓
    ┌─────────────────────┐
    │  HAProxy (active)   │  (load balances + health checks)
    └──────────┬──────────┘
               ↓
    ┌──────────┴──────────┐
    │                     │
 Server 1             Server 2
```

### Production Recommendation

Use Hetzner Load Balancer (~€5/mo) instead of DIY until scale justifies complexity.

---

## Postgres High Availability

### Simple Approach (Recommended for Current Scale)

- Dedicated Postgres server
- Hourly backups with `pg_dump`
- Offsite sync to Hetzner Storage Box
- 15-30 minute recovery time acceptable
- App continues in degraded mode during outage

### Future: pg_auto_failover

When downtime cost exceeds operational complexity:

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Monitor   │ ←── │   Primary   │ ──→ │   Standby   │
│  (witness)  │ ←── │  (node 1)   │     │  (node 2)   │
└─────────────┘     └─────────────┘     └─────────────┘
```

Consider when:
- 30 min downtime costs real money
- Enterprise customers require SLAs
- Past ~€10k MRR
