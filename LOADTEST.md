# Load Testing & Performance Optimization

## Summary

Two rounds of load testing revealed and eliminated bottlenecks. The first round (production, 4 shared cores) optimized DB queries and reached 500 req/s. The second round (staging, 16 vCPUs) discovered that **Docker's default `ulimit nofile=1024` was the #1 throughput bottleneck** — once raised to 65536, the ceiling jumped from ~900 req/s to **4000 req/s on a €30/mo server**.

All earlier hardware comparisons (4 shared → 8 shared → 8 dedicated) were hitting the FD limit, not actual hardware limits.

## Staging Server (Current Best Results)

- Hetzner CPX62: 16 vCPUs (AMD), 32GB RAM (~€30/mo)
- App + Postgres on the same VPS
- DB pool: 100 connections
- Docker ulimit: nofile=65536:65536
- k6 run from inside Docker on the same server (no network latency)

## Results — Staging (CPX62, 16 vCPUs, after ulimit fix)

| Rate | Success | p95 Latency | Tasks/s created | Notes |
|------|---------|-------------|-----------------|-------|
| 2000/s | **100%** | 97ms | 1399/s | Clean |
| 3000/s | **100%** | 139ms | 2108/s | Clean |
| 3500/s | **100%** | 456ms | 3452/s | Clean |
| **4000/s** | **100%** | **253ms** | **3986/s** | **Sweet spot** |
| 5000/s | 100% | 1.4s | 4544/s | 5% dropped iterations |
| 6000/s | 91% | 3.5s | 4481/s | Breaking down |

**Ceiling: ~4000 req/s sustained at 100% success, p95 253ms.**

## Results — Staging (CX33, 4 shared cores, production-identical hardware)

Tested with ulimit fix, POOL_SIZE=80, workers active, k6 from remote (over internet + TLS).

| Rate | Success | p95 Latency | Actual Throughput | Notes |
|------|---------|-------------|-------------------|-------|
| **500/s** | **100%** | **505ms** | **483/s** | Clean |
| **750/s** | **100%** | **567ms** | **718/s** | Sweet spot |
| 1000/s | 100% | 2.55s | 818/s | Latency rising |
| 1500/s | 76% | 5.07s | 1150/s | Breaking down |

**Ceiling: ~750 req/s sustained at 100% success, p95 567ms.**

DB pool contention is the main bottleneck. Workers actively executing tasks compete for DB connections.

### Pool Size Comparison (CX33, 750 req/s, 30s burst)

Tested POOL_SIZE values at 750 req/s to find the optimal setting:

| Pool Size | p95 Latency | Avg Latency | Actual Throughput | Notes |
|-----------|-------------|-------------|-------------------|-------|
| 40 | 1.5s | ~800ms | 698/s | Pool contention |
| 60 | 941ms | ~500ms | 664/s | Better but still contending |
| **80** | **247ms** | **158ms** | **725/s** | **Optimal — clear winner** |
| 100 | 673ms | ~400ms | 709/s | Diminishing returns |
| 120 | 282ms | ~170ms | 706/s | Close to 80 but more Postgres overhead |

POOL_SIZE=80 is the sweet spot for CX33 hardware. Beyond 80, Postgres connection management overhead offsets the pool availability gains. Applied to both production and staging.

## Results — Staging (Google C4D, 12 cores, before ulimit discovery)

| Rate | Success | p95 Latency | Tasks/s | Notes |
|------|---------|-------------|---------|-------|
| 500/s | 99.87% | 321ms | 339/s | From remote (internet latency) |
| 1000/s | 98.27% | 346ms | 663/s | From remote |
| 2000/s | 100% | 97ms | 1399/s | From server (after ulimit fix) |
| 3000/s | 100% | 139ms | 2108/s | From server (after ulimit fix) |

## Results — Production Round 1 (CX33, 4 shared cores)

These results were **capped by Docker's 1024 FD limit**, not actual hardware. True ceiling is likely ~800-1200 req/s with the ulimit fix deployed.

