import type { Express } from 'express';
import { parseManualTransaction, parseManualTransactionPatch } from '../../domain/ledger.js';
import { actor, key, payloadHash, route, rpc, version } from '../../http/request.js';
import {decodeCursor,encodeCursor,listQuery,pageScope} from '../../http/pagination.js';

export function registerTransactionRoutes(app: Express): void {
  app.get('/api/v1/transactions', route(async (req, res) => {
    const query=listQuery('listTransactions',req.query),scope=pageScope(actor(req),'transactions',{view:query.view,...query.filters}),position=decodeCursor(scope,query.cursor);
    const result = await rpc<{data:unknown[];next:{time:string;id:string}|null}>(req, 'sl_transactions_page', {
      p_actor_subject: actor(req), p_view: query.view,p_limit:query.limit,p_filters:query.filters,p_after_time:position?.time??null,p_after_id:position?.id??null,
    });
    res.json({ data:result.data, page: { next_cursor: encodeCursor(scope,result.next) } });
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
