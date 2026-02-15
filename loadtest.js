import http from "k6/http";
import { check, sleep } from "k6";
import { Counter, Trend, Rate } from "k6/metrics";

// Custom metrics
const tasksCreated = new Counter("tasks_created");
const tasksFailed = new Counter("tasks_failed");
const apiDuration = new Trend("api_duration_ms");
const rateLimited = new Rate("rate_limited");

// --- Configuration ---
// Override via: k6 run -e RATE=200 -e DURATION=2m loadtest.js
const RATE = parseInt(__ENV.RATE || "25"); // requests per second
const DURATION = __ENV.DURATION || "2m";
const BASE_URL = __ENV.BASE_URL || "https://runlater.eu";
const API_KEY = __ENV.API_KEY;
const ENDPOINT_URL =
  __ENV.ENDPOINT_URL ||
  "https://runlater.eu/in/ep_NgIY3xmLF6Awbs46Ez4boYV-f2pS4lgl";
const TARGET_URL = __ENV.TARGET_URL || "https://httpbin.org/get";

// If no API_KEY, run endpoint-only mode
const MODE = API_KEY ? "api" : "endpoint";

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

const jsonHeaders = { "Content-Type": "application/json" };

// --- Endpoint mode: POST to inbound webhook endpoint ---
function hitEndpoint() {
  const payload = JSON.stringify({
    event: "loadtest",
    timestamp: new Date().toISOString(),
    iteration: __ITER,
    vu: __VU,
  });

  const res = http.post(ENDPOINT_URL, payload, { headers: jsonHeaders });
  apiDuration.add(res.timings.duration);

  const ok = check(res, {
    "status is 200": (r) => r.status === 200,
    "not rate limited": (r) => r.status !== 429,
  });

  rateLimited.add(res.status === 429);

  if (ok) {
    tasksCreated.add(1);
  } else if (res.status !== 429) {
    tasksFailed.add(1);
  }
}

// --- API mode: mix of operations ---
const apiHeaders = {
  Authorization: `Bearer ${API_KEY}`,
  "Content-Type": "application/json",
};

function createImmediateTask() {
  const payload = JSON.stringify({
    name: `loadtest-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    url: TARGET_URL,
    retry_attempts: 1,
    method: "GET",
    timeout_ms: 10000,
  });

  const res = http.post(`${BASE_URL}/api/v1/tasks`, payload, {
    headers: apiHeaders,
  });
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

function createDelayedTask() {
  const payload = JSON.stringify({
    name: `loadtest-delayed-${Date.now()}`,
    url: TARGET_URL,
    method: "GET",
    delay: "5s",
  });

  const res = http.post(`${BASE_URL}/api/v1/tasks`, payload, {
    headers: apiHeaders,
  });
  apiDuration.add(res.timings.duration);

  check(res, {
    "delayed: status is 202": (r) => r.status === 202,
  });
}

function listTasks() {
  const res = http.get(`${BASE_URL}/api/v1/tasks`, { headers: apiHeaders });
  apiDuration.add(res.timings.duration);

  check(res, {
    "list: status is 200": (r) => r.status === 200,
  });
}

// Main: route based on mode
export default function () {
  if (MODE === "endpoint") {
    hitEndpoint();
  } else {
    // API mode: mix of operations (70% immediate, 15% delayed, 15% list)
    const roll = Math.random();

    if (roll < 0.7) {
      createImmediateTask();
    } else if (roll < 0.85) {
      createDelayedTask();
    } else {
      listTasks();
    }
  }
  // No sleep — constant-arrival-rate executor controls the pace
}