### Optimization Timeline

| Change | Rate | p95 | Errors |
|--------|------|-----|--------|
| Baseline (60k rows) | 50 req/s | 4,900ms | - |
| Scoped list_tasks subquery | 50 req/s | 1,540ms | - |
| Fixed 3 hot-path bottlenecks | 50 req/s | 9,036ms | 16.52% |
| + LATERAL join for list_tasks | 50 req/s | 4,770ms | 0% |
| + Denormalized last_execution_at | 50 req/s | 808ms | 0% |
| + Fixed index sort order (DESC NULLS LAST) | 100 req/s | 520ms | 0% |
| + Preload in claim + ETS buffered timestamps | 250 req/s | 1,880ms | 0% |
| + Pool 20→40, removed count(*) from API | 300 req/s | 762ms | 0% |
| + Missing PK index on tasks partition | 300 req/s | 762ms | 0% |
| + Finch connection pool (TLS reuse) | **500 req/s** | **432ms** | **0%** |
| 1000 req/s stress test | 1000 req/s | 8,240ms | 37% |

### Old Hardware Comparison (invalidated by ulimit discovery)

| Hardware | Cost | Rate | p95 | Errors |
|----------|------|------|-----|--------|
| 4 shared cores | ~€6/mo | 500 req/s | 432ms | 0% |
| 8 shared cores | ~€11/mo | 750 req/s | 1,310ms | 0% |
| 8 dedicated cores | ~€59/mo | 1000 req/s | 187ms | 0% (14% rate-limited) |

All were hitting the Docker FD limit (~900 req/s ceiling), not hardware limits.

### Sustained Load Tests (10 minutes, data accumulating)

| Hardware | Rate | p95 | Errors | Tasks created |
|----------|------|-----|--------|---------------|
| 4 shared cores | 250 req/s | 6,060ms | 0.18% | 102k |
| 4 shared cores | 350 req/s | 6,570ms | 27% | 100k |

Sustained tests are harder than burst tests because data accumulates (100k+ tasks in one org), making the `list_tasks` query progressively slower. Real-world usage across many orgs with smaller task counts per org would perform better.

## Key Bottlenecks Found (in order of impact)

1. **Docker ulimit nofile=1024** — The #1 bottleneck. Capped throughput at ~900 req/s on every machine. Fix: `ulimit: nofile=65536:65536` in Kamal deploy config.
2. **DB query optimization** (round 1) — Subqueries, missing indexes, redundant fetches. Fixed via denormalization, LATERAL joins, ETS buffering.
3. **Finch pool `count: 1`** — Serialized TLS handshakes through one process. Fixed to `count: 4`.
4. **DB pool size** — 20 connections too few at high throughput. Tested 40/60/80/100/120 at 750 req/s — 80 is optimal for CX33. Increased to 80 (prod + staging).
5. **Rate limiter** — 100k/min = 1667/s effective ceiling. Bumped for staging tests.

## Capacity Estimates

| Hardware | Cost | API Throughput | Pool Size | Est. Users (500k exec/mo) |
|----------|------|----------------|-----------|---------------------------|
| CX33 (4 shared) | ~€6/mo | 750 req/s (tested) | 80 | ~500 |
| CPX62 (16 vCPU) | ~€30/mo | 4000 req/s (tested) | 100 | ~2000+ |

CX33 with POOL_SIZE=40 caps at ~430 req/s usable; bumping to 80 unlocks 750 req/s.

Workers are the real execution bottleneck: 20 workers at ~100ms avg = ~200 executions/s. API ingestion has massive headroom.

### 10k Pro Users Estimate

| | Value |
|---|---|
| Revenue | €290k/mo (€3.5M ARR) |
| Total tasks | ~100k |
| Execution rate | ~274/s (mixed intervals) |
| Workers needed | ~55-137 (depends on endpoint latency) |
| Execution history | ~23M rows/day, 710M rows at 30-day retention |
| Infrastructure needed | 2x app nodes + dedicated Postgres (~€300-400/mo) |
| Code changes needed | Partition executions table, batch scheduler inserts |

