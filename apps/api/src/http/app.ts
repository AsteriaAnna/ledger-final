import express, { type NextFunction, type Request, type Response } from 'express';
import { DomainError } from '../domain/ledger.js';
import { verifyAccessToken } from '../infrastructure/cloudbase.js';
import { registerAccountRoutes } from '../modules/accounts/routes.js';
import { registerRelationshipRoutes } from '../modules/relationship/routes.js';
import { registerTransactionRoutes } from '../modules/transactions/routes.js';
import type { AuthRequest } from './request.js';
import { registerImportRoutes } from '../modules/imports/routes.js';
import { registerOverviewRoutes } from '../modules/overview/routes.js';
import { registerWeb } from './web.js';

export const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '32kb' }));
app.use((req, res, next) => {
  const origin = process.env.WEB_ORIGIN;
  if (origin && req.get('Origin') === origin) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Vary', 'Origin');
    res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type, Idempotency-Key, If-Match');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, PATCH, DELETE, OPTIONS');
    res.setHeader('Access-Control-Expose-Headers','ETag');
  }
  if (req.method === 'OPTIONS') { res.sendStatus(204); return; }
  next();
});
app.get('/healthz', (_req, res) => res.setHeader('Cache-Control','no-store').json({ status: 'ok' }));

app.use('/api/v1', async (req: AuthRequest, res, next) => {
  res.setHeader('Cache-Control','no-store');
  try {
    const header = req.get('Authorization') ?? '';
    if (!header.startsWith('Bearer ')) throw new DomainError(401, 'UNAUTHENTICATED', '请先登录。');
    const identity = await verifyAccessToken(header.slice(7));
    req.actorSubject = identity.subject;
    req.actorDisplayName = identity.displayName;
    next();
  } catch (error) { next(error); }
});

registerRelationshipRoutes(app);
registerAccountRoutes(app);
registerTransactionRoutes(app);
registerImportRoutes(app);
registerOverviewRoutes(app);
app.use('/api/v1',(_req,res)=>res.status(404).json({code:'RESOURCE_NOT_FOUND',message:'目标不存在。'}));
registerWeb(app,process.env.WEB_DIST_PATH);

app.use((error: unknown, _req: Request, res: Response, _next: NextFunction) => {
  if (error instanceof DomainError) { res.status(error.status).json({ code: error.code, message: error.message }); return; }
  if (error instanceof Error && error.name==='MulterError') { res.status(413).json({ code:'PAYLOAD_TOO_LARGE',message:'每次请选择一个不超过10MiB的文件。' });return; }
  if (error instanceof Error && 'type' in error && error.type==='entity.too.large') { res.status(413).json({code:'PAYLOAD_TOO_LARGE',message:'请求内容过大。'});return; }
  if (error instanceof SyntaxError && 'body' in error) { res.status(400).json({ code: 'BAD_REQUEST', message: '请求正文不是有效 JSON。' }); return; }
  console.error('Unhandled API error', error instanceof Error ? error.message : String(error));
  res.status(500).json({ code: 'INTERNAL_ERROR', message: '暂时无法完成操作。' });
});
