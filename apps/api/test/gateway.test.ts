import assert from 'node:assert/strict';
import { test } from 'node:test';
import { DomainError } from '../src/domain/ledger.js';

process.env.CLOUDBASE_ENV_ID = 'synthetic-contract-test';
process.env.CLOUDBASE_API_KEY = 'synthetic-test-key';
const { callRpc,verifyAccessToken } = await import('../src/infrastructure/cloudbase.js');

test('temporary Auth outage does not masquerade as an expired user session',async t=>{
  let status=503;t.mock.method(globalThis,'fetch',async()=>new Response('{}',{status}));
  for(const code of [503,429]){status=code;await assert.rejects(verifyAccessToken('synthetic'),e=>e instanceof DomainError&&e.status===500);}
  status=401;await assert.rejects(verifyAccessToken('synthetic'),e=>e instanceof DomainError&&e.status===401);
});

test('provider failures map to the published error codes and statuses', async (t) => {
  let providerMessage = '';
  t.mock.method(globalThis, 'fetch', async () => new Response(JSON.stringify({ message: providerMessage }), { status: 400 }));
  for (const [message, status, code] of [
    ['sl_account_not_found', 404, 'RESOURCE_NOT_FOUND'],
    ['sl_version_mismatch', 412, 'RESOURCE_VERSION_CONFLICT'],
    ['sl_insufficient_funds', 409, 'FUNDS_ALLOCATION_NOT_POSSIBLE'],
    ['sl_unsafe_reversal', 409, 'FUNDS_ALLOCATION_NOT_POSSIBLE'],
    ['sl_opening_recalculation_conflict', 409, 'OPENING_STATE_RECALCULATION_CONFLICT'],
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
  await assert.rejects(callRpc('sl_import_json', { p_subject: 'fixture',p_batch:'missing' }),
    (error: unknown) => error instanceof DomainError && error.code === 'RESOURCE_NOT_FOUND');
  assert.deepEqual(await callRpc('sl_accounts_page',{p_actor_subject:'fixture',p_view:'mine'}),{data:[],next:null});
  assert.deepEqual(await callRpc('sl_transactions_page',{p_actor_subject:'fixture',p_view:'mine'}),{data:[],next:null});
  assert.equal(fetchMock.mock.callCount(), 7);
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

test('an interrupted import is not retried automatically and keeps its explicit retry arguments',async t=>{
  const budgets:number[]=[];const bodies:string[]=[];let interrupted=true;
  t.mock.method(AbortSignal,'timeout',(ms:number)=>{budgets.push(ms);return new AbortController().signal;});
  t.mock.method(globalThis,'fetch',async(_url:Parameters<typeof fetch>[0],init?:RequestInit)=>{
    bodies.push(String(init?.body));if(interrupted)throw new DOMException('synthetic interrupted response','AbortError');
    return new Response(JSON.stringify({saved:true}));
  });
  const args={p_actor_subject:'synthetic',p_key_digest:'same-request',p_payload_hash:'same-content'};
  await assert.rejects(callRpc('sl_import_upload',args),e=>e instanceof DomainError&&e.status===500);
  assert.equal(bodies.length,1,'Do not repeat a write whose outcome is unknown');
  interrupted=false;assert.deepEqual(await callRpc('sl_import_upload',args),{saved:true});assert.equal(bodies[0],bodies[1]);
  await callRpc('sl_accounts_page',{p_actor_subject:'synthetic',p_view:'mine'});
  assert.deepEqual(budgets,[45000,45000,12000]);
});
