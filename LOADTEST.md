# Load Testing & Performance Optimization

## Summary

Multiple rounds of load testing on production, staging, and a dedicated 192 vCPU GCP instance revealed and eliminated bottlenecks. Starting from 50 req/s on old hardware, optimizations progressed through DB query fixes, connection pooling, Postgres tuning, and application-level caching to reach **1500 req/s on a 4-core dedicated server**, **4000 req/s on a 16 vCPU staging server**, and **17,000 req/s on a 192 vCPU GCP C4D** (direct to Phoenix, bypassing kamal-proxy).

Key discoveries:
- Docker's default `ulimit nofile=1024` was the single biggest throughput unlock early on
- **kamal-proxy TLS halves throughput** — 8k req/s through kamal-proxy vs 17k req/s direct to Phoenix on the same hardware
- **DB pool size is the hard ceiling** — 150 connections capped at 16k req/s; raising to 500 pushed past 17k
- **Workers competing for DB connections** during tests was the #1 source of inconsistent results

## Current Production Results (netcup, 4 dedicated AMD EPYC cores, 8GB RAM)

Server: 159.195.53.120. k6 run from remote (over internet + TLS). POOL_SIZE=150, max_connections=200, Docker ulimit=65536.

### Round 1: Baseline (POOL_SIZE=80, default Postgres)

| Rate | Success | p50 | p95 | Notes |
|------|---------|-----|-----|-------|
| **750/s** | **100%** | **145ms** | **509ms** | Clean |
| 850/s | 100% | 142ms | 2.28s | Threshold fail |

**Ceiling: ~750 req/s.**

### Round 2: Postgres WAL/IO tuning

Added: `wal_level=minimal`, `random_page_cost=1.1`, `effective_io_concurrency=200`, `max_wal_size=4GB`.

| Rate | Success | p50 | p95 | Notes |
|------|---------|-----|-----|-------|
| **850/s** | **100%** | **244ms** | **1.49s** | Now passes |
| 1000/s | 100% | 670ms | 3.53s | Threshold fail |

**Ceiling: ~850 req/s.** +13% from WAL/IO tuning.

### Round 3: synchronous_commit=off + POOL_SIZE=150

Added: `synchronous_commit=off`, `work_mem=16MB`, `maintenance_work_mem=512MB`, `max_connections=200`, `POOL_SIZE=150`. Kernel: `tcp_max_syn_backlog=4096`, `netdev_max_backlog=5000`, `vm.swappiness=10`.

| Rate | Success | p50 | p95 | Dropped | Notes |
|------|---------|-----|-----|---------|-------|
| **1000/s** | **100%** | **272ms** | **778ms** | **0** | Clean |
| **1150/s** | **100%** | **314ms** | **1.39s** | 538 | Clean |
| **1250/s** | **100%** | **470ms** | **1.60s** | 1,066 | Clean |
| **1300/s** | **100%** | **1.01s** | **1.84s** | 2,260 | **Sweet spot** |
| 1350/s | 100% | 1.87s | 2.41s | 10,016 | Threshold fail |

**Ceiling: ~1300 req/s.** Biggest wins: `synchronous_commit=off` and doubling DB pool from 80 to 150.

### Round 4: BEAM scheduler binding (+sbt db)

Added `ERL_FLAGS: "+sbt db"` to bind BEAM schedulers to CPU cores for better cache locality.

| Rate | Success | p50 | p95 | Dropped | Notes |
|------|---------|-----|-----|---------|-------|
| **1300/s** | **100%** | **985ms** | **1.70s** | 1,991 | Improved from 1.84s |
| 1350/s | 100% | 1.95s | 2.36s | 10,029 | Threshold fail |

**Ceiling: still ~1300 req/s.** p95 improved ~8% (1.84s -> 1.70s) but not enough to raise the ceiling.

### Round 5: Drop unused indexes

