import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";

// Sustained load test — simulates steady production traffic
// Tests: task creation, task listing, trigger existing tasks
const BASE_URL = __ENV.BASE_URL || "https://staging.runlater.eu";
const API_KEY = __ENV.API_KEY || "CHANGE_ME";
const MOCK_URL = __ENV.MOCK_URL || "http://localhost:8080";

const failRate = new Rate("failed_requests");

export const options = {
  scenarios: {
    // Steady queue traffic (bulk of requests)
    queue_tasks: {
      executor: "constant-rate",
      rate: 50,
      timeUnit: "1s",
      duration: "10m",
      preAllocatedVUs: 100,
      maxVUs: 200,
      exec: "queueTask",
    },
    // Periodic dashboard reads (simulates users checking UI)
    read_tasks: {
      executor: "constant-rate",
      rate: 5,
      timeUnit: "1s",
      duration: "10m",
      preAllocatedVUs: 10,
      maxVUs: 20,
      exec: "listTasks",
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<1000"],
    failed_requests: ["rate<0.05"],
  },
};

const headers = {
  "Content-Type": "application/json",
  Authorization: `Bearer ${API_KEY}`,
};

export function queueTask() {
  const payload = JSON.stringify({
    task: {
      name: `sustained-${Date.now()}`,
      url: `${MOCK_URL}/?jitter=500`,
      method: "POST",
      body: JSON.stringify({ test: true }),
      schedule_type: "once",
      scheduled_at: new Date().toISOString(),
    },
  });

  const res = http.post(`${BASE_URL}/api/v1/tasks`, payload, { headers });

  const success = check(res, {
    "queue: status 201": (r) => r.status === 201,
  });

  failRate.add(!success);
}

export function listTasks() {
  const res = http.get(`${BASE_URL}/api/v1/tasks`, { headers });

  const success = check(res, {
    "list: status 200": (r) => r.status === 200,
  });

  failRate.add(!success);
}
