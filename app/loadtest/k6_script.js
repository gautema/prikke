import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";

// ─── Configuration ──────────────────────────────────────────────
const BASE_URL = __ENV.BASE_URL || "http://51.15.43.1";
const API_KEY = __ENV.API_KEY || "REPLACE_ME";
// Target URL that tasks will call — use the health endpoint itself
const TARGET_URL = __ENV.TARGET_URL || `${BASE_URL}/health`;

const headers = {
  "Content-Type": "application/json",
  Authorization: `Bearer ${API_KEY}`,
};

// ─── Custom metrics ─────────────────────────────────────────────
const taskCreateErrors = new Rate("task_create_errors");
const taskListErrors = new Rate("task_list_errors");
const triggerErrors = new Rate("trigger_errors");
const healthDuration = new Trend("health_duration", true);

// ─── Scenarios ──────────────────────────────────────────────────
export const options = {
  scenarios: {
    // Scenario 1: Health check baseline
    health_check: {
      executor: "constant-arrival-rate",
      rate: 100,
      timeUnit: "1s",
      duration: "2m",
      preAllocatedVUs: 50,
      maxVUs: 200,
      exec: "healthCheck",
    },

    // Scenario 2: Task creation ramp-up
    create_tasks: {
      executor: "ramping-vus",
      startVUs: 10,
      stages: [
        { duration: "30s", target: 50 },
        { duration: "1m", target: 200 },
        { duration: "1m", target: 500 },
        { duration: "1m", target: 1000 },
        { duration: "30s", target: 0 },
      ],
      exec: "createAndTriggerTask",
      startTime: "30s",
    },

    // Scenario 3: List tasks (read-heavy)
    list_tasks: {
      executor: "ramping-vus",
      startVUs: 5,
      stages: [
        { duration: "30s", target: 20 },
        { duration: "1m", target: 100 },
        { duration: "1m", target: 200 },
        { duration: "1m", target: 200 },
        { duration: "30s", target: 0 },
      ],
      exec: "listTasks",
      startTime: "30s",
    },
  },

  thresholds: {
    http_req_duration: ["p(95)<2000", "p(99)<5000"],
    http_req_failed: ["rate<0.05"],
    task_create_errors: ["rate<0.05"],
  },
};

// ─── Scenarios ──────────────────────────────────────────────────

// Scenario 1: Health check (baseline throughput)
export function healthCheck() {
  const res = http.get(`${BASE_URL}/health`);
  healthDuration.add(res.timings.duration);
  check(res, {
    "health 200": (r) => r.status === 200,
  });
}

// Scenario 2: Create a task then trigger it
export function createAndTriggerTask() {
  // Create an immediate (queued) task
  const payload = JSON.stringify({
    task: {
      name: `loadtest-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
      url: TARGET_URL,
      method: "GET",
      schedule_type: "once",
      scheduled_at: new Date().toISOString(),
    },
  });

  const createRes = http.post(`${BASE_URL}/api/v1/tasks`, payload, {
    headers,
  });

  const created = check(createRes, {
    "task created 202": (r) => r.status === 202,
  });
  taskCreateErrors.add(!created);

  if (created && createRes.json("data.task_id")) {
    const taskId = createRes.json("data.task_id");

    // Trigger execution
    const triggerRes = http.post(
      `${BASE_URL}/api/v1/tasks/${taskId}/trigger`,
      null,
      { headers }
    );
    const triggered = check(triggerRes, {
      "trigger 202": (r) => r.status === 202,
    });
    triggerErrors.add(!triggered);
  }

  sleep(0.1);
}

// Scenario 3: List tasks (read-heavy load)
export function listTasks() {
  const res = http.get(`${BASE_URL}/api/v1/tasks?page=1&page_size=20`, {
    headers,
  });
  const ok = check(res, {
    "list 200": (r) => r.status === 200,
  });
  taskListErrors.add(!ok);
  sleep(0.2);
}

// Default: runs all flows, works with --duration and --vus
export default function () {
  healthCheck();
  createAndTriggerTask();
  listTasks();
}