Dropped 4 task indexes with 0 scans (51 MB covering index, enabled, badge_token, deleted_at). Also tried dropping 2 execution indexes but the claim query regressed 2.50ms -> 5.09ms — rolled back immediately.

| Rate | Success | p50 | p95 | Dropped | Notes |
|------|---------|-----|-----|---------|-------|
| **1300/s** | **100%** | **922ms** | **1.74s** | 1,811 | Within noise |
| 1350/s | 100% | 1.82s | 2.31s | 10,344 | Threshold fail |

**Ceiling: still ~1300 req/s.** Task index drops had negligible impact. Execution indexes MUST NOT be dropped — even "barely used" indexes are critical for the worker claim query plan.

### Round 6: ETS cache for API key auth

Added ETS-based cache for API key lookups (`lib/app/api_key_cache.ex`). Every API request did 2 DB queries (`get_by` + `preload`) just for auth — now cached in ETS with 60s TTL. Also moved `last_used_at` debounce tracking to a second ETS table (was doing a DB query per request).

Also tried a CTE-based combined task+execution INSERT but it was **slower** than `Repo.transaction` on a same-server DB (query planning overhead > round-trip savings) — reverted.

| Rate | Success | p50 | p95 | Dropped | Notes |
|------|---------|-----|-----|---------|-------|
| **1000/s** | **100%** | **130ms** | **522ms** | **0** | Was 778ms |
| **1200/s** | **100%** | **204ms** | **614ms** | **0** | Was ~1.60s |
| **1300/s** | **100%** | **752ms** | **1.09s** | 350 | Was 1.70s |
| **1350/s** | **100%** | **393ms** | **1.36s** | 570 | Was 2.41s (fail) |
| **1400/s** | **100%** | **925ms** | **1.55s** | 866 | New |
| **1450/s** | **100%** | **520ms** | **1.24s** | 643 | **Sweet spot** |
| 1500/s | 90.5% | 1.28s | 2.44s | 2,417 | 9.5% errors |

**Ceiling: ~1450 req/s.** +12% over Round 5. ETS cache eliminates ~2 DB queries per request (~2900 queries/s saved at peak).

### Round 7: nginx TLS termination (reverted)

Hypothesis: Go's `crypto/tls` in kamal-proxy is slower than nginx/OpenSSL for TLS termination. Added nginx as a Kamal accessory in front of kamal-proxy: `Client → nginx (TLS on 443) → kamal-proxy (HTTP on 8080) → Phoenix (HTTP on 4000)`.

| Rate | Success | p50 | p95 | Errors | Notes |
|------|---------|-----|-----|--------|-------|
| **1250/s** | **100%** | **178ms** | **572ms** | **0%** | Clean |
| 1350/s | 88.5% | 1.15s | 1.73s | 11.4% | 503s + resets |
| 1450/s | 94.3% | 1.07s | 2.0s | 5.7% | 503s + resets |

**Result: nginx was SLOWER than kamal-proxy direct TLS.** The extra network hop added latency and connection overhead that outweighed any TLS crypto savings. At 1350 req/s, nginx had 11.4% errors vs 0% with kamal-proxy direct. Reverted.

Note: nginx container also needed `ulimit: nofile=65536:65536` — without it, `accept4() failed (24: No file descriptors available)` at ~1250 req/s.

### Round 8: Confirmed ceiling with proper test isolation

Previous rounds had inconsistent results at 1350-1450 req/s due to TCP TIME_WAIT from back-to-back runs. Thousands of sockets sit in TIME_WAIT for ~60s after each test. Running too quickly means the OS is still cleaning up connections from the previous run. Added 60s wait between runs for clean results.

| Rate | Success | p50 | p95 | Dropped | Notes |
|------|---------|-----|-----|---------|-------|
| **1300/s** | **100%** | **44ms** | **293ms** | 327 | Clean |
| **1350/s** | **100%** | **231ms** | **582ms** | 0 | Clean |
| **1400/s** | **100%** | **359ms** | **869ms** | 0 | Clean |
| **1450/s** | **100%** | **368ms** | **870ms** | 0 | Clean |
| **1500/s** | **100%** | **520ms** | **1.93s** | 1,410 | 0 errors but many dropped |

