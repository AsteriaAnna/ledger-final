import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import express from 'express';
import { registerWeb } from '../src/http/web.js';

test('same-origin host serves only build outputs and preserves API authentication/errors',async t=>{
  const root=await mkdtemp(join(tmpdir(),'ledger-web-'));
  await mkdir(join(root,'assets'));
  await writeFile(join(root,'index.html'),'<html>synthetic app shell</html>');
  await writeFile(join(root,'assets','index-aB123456.js'),'window.synthetic=true;');
  await writeFile(join(root,'.env'),'SYNTHETIC_SECRET=must-not-serve');
  await writeFile(join(root,'assets','.env'),'SYNTHETIC_SECRET=must-not-serve');
  process.env.WEB_DIST_PATH=root;process.env.CLOUDBASE_ENV_ID='synthetic-local-check';
  process.env.CLOUDBASE_API_KEY='synthetic-only-key';
  const {app}=await import('../src/http/app.js');
  const nativeFetch=globalThis.fetch;let mockedAuthCalls=0;
  t.mock.method(globalThis,'fetch',async(input:Parameters<typeof fetch>[0],init?:RequestInit)=>{
    const url=String(input);
    if(url.startsWith('http://127.0.0.1:'))return nativeFetch(input,init);
    assert.equal(url,'https://synthetic-local-check.api.tcloudbasegateway.com/auth/v1/user/me','Unexpected external call blocked');
    mockedAuthCalls++;return new Response(JSON.stringify({sub:'synthetic-host-user'}));
  });
  const server=app.listen(0,'127.0.0.1');await new Promise<void>(ok=>server.once('listening',ok));
  const address=server.address();assert.ok(address&&typeof address==='object');const base='http://127.0.0.1:'+address.port;
  try{
    for(const path of ['/','/index.html']){
      const r=await fetch(base+path,{headers:{'x-cloudbase-context':'synthetic-context-must-not-echo'}});
      assert.equal(r.status,200);assert.match(r.headers.get('content-type')??'',/text\/html/);
      assert.equal(r.headers.get('cache-control'),'no-store');assert.equal(r.headers.get('x-content-type-options'),'nosniff');
      assert.equal(await r.text(),'<html>synthetic app shell</html>');
    }
    const asset=await fetch(base+'/assets/index-aB123456.js');assert.equal(asset.status,200);
    assert.equal(asset.headers.get('cache-control'),'public, max-age=31536000, immutable');
    for(const path of ['/.env','/assets/.env','/package.json','/assets/missing.js','/api/missing','/unknown']){
      const r=await fetch(base+path);assert.equal(r.status,404,path);assert.doesNotMatch(await r.text(),/synthetic app shell|must-not-serve/);
    }
    const health=await fetch(base+'/healthz');assert.deepEqual(await health.json(),{status:'ok'});
    const denied=await fetch(base+'/api/v1/accounts');assert.equal(denied.status,401);
    assert.equal(denied.headers.get('cache-control'),'no-store');assert.equal((await denied.json() as {code:string}).code,'UNAUTHENTICATED');
    const missing=await fetch(base+'/api/v1/missing',{headers:{Authorization:'Bearer synthetic'}});
    assert.equal(missing.status,404);assert.match(missing.headers.get('content-type')??'',/application\/json/);
    assert.equal((await missing.json() as {code:string}).code,'RESOURCE_NOT_FOUND');assert.equal(mockedAuthCalls,1);
  }finally{
    server.closeAllConnections();await new Promise<void>((ok,fail)=>server.close(e=>e?fail(e):ok()));
    assert.ok(root.startsWith(join(tmpdir(),'ledger-web-')));
    await rm(root,{recursive:true,force:true});delete process.env.WEB_DIST_PATH;
  }
});

test('a configured Web directory must contain an actual build before startup',()=>{
  assert.throws(()=>registerWeb(express(),join(tmpdir(),'ledger-nonexistent-build','dist')));
});
