# Prikke Implementation Progress

## Current Status: Phase 2 - Complete

### What's Done

#### Phase 1: Project Setup (Complete)
- Erlang 28.3, Elixir 1.19.5-otp-28, Phoenix 1.8.3
- PostgreSQL 18 via Docker Compose
- UUID primary keys, health check endpoint
- Landing page and documentation pages
- Deployed to Koyeb (Frankfurt)

#### Phase 2: Authentication & Organizations (Complete)
- **User Auth** via `mix phx.gen.auth`
  - Email/password registration and login
  - Magic link authentication
  - Session management
  - Password reset flow

- **Organizations**
  - Schema: name, slug (unique), tier (free/pro)
  - Users create orgs and become owner
  - Slug validation (lowercase, hyphens, numbers only)

- **Memberships**
  - Links users to organizations
  - Roles: owner, admin, member
  - Role hierarchy checking (`has_role?/3`)

- **API Keys**
  - Format: `pk_live_xxx.sk_live_yyy`
  - Public key_id + hashed secret
  - Tracks created_by user and last_used_at
  - Secure verification with timing-safe comparison

- **API Auth Plug**
  - Authenticates via `Authorization: Bearer` header
  - Assigns `current_organization` to connection
  - Returns 401 for invalid/missing keys

- **Tests**: 114 passing

### Files Created/Modified (Phase 2)
```
app/lib/app/accounts/
├── user.ex                    # Added memberships/organizations relations
├── organization.ex            # NEW: org schema
├── membership.ex              # NEW: user-org link with role
└── api_key.ex                 # NEW: API key schema with generation

app/lib/app/accounts.ex        # Added org, membership, API key functions

app/lib/app_web/plugs/
└── api_auth.ex                # NEW: API authentication plug

app/priv/repo/migrations/
├── *_create_users_auth_tables.exs
└── *_create_organizations.exs  # orgs, memberships, api_keys

app/test/
├── app/accounts_test.exs       # Added org, membership, API key tests
└── app_web/plugs/api_auth_test.exs  # NEW: API auth tests
```

### Next: Phase 3 - Core Domain (Jobs & Executions)

Create the Jobs and Executions schemas:

```elixir
# Jobs schema
schema "jobs" do
  belongs_to :organization, Organization
  field :key, :string           # unique per org, for idempotent API
  field :name, :string
  field :url, :string
  field :method, :string        # GET, POST
  field :headers, :map
  field :body, :string
  field :schedule_type, :string # "cron" or "once"
  field :cron_expression, :string
  field :scheduled_at, :utc_datetime
  field :enabled, :boolean
  field :timeout_ms, :integer
end

# Executions schema
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
  field :attempt, :integer
end
```

### Local Development Commands
```bash
# Start PostgreSQL
cd app && docker compose up -d

# Start Phoenix server
cd app && mix phx.server
# Visit http://localhost:4000

# Run tests
cd app && mix test

# Interactive console
cd app && iex -S mix
```

### Koyeb Configuration
```
GitHub repo: gautema/prikke
Root directory: app
Builder: Dockerfile
Port: 8000
Health check: /health

Environment variables:
- DATABASE_URL (from Koyeb managed Postgres)
- SECRET_KEY_BASE
- PHX_HOST=prikke.whitenoise.no
```

### URLs
- App: https://prikke.whitenoise.no
- API: https://prikke.whitenoise.no/api
- Register: https://prikke.whitenoise.no/users/register

---
Last updated: 2026-01-28
