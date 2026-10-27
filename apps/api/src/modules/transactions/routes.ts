import type { Express } from 'express';
import { parseManualTransaction, parseManualTransactionPatch } from '../../domain/ledger.js';
import { actor, key, payloadHash, route, rpc, version, view } from '../../http/request.js';

export function registerTransactionRoutes(app: Express): void {
  app.get('/api/v1/transactions', route(async (req, res) => {
    const data = await rpc<unknown[]>(req, 'sl_list_transactions_visible', {
      p_actor_subject: actor(req), p_view: view(req),
    });
    res.json({ data, page: { next_cursor: null } });
  }));

  app.get('/api/v1/transactions/:transactionId', route(async (req, res) => {
    const data = await rpc<Record<string, unknown>>(req, 'sl_get_transaction_visible', {
      p_actor_subject: actor(req), p_transaction_id: req.params.transactionId,
    });
    res.setHeader('ETag', `"${data.version}"`);
    res.json({ data });
  }));

  app.post('/api/v1/transactions', route(async (req, res) => {
    const input = parseManualTransaction(req.body);
    const data = await rpc<Record<string, unknown>>(req, 'sl_create_transaction', {
      p_actor_subject: actor(req), p_key_digest: key(req), p_payload_hash: payloadHash(input), p_input: input,
    });
    res.setHeader('ETag', `"${(data.transaction as Record<string, unknown>).version}"`);
    res.status(201).json({ data });
  }));

  app.patch('/api/v1/transactions/:transactionId', route(async (req, res) => {
    const expectedVersion = version(req);
    const patch = parseManualTransactionPatch(req.body);
    const data = await rpc<Record<string, unknown>>(req, 'sl_patch_transaction', {
      p_actor_subject: actor(req), p_transaction_id: req.params.transactionId,
      p_expected_version: expectedVersion, p_patch: patch,
    });
    res.setHeader('ETag', `"${(data.transaction as Record<string, unknown>).version}"`);
    res.json({ data });
  }));

  app.delete('/api/v1/transactions/:transactionId', route(async (req, res) => {
    const expectedVersion = version(req);
    const data = await rpc<Record<string, unknown>>(req, 'sl_delete_transaction', {
      p_actor_subject: actor(req), p_transaction_id: req.params.transactionId,
      p_expected_version: expectedVersion,
    });
    res.json({ data });
  }));

  app.get('/api/v1/transaction-categories', route(async (_req, res) => {
    const data = [
      ['food', '餐饮'], ['shopping', '购物'], ['transport', '交通'], ['education', '教育'],
      ['health', '医疗'], ['entertainment', '娱乐'], ['utilities', '生活缴费'], ['other', '其他'],
    ].map(([code, name]) => ({ code, name }));
    res.json({ data });
  }));
}
