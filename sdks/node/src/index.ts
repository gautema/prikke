import {
  RunlaterOptions,
  SendOptions,
  DelayOptions,
  ScheduleOptions,
  CronOptions,
  TaskResponse,
  CronResponse,
  Task,
  Execution,
  ListOptions,
  ListResponse,
  TriggerResponse,
  Monitor,
  CreateMonitorOptions,
  SyncOptions,
  SyncResponse,
  RunlaterError,
} from "./types"

export { RunlaterError }
export type {
  RunlaterOptions,
  SendOptions,
  DelayOptions,
  ScheduleOptions,
  CronOptions,
  TaskResponse,
  CronResponse,
  Task,
  Execution,
  ListOptions,
  ListResponse,
  TriggerResponse,
  Monitor,
  CreateMonitorOptions,
  SyncOptions,
  SyncResponse,
}

const DEFAULT_BASE_URL = "https://runlater.eu"

export class Runlater {
  private apiKey: string
  private baseUrl: string

  tasks: Tasks
  monitors: Monitors

  constructor(options: RunlaterOptions | string) {
    if (typeof options === "string") {
      this.apiKey = options
      this.baseUrl = DEFAULT_BASE_URL
    } else {
      this.apiKey = options.apiKey
      this.baseUrl = options.baseUrl ?? DEFAULT_BASE_URL
    }

    this.tasks = new Tasks(this)
    this.monitors = new Monitors(this)
  }

  /**
   * Send a request immediately with reliable delivery and retries.
   *
   * ```js
   * await rl.send("https://myapp.com/api/process", {
   *   body: { orderId: 123 },
   *   retries: 5
   * })
   * ```
   */
  async send(url: string, options: SendOptions = {}): Promise<TaskResponse> {
    const res = await this.request<{ data: TaskResponse }>("POST", "/tasks", {
      body: this.buildTaskBody(url, options),
      idempotencyKey: options.idempotencyKey,
    })
    return res.data
  }

  /**
   * Execute a request after a delay.
   *
   * ```js
   * await rl.delay("https://myapp.com/api/remind", {
   *   delay: "10m",
   *   body: { userId: 456 }
   * })
   * ```
   *
   * Delay accepts:
   * - Strings: "30s", "5m", "2h", "1d"
   * - Numbers: seconds (e.g. 3600 for 1 hour)
   */
  async delay(url: string, options: DelayOptions): Promise<TaskResponse> {
    const res = await this.request<{ data: TaskResponse }>("POST", "/tasks", {
      body: {
        ...this.buildTaskBody(url, options),
        delay: formatDelay(options.delay),
      },
      idempotencyKey: options.idempotencyKey,
    })
    return res.data
  }

  /**
   * Execute a request at a specific time.
   *
   * ```js
   * await rl.schedule("https://myapp.com/api/expire", {
   *   at: "2026-03-15T09:00:00Z",
   *   body: { trialId: 789 }
   * })
   * ```
   */
  async schedule(url: string, options: ScheduleOptions): Promise<TaskResponse> {
    const at = options.at instanceof Date ? options.at.toISOString() : options.at

    const res = await this.request<{ data: TaskResponse }>("POST", "/tasks", {
      body: {
        ...this.buildTaskBody(url, options),
        run_at: at,
      },
      idempotencyKey: options.idempotencyKey,
    })
    return res.data
  }

  /**
   * Create or update a recurring cron task.
   *
   * ```js
   * await rl.cron("daily-report", {
   *   url: "https://myapp.com/api/report",
   *   schedule: "0 9 * * *"
   * })
   * ```
   */
  async cron(name: string, options: CronOptions): Promise<CronResponse> {
    const res = await this.request<{ data: CronResponse }>("POST", "/tasks", {
      body: {
        name,
        url: options.url,
        method: options.method ?? "GET",
        cron: options.schedule,
        headers: options.headers,
        body: options.body != null ? JSON.stringify(options.body) : undefined,
        timeout_ms: options.timeout,
        retry_attempts: options.retries,
        queue: options.queue,
        callback_url: options.callback,
        enabled: options.enabled,
      },
    })
    return res.data
  }