**Ceiling: ~1500 req/s.** With proper 60s isolation between runs, 1450 passes cleanly and 1500 is the practical limit (0 errors but p95 approaches 2s and iterations start dropping).

**Test methodology:** Always wait 60s between runs, delete loadtest data, and VACUUM FULL before re-testing. Even running `htop` on the server during a test can tip results at the margin.

## GCP C4D Results (192 vCPUs, 744GB RAM)

GCP c4d-standard-192-lssd (AMD EPYC Genoa). App + Postgres on same instance via Docker/Kamal. k6 run from same server. `deploy.loadtest.yml` config.

### Round 9: Through kamal-proxy (TLS)

POOL_SIZE=150, max_connections=300. k6 run from server to `https://load.runlater.eu`.

| Rate | Success | p95 | Dropped | Notes |
|------|---------|-----|---------|-------|
| **5,000/s** | **100%** | **22ms** | **0** | Very clean |
| **6,000/s** | **100%** | **115ms** | **0** | Clean |
| **7,000/s** | **100%** | **166ms** | **0** | Clean |
| **8,000/s** | **100%** | **82ms** | **0** | **Ceiling** |
| 9,000/s | 81% | 782ms | 5,179 | 18.8% failures |
| 10,000/s | 43% | 2.9s | 20,285 | 57% failures |

**kamal-proxy TLS ceiling: ~8,000 req/s.** Server CPU only at ~30% — kamal-proxy (single Go process doing TLS) is the bottleneck, not the app.

### Round 10: Direct to Phoenix (bypass kamal-proxy)

Hitting `http://<container-ip>:4000` directly — no TLS, no kamal-proxy.

**POOL_SIZE=150, max_connections=300:**

| Rate | Success | p95 | Dropped | Notes |
|------|---------|-----|---------|-------|
| **8,000/s** | **100%** | **48ms** | **0** | Half the p95 of kamal-proxy |
| **15,000/s** | **100%** | **396ms** | **0** | Clean |
| **16,000/s** | **100%** | **308ms** | **0** | Pool limit approaching |
| 17,000/s | 22% | — | — | DB pool exhausted |

**POOL_SIZE=500, max_connections=1000:**

| Rate | Success | p95 | Dropped | Notes |
|------|---------|-----|---------|-------|
| **17,000/s** | **100%** | **189ms** | **0** | Clean, ~50% CPU |
| 20,000/s | 29% | — | 87,531 | k6 + app competing for CPU |

**Direct Phoenix ceiling: ~17,000 req/s** (with pool=500). Server at ~50% CPU at 17k — not CPU-bound. The cliff at 20k is partly k6 itself (single Go process) competing with the app for CPU on the same server.

### Key takeaways from GCP testing

1. **kamal-proxy TLS halves throughput**: 8k vs 17k req/s on identical hardware. The Go `crypto/tls` single-process TLS termination is the bottleneck at scale, not CPU.
2. **DB pool is the hard ceiling**: 150 connections → 16k max. 500 connections → 17k+. Each API request holds a connection for the transaction duration.
3. **Workers compete with API for DB pool**: During a test, workers process created tasks and consume pool connections. Must wait 30+ seconds between tests for workers to drain, otherwise results are unreliable. Previous test failures at 7k-9k were caused by this.
4. **VACUUM FULL required between tests**: Regular VACUUM doesn't reclaim space fast enough after mass DELETEs. Dead tuples cause severe performance degradation.
5. **k6 on same server is a bottleneck above 17k**: At 20k+ req/s, k6 spawns 20k+ goroutines competing for CPU with the app and Postgres. Need a separate load generator for higher rates.

## Staging Results (CPX62, 16 vCPUs, 32GB RAM)

