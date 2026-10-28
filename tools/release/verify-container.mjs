// Invoked inside the Linux image with --network none. No Auth or business calls.
import assert from 'node:assert/strict';
import {access,readFile} from 'node:fs/promises';
assert.equal(process.platform,'linux');assert.notEqual(process.getuid(),0);
assert.equal(process.env.NODE_ENV,'production');assert.equal(process.env.PORT,'9000');
const origin='http://127.0.0.1:9000';
const health=await fetch(origin+'/healthz');assert.equal(health.status,200);assert.deepEqual(await health.json(),{status:'ok'});
const index=await fetch(origin+'/');assert.equal(index.status,200);assert.match(index.headers.get('cache-control'),/no-store/);
const html=await index.text();assert.match(html,/<title>星账<\/title>/);
const asset=html.match(/src="([^"]+\.js)"/);assert.ok(asset);
const js=await fetch(origin+asset[1]);assert.equal(js.status,200);assert.match(js.headers.get('cache-control'),/immutable/);
const javascript=await js.text();assert.ok(!javascript.includes('synthetic-local-only-server-key'));
assert.ok(!javascript.includes('ledger-local-browser-session'),'Local Auth substitute must not enter production image');
assert.equal((await fetch(origin+'/api/v1/accounts')).status,401);
// API auth runs before routing, including unknown paths. It must never return HTML.
const unknown=await fetch(origin+'/api/v1/unknown');assert.equal(unknown.status,401);assert.match(unknown.headers.get('content-type'),/application\/json/);
for(const path of ['/.env','/package.json','/openapi.yaml','/src/main.tsx','/tmp/recovery/snapshot.json'])
  assert.equal((await fetch(origin+path)).status,404,path);
await access('/app/openapi.yaml');await access('/app/apps/api/dist/server.js');
for(const path of ['/app/apps/api/.env.local','/app/apps/web/.env.local','/app/tools/recovery','/app/tmp','/app/.git'])
  await assert.rejects(access(path),{code:'ENOENT'});
const apiPackage=JSON.parse(await readFile('/app/apps/api/package.json','utf8'));assert.equal(apiPackage.name,'@ledger/api');
console.log('Linux container verified: non-root, 9000, Web/assets, fixed health, API 401/404, private files absent, network disabled.');
