process.env.READY_DELAY_MS = '0';

import request from 'supertest';
import { app } from './index';

describe('GET /health', () => {
  it('returns 200 with an ok status payload', async () => {
    const res = await request(app).get('/health');

    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ok');
    expect(typeof res.body.uptime).toBe('number');
    expect(typeof res.body.timestamp).toBe('string');
  });
});

describe('GET /ready', () => {
  it('returns 200 with a ready status once past the startup delay', async () => {
    const res = await request(app).get('/ready');

    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ready');
    expect(typeof res.body.timestamp).toBe('string');
  });
});

describe('GET /metrics', () => {
  it('exposes Prometheus metrics including default and synthetic ones', async () => {
    const res = await request(app).get('/metrics');

    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toContain('text/plain');
    expect(res.text).toContain('process_cpu_user_seconds_total');
    expect(res.text).toContain('http_requests_total');
    expect(res.text).toContain('app_synthetic_queue_depth');
  });
});

describe('GET /', () => {
  it('returns 200 with a greeting', async () => {
    const res = await request(app).get('/');

    expect(res.status).toBe(200);
    expect(res.text).toContain('Hello from the DevOps home assignment app!');
  });
});