Hetzner CPX62 (~€30/mo). App + Postgres on same VPS. DB pool: 100. k6 run from inside Docker on same server (no network latency).

| Rate | Success | p95 | Tasks/s | Notes |
|------|---------|-----|---------|-------|
| 2000/s | **100%** | 97ms | 1399/s | Clean |
| 3000/s | **100%** | 139ms | 2108/s | Clean |
| 3500/s | **100%** | 456ms | 3452/s | Clean |
| **4000/s** | **100%** | **253ms** | **3986/s** | **Sweet spot** |
| 5000/s | 100% | 1.4s | 4544/s | 5% dropped iterations |
| 6000/s | 91% | 3.5s | 4481/s | Breaking down |

**Ceiling: ~4000 req/s sustained at 100% success, p95 253ms.**

## Key Bottlenecks Found (in order of impact)

1. **kamal-proxy TLS termination** — Single Go process doing TLS halves throughput (8k vs 17k req/s on 192 vCPU). The biggest bottleneck at scale.
2. **DB connection pool size** — 150 connections capped at ~16k req/s. Raising to 500 pushed past 17k. Each API request holds a connection for the transaction.
3. **Docker ulimit nofile=1024** — Capped throughput at ~900 req/s on every machine. Fix: `ulimit: nofile=65536:65536` in Kamal deploy config.
4. **DB query optimization** — Subqueries, missing indexes, redundant fetches. Fixed via denormalization, LATERAL joins, ETS buffering.
5. **Finch pool `count: 1`** — Serialized TLS handshakes through one process. Fixed to `count: 4`.
6. **API key auth queries** — 2 DB queries per request just for auth. Fixed with ETS cache (60s TTL). Saves ~2900 queries/s at peak.
7. **Rate limiter** — Default 500/min too low for load testing. Raised to 100k/min.
8. **nginx TLS termination** — Tested as alternative to kamal-proxy but was SLOWER due to extra hop overhead. Reverted.

## Capacity Estimates

| Hardware | Cost | API Throughput | Pool Size | Notes |
|----------|------|----------------|-----------|-------|
| netcup (4 dedicated) | ~€8/mo current prod | 1,500 req/s | 150 | Through kamal-proxy TLS |
| CX33 (4 shared) | ~€6/mo | 750 req/s | 80 | Through kamal-proxy TLS |
| CPX62 (16 vCPU) | ~€30/mo | 4,000 req/s | 100 | Through kamal-proxy TLS |
| GCP C4D (192 vCPU) | ~€5/hr spot | 8,000 req/s | 150 | Through kamal-proxy TLS |
| GCP C4D (192 vCPU) | ~€5/hr spot | 17,000 req/s | 500 | Direct to Phoenix (no TLS proxy) |

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
- `monthly_execution_count` on organizations
- `last_execution_at` on tasks

### 4. Eliminated redundant worker re-fetches
**File:** `lib/app/worker.ex`

Worker called `get_execution_with_task` multiple times per execution. Now reuses the preloaded task via `%{updated_execution | task: execution.task}`.

### 5. Replaced GROUP BY subquery with LATERAL join
**File:** `lib/app/tasks.ex`

The list_tasks query used a global GROUP BY to find latest execution per task. Replaced with a LATERAL join that does one index probe per task.

### 6. Denormalized `last_execution_at` onto tasks table
**Files:** `lib/app/tasks/task.ex`, `lib/app/tasks.ex`, `lib/app/executions.ex`, migration

Eliminated the JOIN entirely. Added `last_execution_at` column to tasks, updated on execution completion.

### 7. Fixed index sort order
**Migration:** `fix_tasks_list_index_sort_order`

Index was `(organization_id, last_execution_at ASC)` but the query sorts `DESC NULLS LAST`. Recreated as `(organization_id, last_execution_at DESC NULLS LAST, inserted_at DESC)`.

### 8. Preload task+org in claim_next_execution
**Files:** `lib/app/executions.ex`, `lib/app/worker.ex`

