import { createHash, randomBytes } from 'node:crypto';
import type { Express } from 'express';
import { DomainError } from '../../domain/ledger.js';
import { actor, key, payloadHash, route, rpc } from '../../http/request.js';

function bindingToken(body: unknown): string {
  if (!body || typeof body !== 'object' || Array.isArray(body) ||
    Object.keys(body).length !== 1 || !('binding_token' in body) ||
    typeof body.binding_token !== 'string' || !body.binding_token.trim() || body.binding_token.length > 128) {
    throw new DomainError(422, 'VALIDATION_ERROR', '请输入有效的绑定凭据。');
  }
  return body.binding_token;
}

export function registerRelationshipRoutes(app: Express): void {
  app.get('/api/v1/relationship', route(async (req, res) => {
    const data = await rpc(req, 'sl_get_relationship', { p_actor_subject: actor(req) });
    res.json({ data });
  }));

  app.post('/api/v1/relationship/invitations', route(async (req, res) => {
    if (!req.body || typeof req.body !== 'object' || Array.isArray(req.body) || Object.keys(req.body).length) {
      throw new DomainError(422, 'VALIDATION_ERROR', '生成邀请不需要填写内容。');
    }
    const token = randomBytes(32).toString('base64url');
    const data = await rpc(req, 'sl_create_invitation', {
      p_actor_subject: actor(req), p_key_digest: key(req), p_payload_hash: payloadHash({}),
      p_token_hash: createHash('sha256').update(token).digest('hex'), p_token: token,
    });
    res.status(201).json({ data });
  }));

  app.post('/api/v1/relationship/binding', route(async (req, res) => {
    const token = bindingToken(req.body);
    const data = await rpc(req, 'sl_bind_relationship', {
      p_actor_subject: actor(req), p_key_digest: key(req), p_payload_hash: payloadHash({ binding_token: token }),
      p_token_hash: createHash('sha256').update(token).digest('hex'),
    });
    res.json({ data });
  }));
}
