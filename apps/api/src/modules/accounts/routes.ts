import type { Express } from 'express';
import { parseAccount, parseAccountPatch, parseFundAdjustment, parseOpeningState } from '../../domain/ledger.js';
import { actor, key, payloadHash, route, rpc, version, view } from '../../http/request.js';

export function registerAccountRoutes(app: Express): void {
  app.get('/api/v1/accounts', route(async (req, res) => {
    const data = await rpc<unknown[]>(req, 'sl_list_accounts_visible', {
      p_actor_subject: actor(req), p_view: view(req),
    });
    res.json({ data, page: { next_cursor: null } });
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
