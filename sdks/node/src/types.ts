export interface RunlaterOptions {
  apiKey: string
  baseUrl?: string
}

export interface SendOptions {
  method?: "GET" | "POST" | "PUT" | "PATCH" | "DELETE"
  headers?: Record<string, string>
  body?: unknown
  retries?: number
  timeout?: number
  queue?: string
  callback?: string
  idempotencyKey?: string
}

export interface DelayOptions extends SendOptions {
  delay: string | number
}

export interface ScheduleOptions extends SendOptions {
  at: string | Date
}

export interface CronOptions {
  url: string
  schedule: string
  method?: "GET" | "POST" | "PUT" | "PATCH" | "DELETE"
  headers?: Record<string, string>
  body?: unknown
  timeout?: number
  retries?: number
  queue?: string
  callback?: string
  enabled?: boolean
}

export interface TaskResponse {
  task_id: string
  execution_id: string
  status: string
  scheduled_for: string
}

export interface CronResponse {
  id: string
  name: string
  url: string
  method: string
  cron_expression: string
  enabled: boolean
  next_run_at: string | null
  inserted_at: string
  updated_at: string
}

export interface Task {
  id: string
  name: string
  url: string
  method: string
  headers: Record<string, string>
  body: string | null
  schedule_type: string
  cron_expression: string | null
  scheduled_at: string | null
  enabled: boolean
  muted: boolean
  timeout_ms: number
  retry_attempts: number
  callback_url: string | null
  queue: string | null
  next_run_at: string | null
  inserted_at: string
  updated_at: string
}

export interface Execution {
  id: string
  status: "pending" | "running" | "success" | "failed" | "timeout"
  scheduled_for: string
  started_at: string | null
  finished_at: string | null
  status_code: number | null
  duration_ms: number | null
  error_message: string | null
  attempt: number
}

export interface ListOptions {
  queue?: string
  limit?: number
  offset?: number
}

export interface ListResponse<T> {
  data: T[]
  has_more: boolean
  limit: number
  offset: number
}

export interface TriggerResponse {
  execution_id: string
  status: string
  scheduled_for: string
}

export interface Monitor {
  id: string
  name: string
  ping_token: string
  ping_url: string
  schedule_type: "cron" | "interval"
  cron_expression: string | null
  interval_seconds: number | null
  grace_period_seconds: number
  status: "new" | "up" | "down" | "paused"
  enabled: boolean
  muted: boolean
  last_ping_at: string | null
  next_expected_at: string | null
  inserted_at: string
  updated_at: string
}

export interface CreateMonitorOptions {
  name: string
  schedule: string
  interval?: number
  grace?: number
  enabled?: boolean
}

export interface SyncOptions {
  tasks?: CronOptions[]
  monitors?: CreateMonitorOptions[]
  deleteRemoved?: boolean
}

export interface SyncResponse {
  tasks: { created: string[]; updated: string[]; deleted: string[] }
  monitors: { created: string[]; updated: string[]; deleted: string[] }
  created_count: number
  updated_count: number
  deleted_count: number
}

export class RunlaterError extends Error {
  status: number
  code: string

  constructor(status: number, code: string, message: string) {
    super(message)
    this.name = "RunlaterError"
    this.status = status
    this.code = code
  }
}