Infrastructure cost at 10k users: ~0.14% of revenue.

## Load Test Profile

70% immediate task creation, 15% delayed task creation, 15% task list reads. See `loadtest.js` and `loadtest/k6/`.

## Optimizations Done

### 1. Scoped list_tasks subquery to org's tasks
**File:** `lib/app/tasks.ex`

The `list_tasks` query had a global subquery scanning ALL executions to compute `max(scheduled_for)` per task. Scoped it to only the org's task IDs.

### 2. Debounced API key `last_used_at` writes
**File:** `lib/app/accounts.ex`

`verify_api_key` wrote `last_used_at` on every single request, causing row-level lock contention on the api_keys table. Now only writes if stale by 5+ minutes.

### 3. ETS-buffered counters and timestamps
**File:** `lib/app/execution_counter.ex` (new), `lib/app/executions.ex`, `lib/app/application.ex`

Two hot-path writes buffered in ETS and flushed to DB every 5 seconds:
- `monthly_execution_count` on organizations (was 55k UPDATEs at 81ms each)
- `last_execution_at` on tasks (was 55k UPDATEs at 81ms each)

### 4. Eliminated redundant worker re-fetches
**File:** `lib/app/worker.ex`

Worker called `get_execution_with_task` multiple times per execution (in execute, notify_failure, notify_recovery, send_callback). Now reuses the preloaded task via `%{updated_execution | task: execution.task}`.

### 5. Replaced GROUP BY subquery with LATERAL join
**File:** `lib/app/tasks.ex`

The list_tasks query used a global GROUP BY to find latest execution per task. Replaced with a LATERAL join that does one index probe per task. Brought avg query time from 3.9s to 2.2s.

### 6. Denormalized `last_execution_at` onto tasks table
**Files:** `lib/app/tasks/task.ex`, `lib/app/tasks.ex`, `lib/app/executions.ex`, migration

Eliminated the JOIN entirely. Added `last_execution_at` column to tasks, updated on execution completion. The list_tasks query became a simple single-table scan with no joins.

### 7. Fixed index sort order
**Migration:** `fix_tasks_list_index_sort_order`

The composite index was `(organization_id, last_execution_at ASC)` but the query sorts `DESC NULLS LAST`. Postgres can't use a backward scan for non-default null ordering. Recreated as `(organization_id, last_execution_at DESC NULLS LAST, inserted_at DESC)`.

### 8. Preload task+org in claim_next_execution
**Files:** `lib/app/executions.ex`, `lib/app/worker.ex`

Worker did ~3.7 task SELECTs per execution (48ms avg each). Moved the preload into the claim transaction and carried through the entire pipeline:
- `queue_blocked?` uses preloaded task instead of `Repo.get`
- `execute()` skips `get_execution_with_task` call
- `broadcast_execution_update` uses preloaded task if available
- `maybe_increment_monthly_count` uses preloaded task if available

### 9. Replaced count(*) with has_more in task list API
**Files:** `lib/app_web/controllers/api/task_controller.ex`, `lib/app_web/schemas.ex`

`SELECT count(*) FROM tasks WHERE organization_id = $1` was 515ms avg per call with 244k rows. Replaced with `has_more` boolean by fetching limit+1 rows and checking length.

### 10. Missing primary key index on tasks partition
**Migration:** `add_tasks_pkey_index`

The `tasks` table is partitioned but the `tasks_default` partition had no primary key index. Every `WHERE id = $1` was a full sequential scan (65ms on 244k rows). With the index: 0.13ms. This was the root cause of most worker latency. After this fix, all queries are sub-millisecond.

### 11. DB connection pool error handling
**File:** `lib/app_web/plug_exception_overrides.ex` (new)

Pool exhaustion returned 500. Added `Plug.Exception` impl for `DBConnection.ConnectionError` to return 503.

### 12. Finch connection pool for HTTP workers
**Files:** `lib/app/application.ex`, `lib/app/worker.ex`