Moved the preload into the claim transaction and carried through the entire pipeline.

### 9. Replaced count(*) with has_more in task list API
**Files:** `lib/app_web/controllers/api/task_controller.ex`, `lib/app_web/schemas.ex`

`SELECT count(*)` was 515ms avg with 244k rows. Replaced with `has_more` boolean by fetching limit+1 rows.

### 10. Missing primary key index on tasks partition
**Migration:** `add_tasks_pkey_index`

The `tasks_default` partition had no primary key index. Every `WHERE id = $1` was a full sequential scan (65ms on 244k rows). With the index: 0.13ms.

### 11. DB connection pool error handling
**File:** `lib/app_web/plug_exception_overrides.ex` (new)

Pool exhaustion returned 500. Added `Plug.Exception` impl for `DBConnection.ConnectionError` to return 503.

### 12. Finch connection pool for HTTP workers
**Files:** `lib/app/application.ex`, `lib/app/worker.ex`

Workers made ephemeral HTTP connections — every request did a fresh TLS handshake. Added a named Finch pool with 25 connections that reuses TLS connections.

### 13. Postgres memory tuning
**File:** `config/deploy.yml`

Tuned to: shared_buffers=2GB, effective_cache_size=4GB, work_mem=64MB (was 128MB shared_buffers default).

### 14. Docker file descriptor limit
**File:** `config/deploy.yml`, `config/deploy.staging.yml`

Docker defaults to `ulimit nofile=1024`. At ~900 req/s, the container runs out of file descriptors. Fix: `ulimit: nofile=65536:65536`. This was the single biggest throughput unlock.

### 15. Postgres WAL and IO tuning
**File:** `config/deploy.yml`

After migrating to netcup: `wal_level=minimal`, `random_page_cost=1.1`, `effective_io_concurrency=200`, `max_wal_size=4GB`.

### 16. BEAM scheduler binding (+sbt db)
**File:** `config/deploy.yml`

Added `ERL_FLAGS: "+sbt db"` for CPU cache locality. ~8% p95 improvement at 1300 req/s.

### 17. Drop unused task indexes
**Migration:** `drop_unused_indexes`, `restore_execution_indexes`

Dropped 4 task indexes with 0 scans. Tried dropping 2 execution indexes but the claim query regressed — restored. Lesson: `idx_scan=0` doesn't mean unused.

### 18. ETS cache for API key auth
**Files:** `lib/app/api_key_cache.ex` (new), `lib/app/accounts.ex`, `lib/app/application.ex`

ETS cache with 60s TTL for API key lookups. Also moved `last_used_at` debounce tracking to ETS. Ceiling raised from 1300 to 1450 req/s (+12%).

Also attempted CTE-based combined INSERT but it was slower than `Repo.transaction` on same-server DB — reverted.

## Infrastructure Changes

- `pg_stat_statements` enabled
- DB pool: 20 -> 150 (prod), 80 (staging)
- Postgres shared memory: 64MB -> 256MB (`--shm-size`)
- Postgres tuned: shared_buffers=2GB, effective_cache_size=4GB, work_mem=64MB
- Postgres WAL/IO: wal_level=minimal, random_page_cost=1.1, effective_io_concurrency=200, max_wal_size=4GB
- Docker ulimit: nofile=65536:65536 (prod + staging)

## Profiling Commands

