# Load Testing & Performance Optimization

## Summary

Load testing at 50-500 req/s revealed and eliminated several bottlenecks. Through iterative profiling with `pg_stat_statements` and targeted fixes, the API now handles **300 req/s with p95=762ms and 0% errors** on a single 4-core VPS. The hard ceiling is ~400-500 req/s due to CPU saturation.

## Server

- 4 CPU cores, 7.6GB RAM
- App + Postgres on the same VPS
- DB pool: 40 connections
- Postgres max_connections: 100

## Results Timeline

| Change | Rate | p95 | Errors |
|--------|------|-----|--------|
| Baseline (60k rows) | 50 req/s | 4,900ms | - |
| Scoped list_tasks subquery | 50 req/s | 1,540ms | - |
| Fixed 3 hot-path bottlenecks | 50 req/s | 9,036ms | 16.52% |
| + LATERAL join for list_tasks | 50 req/s | 4,770ms | 0% |
| + Denormalized last_execution_at | 50 req/s | 808ms | 0% |
| + Fixed index sort order (DESC NULLS LAST) | 100 req/s | 520ms | 0% |
| + Preload in claim + ETS buffered timestamps | 250 req/s | 1,880ms | 0% |
| + Pool 20→40, removed count(*) from API | 300 req/s | **762ms** | **0%** |
| + Missing PK index on tasks partition | 300 req/s | **762ms** | **0%** |
| 500 req/s stress test (all optimizations) | 500 req/s | 6,120ms | 24.4% |

## Load Test Profile

70% immediate task creation, 15% delayed task creation, 15% task list reads. See `loadtest.js`.

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

## Infrastructure Changes

- Enabled `pg_stat_statements` in docker-compose.yml and deploy.yml
- DB pool increased from 20 to 40
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
ssh root@46.225.66.205 'docker logs <container> 2>&1 | grep -c "connection not available"'
```

## Current Ceiling

At **300 req/s**: p95=762ms, 0% errors — all queries sub-millisecond.

At **500 req/s**: p95=6.1s, 24% errors — DB is still fast (all sub-ms), bottleneck is CPU saturation on the 4-core VPS (app + Postgres share cores). No DB pool exhaustion errors.

## Scaling Beyond 500 req/s

The DB layer is fully optimized — all queries are sub-millisecond. To go higher:

- **More CPU cores**: Bigger VPS or dedicated DB server
- **Second app node**: Kamal supports multi-host, Postgres SKIP LOCKED handles multi-worker coordination
- **Separate DB server**: Move Postgres to its own VPS so app gets all 4 cores
- **Per-org worker fairness**: Limit each org to 1 concurrent worker so slow endpoints can't starve others
- **Execution cleanup**: Periodic cleanup based on retention policy keeps tables lean