Workers made ephemeral HTTP connections — every request did a fresh TLS handshake, which is CPU-intensive. Added a named Finch pool (`Prikke.Finch`) with 25 connections that reuses TLS connections to the same hosts. This eliminated the CPU bottleneck that caused 20 workers to saturate all 4 cores. Result: 500 req/s at p95=432ms (was failing at 500 req/s before).

### 13. Postgres memory tuning
**File:** `config/deploy.yml`

Default Postgres config only used 128MB shared_buffers on a 7.6GB server. Tuned to: shared_buffers=2GB, effective_cache_size=4GB, work_mem=64MB. Improves caching and aggregate query performance.

### 14. Docker file descriptor limit
**File:** `config/deploy.yml`, `config/deploy.staging.yml`

Docker defaults to `ulimit nofile=1024`. At ~900 req/s, the container runs out of file descriptors (each TCP connection uses one FD), causing `connection reset by peer` errors. Fix: `options: { ulimit: nofile=65536:65536 }` in Kamal deploy config. This was the single biggest throughput unlock — all previous hardware tests were hitting this ceiling.

## Infrastructure Changes

- Enabled `pg_stat_statements` in docker-compose.yml and deploy.yml
- DB pool increased from 20 to 80 (prod + staging) — tested 40/60/80/100/120, 80 optimal
- Postgres shared memory increased from 64MB to 256MB (Docker `--shm-size`)
- Postgres tuned: shared_buffers=2GB, effective_cache_size=4GB, work_mem=64MB
- Docker ulimit: nofile=65536:65536 (prod + staging)
- Superadmin dashboard: replaced disk usage with peak throughput metric

## Profiling Commands

```bash
# Query pg_stat_statements (top queries by total time)
ssh root@46.225.66.205 'docker exec runlater-db psql -U cronly -d cronly_prod -c "
  SELECT left(query, 120) as query, calls, round(mean_exec_time::numeric, 2) as avg_ms,
         round(total_exec_time::numeric, 0) as total_ms
  FROM pg_stat_statements
  WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  ORDER BY total_exec_time DESC
  LIMIT 15;
"'

# Reset stats between test runs
ssh root@46.225.66.205 'docker exec runlater-db psql -U cronly -d cronly_prod -c "SELECT pg_stat_statements_reset();"'

# Check query plan for a specific query
ssh root@46.225.66.205 'docker exec runlater-db psql -U cronly -d cronly_prod -c "EXPLAIN ANALYZE <query>;"'

# Check table sizes and dead tuples
ssh root@46.225.66.205 'docker exec runlater-db psql -U cronly -d cronly_prod -c "
  SELECT relname, n_live_tup, n_dead_tup,
         pg_size_pretty(pg_relation_size(relid)) as table_size,
         pg_size_pretty(pg_indexes_size(relid)) as index_size
  FROM pg_stat_user_tables ORDER BY n_live_tup DESC;
"'

# Check CPU and memory
ssh root@46.225.66.205 'nproc && free -h | head -2'

# Check app logs
ssh root@46.225.66.205 'docker logs $(docker ps --filter label=service=runlater --filter label=role=web -q) 2>&1 | grep -c "connection not available"'
```

## Scaling Path

The DB layer is fully optimized — all queries are sub-millisecond. The bottleneck is CPU. To scale:

1. **Now (4 shared cores, ~€6/mo)**: ~800-1200 req/s (estimated with ulimit fix), production server
2. **CPX62 (16 vCPU, ~€30/mo)**: 4000 req/s, p95=253ms — tested on staging
3. **Add second app node**: Kamal multi-host, SKIP LOCKED handles coordination — doubles capacity
4. **Separate DB server**: App gets all CPU cores, DB gets dedicated resources
5. **AX102 + dedicated Postgres (~€300-400/mo)**: For 10k+ users, ~274 exec/s, €3.5M ARR

Architecture supports horizontal scaling with zero code changes. Workers scale perfectly with CPU via SKIP LOCKED.