```bash
# Top queries by total time
ssh root@159.195.53.120 'docker exec runlater-db psql -U cronly -d cronly_prod -c "
  SELECT left(query, 120) as query, calls, round(mean_exec_time::numeric, 2) as avg_ms,
         round(total_exec_time::numeric, 0) as total_ms
  FROM pg_stat_statements
  WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  ORDER BY total_exec_time DESC LIMIT 15;
"'

# Reset stats between test runs
ssh root@159.195.53.120 'docker exec runlater-db psql -U cronly -d cronly_prod -c "SELECT pg_stat_statements_reset();"'

# Table sizes and dead tuples
ssh root@159.195.53.120 'docker exec runlater-db psql -U cronly -d cronly_prod -c "
  SELECT relname, n_live_tup, n_dead_tup,
         pg_size_pretty(pg_relation_size(relid)) as table_size,
         pg_size_pretty(pg_indexes_size(relid)) as index_size
  FROM pg_stat_user_tables ORDER BY n_live_tup DESC;
"'

# Check connection errors in app logs
ssh root@159.195.53.120 'docker logs $(docker ps --filter label=service=runlater --filter label=role=web -q) 2>&1 | grep -c "connection not available"'
```

## Scaling Path

The DB layer is fully optimized — all queries are sub-millisecond. The bottleneck at scale is kamal-proxy TLS termination (single Go process), then DB pool size.

1. **Now (4 dedicated cores, netcup)**: ~1,500 req/s through kamal-proxy TLS. Production server.
2. **CPX62 (16 vCPU, ~€30/mo)**: 4,000 req/s — tested on staging
3. **Bigger single server (e.g. 16-32 cores)**: kamal-proxy caps around 8k req/s regardless of core count
4. **Add TLS termination in front of kamal-proxy**: nginx or HAProxy doing TLS → kamal-proxy HTTP. Unlocks Phoenix's full throughput (~17k+ req/s on big hardware)
5. **Add second app node**: Kamal multi-host, SKIP LOCKED handles coordination — doubles capacity
6. **Separate DB server**: App gets all CPU cores, DB gets dedicated resources with its own pool
7. **Increase DB pool**: 150 → 500 connections pushed ceiling from 16k to 17k+. Scale pool with hardware.

Architecture supports horizontal scaling with zero code changes. The production bottleneck won't be hit for a very long time — 1,500 req/s on the current €8/mo server is enormous headroom.

## Historical Results

### Production Round 1 (CX33, 4 shared cores)

These results were **capped by Docker's 1024 FD limit**, not actual hardware.

| Change | Rate | p95 | Errors |
|--------|------|-----|--------|
| Baseline (60k rows) | 50 req/s | 4,900ms | - |
| Scoped list_tasks subquery | 50 req/s | 1,540ms | - |
| Fixed 3 hot-path bottlenecks | 50 req/s | 9,036ms | 16.52% |
| + LATERAL join for list_tasks | 50 req/s | 4,770ms | 0% |
| + Denormalized last_execution_at | 50 req/s | 808ms | 0% |
| + Fixed index sort order | 100 req/s | 520ms | 0% |
| + Preload in claim + ETS buffered timestamps | 250 req/s | 1,880ms | 0% |
| + Pool 20->40, removed count(*) from API | 300 req/s | 762ms | 0% |
| + Missing PK index on tasks partition | 300 req/s | 762ms | 0% |
| + Finch connection pool (TLS reuse) | **500 req/s** | **432ms** | **0%** |

### Staging (CX33, 4 shared cores, old production hardware)

| Rate | Success | p95 | Actual Throughput | Notes |
|------|---------|-----|-------------------|-------|
| **500/s** | **100%** | **505ms** | **483/s** | Clean |
| **750/s** | **100%** | **567ms** | **718/s** | Sweet spot |
| 1000/s | 100% | 2.55s | 818/s | Latency rising |
| 1500/s | 76% | 5.07s | 1150/s | Breaking down |

### Pool Size Comparison (CX33, 750 req/s)

| Pool Size | p95 | Avg | Throughput | Notes |
|-----------|-----|-----|------------|-------|
| 40 | 1.5s | ~800ms | 698/s | Pool contention |
| 60 | 941ms | ~500ms | 664/s | Better |
| **80** | **247ms** | **158ms** | **725/s** | **Optimal** |
| 100 | 673ms | ~400ms | 709/s | Diminishing returns |
| 120 | 282ms | ~170ms | 706/s | Close to 80 |
