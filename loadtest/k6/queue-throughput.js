import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";

// Configuration — set these via environment variables:
//   K6_ENV_BASE_URL=https://staging.runlater.eu
//   K6_ENV_API_KEY=sk_live_xxx
//   K6_ENV_MOCK_URL=http://mock-server:8080
const BASE_URL = __ENV.BASE_URL || "https://staging.runlater.eu";
const API_KEY = __ENV.API_KEY || "CHANGE_ME";
const MOCK_URL = __ENV.MOCK_URL || "http://localhost:8080";

const failRate = new Rate("failed_requests");
const taskCreateDuration = new Trend("task_create_duration");

export const options = {
  scenarios: {
    // Ramp up queue throughput
    queue_burst: {
      executor: "ramping-rate",
      startRate: 10,
      timeUnit: "1s",
      preAllocatedVUs: 50,
      maxVUs: 500,
      stages: [
        { duration: "30s", target: 50 },   // warm up to 50 req/s
        { duration: "1m", target: 100 },    // push to 100 req/s
        { duration: "1m", target: 200 },    // push to 200 req/s
        { duration: "1m", target: 500 },    // push to 500 req/s
        { duration: "30s", target: 10 },    // cool down
      ],
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<500"],  // 95% of requests under 500ms
    failed_requests: ["rate<0.01"],     // less than 1% failures
  },
};

export default function () {
  // Create a queued task via API (immediate execution)
  const payload = JSON.stringify({
    task: {
      name: `loadtest-${Date.now()}`,
      url: `${MOCK_URL}/?jitter=200`,
      method: "POST",
      body: JSON.stringify({ test: true, timestamp: Date.now() }),
      schedule_type: "once",
      scheduled_at: new Date().toISOString(),
    },
  });

  const params = {
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${API_KEY}`,
    },
  };

  const res = http.post(`${BASE_URL}/api/v1/tasks`, payload, params);

  taskCreateDuration.add(res.timings.duration);

  const success = check(res, {
    "status is 201": (r) => r.status === 201,
    "has task id": (r) => {
      try {
        return JSON.parse(r.body).data.id !== undefined;
      } catch {
        return false;
      }
    },
  });

  failRate.add(!success);

  if (!success) {
    console.log(`Failed: ${res.status} ${res.body}`);
  }
}
