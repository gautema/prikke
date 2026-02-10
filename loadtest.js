import http from "k6/http";
import { check, sleep } from "k6";
import { Counter, Trend } from "k6/metrics";

// Custom metrics
const tasksCreated = new Counter("tasks_created");
const tasksFailed = new Counter("tasks_failed");
const apiDuration = new Trend("api_duration_ms");

// --- Configuration ---
// Override via: k6 run -e RATE=200 -e DURATION=2m loadtest.js
const RATE = parseInt(__ENV.RATE || "25"); // requests per second
const DURATION = __ENV.DURATION || "2m";
const BASE_URL = __ENV.BASE_URL || "https://runlater.eu";
const API_KEY = __ENV.API_KEY;

if (!API_KEY) {
  throw new Error(
    "API_KEY is required. Run with: k6 run -e API_KEY=pk_live_xxx.sk_live_yyy loadtest.js",
  );
}

export const options = {
  scenarios: {
    // Constant rate: guaranteed N requests/second regardless of response time
    sustained_load: {
      executor: "constant-arrival-rate",
      rate: RATE,
      timeUnit: "1s",
      duration: DURATION,
      preAllocatedVUs: RATE, // one VU per expected in-flight request
      maxVUs: RATE * 3, // headroom if responses are slow
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<2000"], // 95% under 2s
    http_req_failed: ["rate<0.05"], // less than 5% errors
  },
};

const headers = {
  Authorization: `Bearer ${API_KEY}`,
  "Content-Type": "application/json",
};

// Scenario 1: Create immediate tasks (queue-style)
function createImmediateTask() {
  const payload = JSON.stringify({
    name: `loadtest-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    url: "https://httpbin.org/get",
    retry_attempts: 1,
    method: "GET",
    timeout_ms: 10000,
  });

  const res = http.post(`${BASE_URL}/api/v1/tasks`, payload, { headers });
  apiDuration.add(res.timings.duration);

  const ok = check(res, {
    "status is 202": (r) => r.status === 202,
    "has execution_id": (r) => {
      try {
        return JSON.parse(r.body).data.execution_id !== undefined;
      } catch {
        return false;
      }
    },
  });

  if (ok) {
    tasksCreated.add(1);
  } else {
    tasksFailed.add(1);
    if (res.status !== 202) {
      console.warn(`Unexpected status ${res.status}: ${res.body}`);
    }
  }
}

// Scenario 2: Create delayed tasks (5s delay)
function createDelayedTask() {
  const payload = JSON.stringify({
    name: `loadtest-delayed-${Date.now()}`,
    url: "https://httpbin.org/get",
    method: "GET",
    delay: "5s",
  });

  const res = http.post(`${BASE_URL}/api/v1/tasks`, payload, { headers });
  apiDuration.add(res.timings.duration);

  check(res, {
    "delayed: status is 202": (r) => r.status === 202,
  });
}

// Scenario 3: List tasks (read pressure)
function listTasks() {
  const res = http.get(`${BASE_URL}/api/v1/tasks`, { headers });
  apiDuration.add(res.timings.duration);

  check(res, {
    "list: status is 200": (r) => r.status === 200,
  });
}

// Main: mix of operations (70% immediate, 15% delayed, 15% list)
export default function () {
  const roll = Math.random();

  if (roll < 0.7) {
    createImmediateTask();
  } else if (roll < 0.85) {
    createDelayedTask();
  } else {
    listTasks();
  }
  // No sleep — constant-arrival-rate executor controls the pace
}
