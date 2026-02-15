# Load Testing

## Setup

### 1. Mock Endpoint (on a separate cheap VPS)

```bash
# Build and run
cd loadtest/mock-endpoint
docker build -t mock-endpoint .
docker run -d -p 8080:8080 --name mock mock-endpoint

# Verify
curl http://localhost:8080/?delay=100
```

Query params:
- `?delay=100` — fixed 100ms delay
- `?jitter=500` — random 0-500ms delay
- `?status=503` — return specific status code
- `?fail_rate=10` — 10% of requests return 500

### 2. Staging App (on beefy VPS)

```bash
# Update config/deploy.staging.yml with server IP
# Update .kamal/secrets-staging with credentials
cd app
kamal setup -d staging
```

### 3. Create Test Org + API Key

SSH into staging and create a test organization with an API key via IEx:

```bash
kamal app exec -d staging -i 'bin/app remote'
```

```elixir
# Create test user + org
{:ok, user} = Prikke.Accounts.register_user(%{email: "loadtest@runlater.eu", password: "loadtest123456"})
Prikke.Accounts.confirm_user(user)
org = Prikke.Accounts.get_user_organization(user)

# Upgrade to pro (no tier limits during loadtest)
Prikke.Accounts.update_organization(org, %{tier: "pro"})

# Create API key
{:ok, api_key, raw_key} = Prikke.Accounts.create_api_key(org, user, %{name: "loadtest"})
IO.puts("API Key: #{raw_key}")
```

### 4. Run Load Tests

Install k6: https://k6.io/docs/get-started/installation/

```bash
# Queue throughput test (ramps up to 500 req/s)
k6 run \
  -e BASE_URL=https://staging.runlater.eu \
  -e API_KEY=sk_live_xxx \
  -e MOCK_URL=http://mock-server-ip:8080 \
  loadtest/k6/queue-throughput.js

# Sustained load test (50 req/s for 10 minutes)
k6 run \
  -e BASE_URL=https://staging.runlater.eu \
  -e API_KEY=sk_live_xxx \
  -e MOCK_URL=http://mock-server-ip:8080 \
  loadtest/k6/sustained-load.js
```

## What to Watch

During the load test, SSH into the staging server and monitor:

```bash
# App logs
kamal app logs -d staging -f

# DB stats (connect to postgres)
docker exec -it runlater-db psql -U cronly runlater_staging

# Useful queries:
SELECT count(*) FROM executions WHERE status = 'pending';
SELECT count(*) FROM executions WHERE status = 'running';
SELECT pg_size_pretty(pg_total_relation_size('tasks'));
SELECT pg_size_pretty(pg_total_relation_size('executions'));
```

Also check the superadmin dashboard at `https://staging.runlater.eu/superadmin` for real-time metrics.
