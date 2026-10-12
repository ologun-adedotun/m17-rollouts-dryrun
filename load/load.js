import http from 'k6/http';
import { Counter } from 'k6/metrics';

const ok = new Counter('status_2xx');
const s429 = new Counter('status_429');
const s500 = new Counter('status_500');
const s503 = new Counter('status_503');
const s504 = new Counter('status_504');
const other = new Counter('status_other');

export const options = {
  scenarios: {
    load: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 20),
      timeUnit: '1s',
      duration: __ENV.DURATION || '30s',
      preAllocatedVUs: 50,
      maxVUs: 300,
    },
  },
};

export default function () {
  const res = http.get(__ENV.TARGET, { headers: { Host: __ENV.HOST || 'mission.local' }, timeout: '10s' });
  if (res.status >= 200 && res.status < 300) ok.add(1);
  else if (res.status === 429) s429.add(1);
  else if (res.status === 500) s500.add(1);
  else if (res.status === 503) s503.add(1);
  else if (res.status === 504) s504.add(1);
  else other.add(1);
}

export function handleSummary(data) {
  const n = (m) => (data.metrics[m] ? data.metrics[m].values.count : 0);
  const d = data.metrics.http_req_duration.values;
  return {
    stdout: `RESULT 2xx=${n('status_2xx')} 429=${n('status_429')} 500=${n('status_500')} 503=${n('status_503')} 504=${n('status_504')} other=${n('status_other')} p50_ms=${d.med.toFixed(0)} p95_ms=${d['p(95)'].toFixed(0)}\n`,
  };
}
