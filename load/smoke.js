// A short smoke test, used by Argo Rollouts as an analysis: k6 exits non-zero if a threshold fails.
import http from 'k6/http';

export const options = {
  scenarios: {
    smoke: { executor: 'constant-arrival-rate', rate: 10, timeUnit: '1s', duration: '20s', preAllocatedVUs: 10, maxVUs: 50 },
  },
  thresholds: {
    http_req_failed: ['rate<0.02'],
    http_req_duration: ['p(95)<250'],
  },
};

export default function () {
  http.get(`${__ENV.TARGET}/`, { timeout: '5s' });
}