  /**
   * Declaratively sync tasks and monitors. Matched by name.
   *
   * ```js
   * await rl.sync({
   *   tasks: [
   *     { name: "daily-report", url: "https://...", schedule: "0 9 * * *" }
   *   ],
   *   deleteRemoved: true
   * })
   * ```
   */
  async sync(options: SyncOptions): Promise<SyncResponse> {
    const body: Record<string, unknown> = {}

    if (options.tasks) {
      body.tasks = options.tasks.map((t) => ({
        name: t.url, // name defaults to url if not in CronOptions
        url: t.url,
        method: t.method ?? "GET",
        schedule_type: "cron",
        cron_expression: t.schedule,
        headers: t.headers,
        body: t.body != null ? JSON.stringify(t.body) : undefined,
        timeout_ms: t.timeout,
        retry_attempts: t.retries,
        queue: t.queue,
        callback_url: t.callback,
        enabled: t.enabled,
      }))
    }

    if (options.monitors) {
      body.monitors = options.monitors.map((m) => ({
        name: m.name,
        schedule_type: m.interval ? "interval" : "cron",
        cron_expression: m.schedule,
        interval_seconds: m.interval,
        grace_period_seconds: m.grace,
        enabled: m.enabled,
      }))
    }

    if (options.deleteRemoved) {
      body.delete_removed = true
    }

    const res = await this.request<{ data: SyncResponse }>("PUT", "/sync", { body })
    return res.data
  }

  // --- Internal ---

  private buildTaskBody(url: string, options: SendOptions) {
    return {
      url,
      method: options.method ?? "POST",
      headers: options.headers,
      body: options.body != null ? JSON.stringify(options.body) : undefined,
      timeout_ms: options.timeout,
      retry_attempts: options.retries,
      queue: options.queue,
      callback_url: options.callback,
    }
  }

  /** @internal */
  async request<T>(
    method: string,
    path: string,
    options: { body?: unknown; idempotencyKey?: string } = {}
  ): Promise<T> {
    const headers: Record<string, string> = {
      Authorization: `Bearer ${this.apiKey}`,
      "Content-Type": "application/json",
      "User-Agent": "runlater-node/0.1.0",
    }

    if (options.idempotencyKey) {
      headers["Idempotency-Key"] = options.idempotencyKey
    }

    const response = await fetch(`${this.baseUrl}/api/v1${path}`, {
      method,
      headers,
      body: options.body != null ? JSON.stringify(options.body) : undefined,
    })

    if (!response.ok) {
      const errorBody = await response.json().catch(() => ({}))
      const error = (errorBody as { error?: { code?: string; message?: string } }).error
      throw new RunlaterError(
        response.status,
        error?.code ?? "unknown_error",
        error?.message ?? `HTTP ${response.status}`
      )
    }

    if (response.status === 204) {
      return {} as T
    }

    return (await response.json()) as T
  }
}

class Tasks {
  constructor(private client: Runlater) {}

  async list(options: ListOptions = {}): Promise<ListResponse<Task>> {
    const params = new URLSearchParams()
    if (options.queue != null) params.set("queue", options.queue)
    if (options.limit != null) params.set("limit", String(options.limit))
    if (options.offset != null) params.set("offset", String(options.offset))

    const query = params.toString()
    return this.client.request("GET", `/tasks${query ? `?${query}` : ""}`)
  }

  async get(id: string): Promise<Task> {
    const res = await this.client.request<{ data: Task }>("GET", `/tasks/${id}`)
    return res.data
  }

  async delete(id: string): Promise<void> {
    await this.client.request("DELETE", `/tasks/${id}`)
  }

  async trigger(id: string): Promise<TriggerResponse> {
    const res = await this.client.request<{ data: TriggerResponse }>(
      "POST",
      `/tasks/${id}/trigger`
    )
    return res.data
  }

  async executions(id: string, limit = 50): Promise<Execution[]> {
    const res = await this.client.request<{ data: Execution[] }>(
      "GET",
      `/tasks/${id}/executions?limit=${limit}`
    )
    return res.data
  }
}

class Monitors {
  constructor(private client: Runlater) {}

  async list(): Promise<Monitor[]> {
    const res = await this.client.request<{ data: Monitor[] }>("GET", "/monitors")
    return res.data
  }

  async get(id: string): Promise<Monitor> {
    const res = await this.client.request<{ data: Monitor }>("GET", `/monitors/${id}`)
    return res.data
  }

  async create(options: CreateMonitorOptions): Promise<Monitor> {
    const res = await this.client.request<{ data: Monitor }>("POST", "/monitors", {
      body: {
        name: options.name,
        schedule_type: options.interval ? "interval" : "cron",
        cron_expression: options.schedule,
        interval_seconds: options.interval,
        grace_period_seconds: options.grace,
        enabled: options.enabled,
      },
    })
    return res.data
  }

  async delete(id: string): Promise<void> {
    await this.client.request("DELETE", `/monitors/${id}`)
  }
}

function formatDelay(delay: string | number): string {
  if (typeof delay === "number") return `${delay}s`
  return delay
}
