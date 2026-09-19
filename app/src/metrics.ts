import client, { Registry } from 'prom-client';
import { Request, Response, NextFunction } from 'express';

export const register = new Registry();

client.collectDefaultMetrics({ register });

export const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.01, 0.05, 0.1, 0.3, 0.5, 1, 2, 5],
  registers: [register],
});

export const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total number of HTTP requests',
  labelNames: ['method', 'route', 'status_code'],
  registers: [register],
});

export function metricsMiddleware(req: Request, res: Response, next: NextFunction): void {
  const endTimer = httpRequestDuration.startTimer();

  res.on('finish', () => {
    // Avoid unbounded metric cardinality from arbitrary request paths.
    const route = req.route?.path || 'unmatched';
    const labels = { method: req.method, route, status_code: String(res.statusCode) };
    endTimer(labels);
    httpRequestsTotal.inc(labels);
  });

  next();
}

const syntheticQueueDepth = new client.Gauge({
  name: 'app_synthetic_queue_depth',
  help: 'Simulated depth of a background job queue',
  registers: [register],
});

const syntheticActiveUsers = new client.Gauge({
  name: 'app_synthetic_active_users',
  help: 'Simulated number of currently active users',
  registers: [register],
});

const syntheticCpuLoad = new client.Gauge({
  name: 'app_synthetic_cpu_load_ratio',
  help: 'Simulated CPU load ratio between 0 and 1',
  registers: [register],
});

const syntheticJobsProcessed = new client.Counter({
  name: 'app_synthetic_jobs_processed_total',
  help: 'Simulated count of background jobs processed',
  registers: [register],
});

const syntheticJobDuration = new client.Histogram({
  name: 'app_synthetic_job_duration_seconds',
  help: 'Simulated duration of background job processing in seconds',
  buckets: [0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
  registers: [register],
});

function randomBetween(min: number, max: number): number {
  return Math.random() * (max - min) + min;
}

export function startSyntheticMetrics(intervalMs = 5000): NodeJS.Timeout {
  return setInterval(() => {
    syntheticQueueDepth.set(Math.round(randomBetween(0, 50)));
    syntheticActiveUsers.set(Math.round(randomBetween(10, 500)));
    syntheticCpuLoad.set(randomBetween(0.05, 0.95));
    syntheticJobsProcessed.inc(Math.round(randomBetween(1, 10)));
    syntheticJobDuration.observe(randomBetween(0.05, 4));
  }, intervalMs);
}
