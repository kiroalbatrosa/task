import express, { Request, Response } from 'express';
import type { Server } from 'node:http';
import { register, metricsMiddleware, startSyntheticMetrics } from './metrics';

export const app = express();

app.disable('x-powered-by');
app.use(metricsMiddleware);

const READY_DELAY_MS = Number(process.env.READY_DELAY_MS || 5000);
const startedAt = Date.now();

app.get('/health', (_req: Request, res: Response) => {
  res.status(200).json({
    status: 'ok',
    uptime: process.uptime(),
    timestamp: new Date().toISOString(),
  });
});

app.get('/ready', (_req: Request, res: Response) => {
  const isReady = Date.now() - startedAt >= READY_DELAY_MS;
  res.status(isReady ? 200 : 503).json({
    status: isReady ? 'ready' : 'starting',
    timestamp: new Date().toISOString(),
  });
});

app.get('/metrics', async (_req: Request, res: Response) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

app.get('/', (_req: Request, res: Response) => {
  res.status(200).send('Hello from the DevOps home assignment app! CI/CD deployment verified.');
});

if (require.main === module) {
  const port = Number(process.env.PORT || 3000);
  const syntheticMetricsTimer = startSyntheticMetrics();
  let server: Server;

  server = app.listen(port, () => {
    console.log(`App listening on port ${port}`);
  });

  const shutdown = (signal: NodeJS.Signals): void => {
    console.log(`${signal} received; shutting down`);
    clearInterval(syntheticMetricsTimer);
    server.close((error?: Error) => {
      if (error) {
        console.error('Failed to close the HTTP server cleanly', error);
        process.exitCode = 1;
      }
    });
  };

  process.once('SIGTERM', shutdown);
  process.once('SIGINT', shutdown);
}
