import assert from 'node:assert/strict';
import { test } from 'node:test';
import { DomainError } from '../src/domain/ledger.js';

process.env.CLOUDBASE_ENV_ID = 'synthetic-contract-test';
process.env.CLOUDBASE_API_KEY = 'synthetic-test-key';
const { callRpc } = await import('../src/infrastructure/cloudbase.js');

test('provider failures map to the published error codes and statuses', async (t) => {
  let providerMessage = '';
  t.mock.method(globalThis, 'fetch', async () => new Response(JSON.stringify({ message: providerMessage }), { status: 400 }));
  for (const [message, status, code] of [
    ['sl_account_not_found', 404, 'RESOURCE_NOT_FOUND'],
    ['sl_version_mismatch', 412, 'RESOURCE_VERSION_CONFLICT'],
    ['sl_insufficient_funds', 409, 'FUNDS_ALLOCATION_NOT_POSSIBLE'],
    ['sl_unsafe_reversal', 409, 'FUNDS_ALLOCATION_NOT_POSSIBLE'],
    ['sl_partner_unavailable', 403, 'FORBIDDEN'],
    ['unrecognized provider failure', 500, 'INTERNAL_ERROR'],
  ] as const) {
    providerMessage = message;
    await assert.rejects(callRpc('sl_adjust_funds', { p_actor_subject: 'fixture' }),
      (error: unknown) => error instanceof DomainError && error.status === status && error.code === code);
  }
});

test('fresh identity reads return empty state without provisioning writes', async (t) => {
  const fetchMock = t.mock.method(globalThis, 'fetch', async () =>
    new Response(JSON.stringify({ message: 'sl_user_not_provisioned' }), { status: 400 }));
  assert.deepEqual(await callRpc('sl_list_accounts_visible', { p_actor_subject: 'fixture', p_view: 'mine' }), []);
  assert.deepEqual(await callRpc('sl_list_transactions_visible', { p_actor_subject: 'fixture', p_view: 'mine' }), []);
  assert.deepEqual(await callRpc('sl_get_relationship', { p_actor_subject: 'fixture' }), {
    status: 'unbound', partner: null, permissions: { partner_accounts: 'none', partner_transactions: 'none' },
  });
  await assert.rejects(callRpc('sl_get_account_visible', { p_actor_subject: 'fixture' }),
    (error: unknown) => error instanceof DomainError && error.code === 'RESOURCE_NOT_FOUND');
  assert.equal(fetchMock.mock.callCount(), 4);
  assert.ok(fetchMock.mock.calls.every(call => !String(call.arguments[0]).includes('sl_provision_user')));
});

test('first write provisions once and retries the original RPC once', async (t) => {
  let call = 0;
  const fetchMock = t.mock.method(globalThis, 'fetch', async () => {
    call++;
    return call === 1 ? new Response(JSON.stringify({ message: 'sl_user_not_provisioned' }), { status: 400 }) :
      new Response(JSON.stringify(call === 2 ? 'synthetic-user-id' : { saved: true }), { status: 200 });
  });
  assert.deepEqual(await callRpc('sl_create_account', { p_actor_subject: 'fixture' }), { saved: true });
  assert.deepEqual(fetchMock.mock.calls.map(item => String(item.arguments[0]).split('/').at(-1)),
    ['sl_create_account', 'sl_provision_user', 'sl_create_account']);
});
