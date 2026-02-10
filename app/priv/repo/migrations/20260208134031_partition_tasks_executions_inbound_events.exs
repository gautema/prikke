defmodule Prikke.Repo.Migrations.PartitionTasksExecutionsInboundEvents do
  use Ecto.Migration

  @doc """
  Recreates tasks, executions, and inbound_events as range-partitioned tables
  with DEFAULT partitions. Tables are empty so no data migration needed.

  Partition keys:
    - tasks: scheduled_at (cron tasks with NULL go to DEFAULT)
    - executions: scheduled_for
    - inbound_events: received_at

  FKs dropped (columns kept):
    - executions.task_id → tasks.id (tasks is partitioned, can't have UNIQUE(id))
    - inbound_events.execution_id → executions.id (executions is partitioned)

  FKs kept:
    - tasks.organization_id → organizations.id (organizations is not partitioned)
    - inbound_events.endpoint_id → endpoints.id (endpoints is not partitioned)
  """

  def up do
    # ── 1. Drop tables in FK order ──────────────────────────────────────
    drop table(:inbound_events)
    drop table(:executions)
    drop table(:tasks)

    # ── 2. Create tasks (partitioned by scheduled_at) ───────────────────
    # scheduled_at is nullable (NULL for cron tasks → DEFAULT partition)
    # so we cannot have a database-level PRIMARY KEY (PK requires NOT NULL).
    # Ecto's @primary_key is application-level and UUID7 ensures uniqueness.
    execute """
    CREATE TABLE tasks (
      id uuid NOT NULL,
      organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
      name varchar(255) NOT NULL,
      url varchar(255) NOT NULL,
      method varchar(255) NOT NULL DEFAULT 'GET',
      headers jsonb DEFAULT '{}',
      body text,
      schedule_type varchar(255) NOT NULL,
      cron_expression varchar(255),
      interval_minutes integer,
      scheduled_at timestamp(0),
      enabled boolean NOT NULL DEFAULT true,
      retry_attempts integer NOT NULL DEFAULT 3,
      timeout_ms integer NOT NULL DEFAULT 30000,
      next_run_at timestamp(0),
      muted boolean NOT NULL DEFAULT false,
      callback_url varchar(255),
      expected_status_codes text,
      expected_body_pattern text,
      queue varchar(255),
      inserted_at timestamp(0) NOT NULL,
      updated_at timestamp(0) NOT NULL,
      CONSTRAINT valid_schedule CHECK (
        (schedule_type = 'cron' AND cron_expression IS NOT NULL) OR
        (schedule_type = 'once' AND scheduled_at IS NOT NULL)
      )
    ) PARTITION BY RANGE (scheduled_at)
    """

    execute "CREATE TABLE tasks_default PARTITION OF tasks DEFAULT"

    execute "CREATE INDEX tasks_organization_id_idx ON tasks (organization_id)"
    execute "CREATE INDEX tasks_enabled_idx ON tasks (enabled) WHERE enabled = true"

    execute """
    CREATE INDEX tasks_enabled_next_run_at_idx ON tasks (enabled, next_run_at)
    WHERE enabled = true
    """

    execute """
    CREATE INDEX tasks_schedule_type_scheduled_at_idx ON tasks (schedule_type, scheduled_at)
    WHERE schedule_type = 'once'
    """

    execute """
    CREATE INDEX tasks_organization_id_queue_idx ON tasks (organization_id, queue)
    WHERE queue IS NOT NULL
    """

    # ── 3. Create executions (partitioned by scheduled_for) ─────────────
    # task_id FK dropped (tasks is partitioned, no UNIQUE(id))
    execute """
    CREATE TABLE executions (
      id uuid NOT NULL,
      task_id uuid NOT NULL,
      status varchar(255) NOT NULL DEFAULT 'pending',
      scheduled_for timestamp(0) NOT NULL,
      started_at timestamp(0),
      finished_at timestamp(0),
      status_code integer,
      duration_ms integer,
      response_body text,
      error_message text,
      attempt integer NOT NULL DEFAULT 1,
      callback_url varchar(255),
      inserted_at timestamp(0) NOT NULL,
      updated_at timestamp(0) NOT NULL,
      PRIMARY KEY (id, scheduled_for)
    ) PARTITION BY RANGE (scheduled_for)
    """

    execute "CREATE TABLE executions_default PARTITION OF executions DEFAULT"

    execute "CREATE INDEX executions_task_id_idx ON executions (task_id)"

    execute "CREATE INDEX executions_task_id_scheduled_for_idx ON executions (task_id, scheduled_for)"

    execute "CREATE INDEX executions_status_scheduled_for_idx ON executions (status, scheduled_for)"

    execute """
    CREATE INDEX executions_pending_status_idx ON executions (status)
    WHERE status = 'pending'
    """

    # ── 4. Create inbound_events (partitioned by received_at) ───────────
    # execution_id FK dropped (executions is partitioned, no UNIQUE(id))
    # endpoint_id FK kept (endpoints is not partitioned)
    execute """
    CREATE TABLE inbound_events (
      id uuid NOT NULL,
      endpoint_id uuid NOT NULL REFERENCES endpoints(id) ON DELETE CASCADE,
      method varchar(255) NOT NULL,
      headers jsonb DEFAULT '{}',
      body text,
      source_ip varchar(255),
      execution_id uuid,
      received_at timestamp(0) NOT NULL,
      inserted_at timestamp(0) NOT NULL,
      updated_at timestamp(0) NOT NULL,
      PRIMARY KEY (id, received_at)
    ) PARTITION BY RANGE (received_at)
    """

    execute "CREATE TABLE inbound_events_default PARTITION OF inbound_events DEFAULT"

    execute "CREATE INDEX inbound_events_endpoint_id_received_at_idx ON inbound_events (endpoint_id, received_at)"
  end

  def down do
    # Drop partitioned tables
    drop table(:inbound_events)
    drop table(:executions)
    drop table(:tasks)

    # Recreate original non-partitioned tables
    create table(:tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :url, :string, null: false
      add :method, :string, default: "GET", null: false
      add :headers, :map, default: %{}
      add :body, :text
      add :schedule_type, :string, null: false
      add :cron_expression, :string
      add :interval_minutes, :integer
      add :scheduled_at, :utc_datetime
      add :enabled, :boolean, default: true, null: false
      add :retry_attempts, :integer, default: 3, null: false
      add :timeout_ms, :integer, default: 30000, null: false
      add :next_run_at, :utc_datetime
      add :muted, :boolean, default: false, null: false
      add :callback_url, :string
      add :expected_status_codes, :text
      add :expected_body_pattern, :text
      add :queue, :string

      timestamps(type: :utc_datetime)
    end

    execute """
    ALTER TABLE tasks ADD CONSTRAINT valid_schedule CHECK (
      (schedule_type = 'cron' AND cron_expression IS NOT NULL) OR
      (schedule_type = 'once' AND scheduled_at IS NOT NULL)
    )
    """

    create index(:tasks, [:organization_id])
    create index(:tasks, [:enabled], where: "enabled = true")
    create index(:tasks, [:enabled, :next_run_at], where: "enabled = true")
    create index(:tasks, [:schedule_type, :scheduled_at], where: "schedule_type = 'once'")
    create index(:tasks, [:organization_id, :queue], where: "queue IS NOT NULL")

    create table(:executions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:tasks, type: :binary_id, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "pending"
      add :scheduled_for, :utc_datetime, null: false
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime
      add :status_code, :integer
      add :duration_ms, :integer
      add :response_body, :text
      add :error_message, :text
      add :attempt, :integer, null: false, default: 1
      add :callback_url, :string

      timestamps(type: :utc_datetime)
    end

    create index(:executions, [:task_id])
    create index(:executions, [:task_id, :scheduled_for])
    create index(:executions, [:status, :scheduled_for])

    create index(:executions, [:status],
             where: "status = 'pending'",
             name: :executions_pending_status_idx
           )

    create table(:inbound_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :endpoint_id, references(:endpoints, type: :binary_id, on_delete: :delete_all),
        null: false

      add :method, :string, null: false
      add :headers, :map, default: %{}
      add :body, :text
      add :source_ip, :string
      add :execution_id, references(:executions, type: :binary_id, on_delete: :nilify_all)
      add :received_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:inbound_events, [:endpoint_id, :received_at])
  end
end
