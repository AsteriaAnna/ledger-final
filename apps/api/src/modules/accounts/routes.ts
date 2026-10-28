import type { Express } from 'express';
import { parseAccount, parseAccountPatch, parseFundAdjustment, parseOpeningState } from '../../domain/ledger.js';
import { actor, key, payloadHash, route, rpc, version } from '../../http/request.js';
import {decodeCursor,encodeCursor,listQuery,pageScope} from '../../http/pagination.js';

export function registerAccountRoutes(app: Express): void {
  app.get('/api/v1/accounts', route(async (req, res) => {
    const query=listQuery('listAccounts',req.query),scope=pageScope(actor(req),'accounts',{view:query.view}),position=decodeCursor(scope,query.cursor);
    const result = await rpc<{data:unknown[];next:{time:string;id:string}|null}>(req, 'sl_accounts_page', {
      p_actor_subject: actor(req), p_view: query.view,p_limit:query.limit,p_after_time:position?.time??null,p_after_id:position?.id??null,
    });
    res.json({ data:result.data, page: { next_cursor: encodeCursor(scope,result.next) } });
  }));

  app.get('/api/v1/accounts/:accountId', route(async (req, res) => {
    const data = await rpc<Record<string, unknown>>(req, 'sl_get_account_visible', {
      p_actor_subject: actor(req), p_account_id: req.params.accountId,
    });
    res.setHeader('ETag', `"${data.version}"`);
    res.json({ data });
  }));

  app.post('/api/v1/accounts', route(async (req, res) => {
    const input = parseAccount(req.body);
    const data = await rpc<Record<string, unknown>>(req, 'sl_create_account', {
      p_actor_subject: actor(req), p_key_digest: key(req), p_payload_hash: payloadHash(input), p_input: input,
    });
    res.setHeader('ETag', `"${data.version}"`);
    res.status(201).json({ data });
  }));

  app.patch('/api/v1/accounts/:accountId', route(async (req, res) => {
    const expectedVersion = version(req);
    const patch = parseAccountPatch(req.body);
    const data = await rpc<Record<string, unknown>>(req, 'sl_patch_account', {
      p_actor_subject: actor(req), p_account_id: req.params.accountId,
      p_expected_version: expectedVersion, p_patch: patch,
    });
    res.setHeader('ETag', `"${data.version}"`);
    res.json({ data });
  }));

  app.post('/api/v1/accounts/:accountId/fund-adjustments', route(async (req, res) => {
    const keyDigest = key(req);
    const expectedVersion = version(req);
    const input = parseFundAdjustment(req.body);
    const data = await rpc<Record<string, unknown>>(req, 'sl_adjust_funds', {
      p_actor_subject: actor(req), p_account_id: req.params.accountId,
      p_key_digest: keyDigest, p_payload_hash: payloadHash({ expectedVersion, input }),
      p_expected_version: expectedVersion, p_input: input,
    });
    res.setHeader('ETag', `"${data.version}"`);
    res.json({ data });
  }));

  app.put('/api/v1/accounts/:accountId/opening-state', route(async (req, res) => {
    const expectedVersion = version(req);
    const input = parseOpeningState(req.body);
    const data = await rpc<Record<string, unknown>>(req, 'sl_put_opening_state', {
      p_actor_subject: actor(req), p_account_id: req.params.accountId,
      p_expected_version: expectedVersion, p_input: input,
    });
    res.setHeader('ETag', `"${data.version}"`);
    res.json({ data });
  }));
}
