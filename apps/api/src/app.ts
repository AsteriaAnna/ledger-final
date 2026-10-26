import express, { type Request, type Response, type NextFunction } from 'express';
import { createHash } from 'node:crypto';
import { callRpc, verifyAccessToken } from './cloudbase.js';
import { canonicalJson, DomainError, parseAccount, parseExpense } from './domain.js';

export const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '32kb' }));
app.use((req, res, next) => {
  const origin = process.env.WEB_ORIGIN;
  if (origin && req.get('Origin') === origin) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Vary', 'Origin');
    res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type, Idempotency-Key');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  }
  if (req.method === 'OPTIONS') { res.sendStatus(204); return; }
  next();
});
app.get('/healthz', (_req, res) => res.json({ status: 'ok' }));

type AuthRequest = Request & { actorSubject?: string };
app.use('/api/v1', async (req: AuthRequest, _res, next) => {
  try {
    const header = req.get('Authorization') ?? '';
    if (!header.startsWith('Bearer ')) throw new DomainError(401, 'UNAUTHORIZED', '请先登录。');
    req.actorSubject = await verifyAccessToken(header.slice(7));
    next();
  } catch (error) { next(error); }
});

function key(req: Request): string {
  const value = req.get('Idempotency-Key');
  if (!value || value.length > 128) throw new DomainError(400, 'IDEMPOTENCY_KEY_REQUIRED', '缺少有效的请求标识。');
  return createHash('sha256').update(value).digest('hex');
}

function payloadHash(value: unknown): string {
  return createHash('sha256').update(canonicalJson(value)).digest('hex');
}

const route = (fn: (req: AuthRequest, res: Response) => Promise<void>) =>
  (req: AuthRequest, res: Response, next: NextFunction) => { fn(req, res).catch(next); };

app.get('/api/v1/accounts', route(async (req, res) => {
  if (Object.keys(req.query).length) throw new DomainError(422, 'VALIDATION_ERROR', '此版本暂不支持账户筛选。');
  const data = await callRpc<unknown[]>('sl_list_accounts', { p_actor_subject: req.actorSubject });
  res.json({ data, page: { next_cursor: null } });
}));

app.get('/api/v1/accounts/:accountId', route(async (req, res) => {
  const data = await callRpc<Record<string, unknown>>('sl_get_account', {
    p_actor_subject: req.actorSubject, p_account_id: req.params.accountId,
  });
  res.setHeader('ETag', `"${data.version}"`);
  res.json({ data });
}));

app.post('/api/v1/accounts', route(async (req, res) => {
  const input = parseAccount(req.body);
  const data = await callRpc<Record<string, unknown>>('sl_create_account', {
    p_actor_subject: req.actorSubject, p_key_digest: key(req), p_payload_hash: payloadHash(input), p_input: input,
  });
  res.setHeader('ETag', `"${data.version}"`);
  res.status(201).json({ data });
}));

app.get('/api/v1/transactions', route(async (req, res) => {
  if (Object.keys(req.query).length) throw new DomainError(422, 'VALIDATION_ERROR', '此版本暂不支持账单筛选。');
  const data = await callRpc<unknown[]>('sl_list_transactions', { p_actor_subject: req.actorSubject });
  res.json({ data, page: { next_cursor: null } });
}));

app.get('/api/v1/transactions/:transactionId', route(async (req, res) => {
  const data = await callRpc<Record<string, unknown>>('sl_get_transaction', {
    p_actor_subject: req.actorSubject, p_transaction_id: req.params.transactionId,
  });
  res.setHeader('ETag', `"${data.version}"`);
  res.json({ data });
}));

app.post('/api/v1/transactions', route(async (req, res) => {
  const input = parseExpense(req.body);
  const data = await callRpc<Record<string, unknown>>('sl_create_expense', {
    p_actor_subject: req.actorSubject, p_key_digest: key(req), p_payload_hash: payloadHash(input), p_input: input,
  });
  res.setHeader('ETag', `"${(data.transaction as Record<string, unknown>).version}"`);
  res.status(201).json({ data });
}));

app.get('/api/v1/transaction-categories', route(async (_req, res) => {
  const data = [
    ['food', '餐饮'], ['shopping', '购物'], ['transport', '交通'], ['education', '教育'],
    ['health', '医疗'], ['entertainment', '娱乐'], ['utilities', '生活缴费'], ['other', '其他'],
  ].map(([code, name]) => ({ code, name }));
  res.json({ data });
}));

app.use((error: unknown, _req: Request, res: Response, _next: NextFunction) => {
  if (error instanceof DomainError) { res.status(error.status).json({ code: error.code, message: error.message }); return; }
  if (error instanceof SyntaxError && 'body' in error) { res.status(400).json({ code: 'BAD_REQUEST', message: '请求正文不是有效 JSON。' }); return; }
  console.error('Unhandled API error', error instanceof Error ? error.message : String(error));
  res.status(500).json({ code: 'INTERNAL_ERROR', message: '暂时无法完成操作。' });
});
