import { createHash } from 'node:crypto';
import type { NextFunction, Request, Response } from 'express';
import { canonicalJson, DomainError } from '../domain/ledger.js';
import { callRpc } from '../infrastructure/cloudbase.js';

export type AuthRequest = Request & { actorSubject?: string; actorDisplayName?: string };

export const route = (fn: (req: AuthRequest, res: Response) => Promise<void>) =>
  (req: AuthRequest, res: Response, next: NextFunction) => { fn(req, res).catch(next); };

export function actor(req: AuthRequest): string {
  if (!req.actorSubject) throw new DomainError(401, 'UNAUTHENTICATED', '请先登录。');
  return req.actorSubject;
}

export function rpc<T>(req: AuthRequest, name: string, args: Record<string, unknown>): Promise<T> {
  return callRpc<T>(name, args, req.actorDisplayName);
}

export function key(req: Request): string {
  const value = req.get('Idempotency-Key');
  if (!value || value.length > 128) throw new DomainError(400, 'BAD_REQUEST', '缺少有效的请求标识。');
  return createHash('sha256').update(value).digest('hex');
}

export function version(req: Request): number {
  const value = req.get('If-Match');
  if (!value) throw new DomainError(428, 'PRECONDITION_REQUIRED', '请先刷新再修改。');
  if (!/^"[1-9][0-9]*"$/.test(value) || !Number.isSafeInteger(Number(value.slice(1, -1)))) {
    throw new DomainError(400, 'BAD_REQUEST', '版本标识不合法。');
  }
  return Number(value.slice(1, -1));
}

export function payloadHash(value: unknown): string {
  return createHash('sha256').update(canonicalJson(value)).digest('hex');
}

export function view(req: Request): 'mine' | 'partner' {
  const value = req.query.view ?? 'mine';
  if ((value !== 'mine' && value !== 'partner') || Object.keys(req.query).some((name) => name !== 'view')) {
    throw new DomainError(422, 'VALIDATION_ERROR', '此版本只支持本人或对象视图。');
  }
  return value;
}
