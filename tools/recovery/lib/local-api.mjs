// Test-only boundary. Never imported by application or deployment code.
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {PGlite} from '@electric-sql/pglite';

export async function startLocalApi(){
  const root=fileURLToPath(new URL('../../../',import.meta.url));
  Object.assign(process.env,{CLOUDBASE_ENV_ID:'synthetic-local-only',CLOUDBASE_API_KEY:'synthetic-local-only-server-key',
    CURSOR_SECRET:'synthetic-local-only-pagination-secret',LEDGER_CONTRACT_PATH:resolve(root,'openapi.yaml'),WEB_DIST_PATH:resolve(root,'apps/web/dist')});
  const pg=await PGlite.create(),nativeFetch=globalThis.fetch;
  const counters={mocked_auth_calls:0,mocked_rpc_calls:0,blocked_external_calls:0};let origin='',server;
  const close=async()=>{
    if(server?.listening){server.closeAllConnections();await new Promise(ok=>server.close(ok));}
    globalThis.fetch=nativeFetch;await pg.close();
  };
  try{
    await pg.exec('CREATE ROLE anon;CREATE ROLE authenticated;CREATE ROLE service_role BYPASSRLS;');
    for(const name of (await readdir(resolve(root,'cloudbase/migrations'))).filter(n=>n.endsWith('.sql')).sort())await pg.exec(await readFile(resolve(root,'cloudbase/migrations',name),'utf8'));
    globalThis.fetch=async(input,init)=>{
      const url=new URL(typeof input==='string'?input:input.url??String(input));
      if(origin&&url.origin===origin)return nativeFetch(input,{...init,redirect:'error'});
      if(url.origin!=='https://synthetic-local-only.api.tcloudbasegateway.com'){
        counters.blocked_external_calls++;throw new Error('External network request blocked');
      }
      if(url.pathname==='/auth/v1/user/me'){
        counters.mocked_auth_calls++;const token=new Headers(init?.headers).get('Authorization');
        const user=token==='Bearer local-only-a'?'local-only-a':token==='Bearer local-only-b'?'local-only-b':null;
        return user?Response.json({sub:user,name:'Synthetic local user'}):Response.json({},{status:401});
      }
      const name=url.pathname.replace('/v1/rdb/rest/rpc/','');assert.match(name,/^sl_[a-z_]+$/);
      assert.equal(new Headers(init?.headers).get('Authorization'),'Bearer synthetic-local-only-server-key');
      const args=JSON.parse(init.body),keys=Object.keys(args);keys.forEach(key=>assert.match(key,/^p_[a-z_]+$/));counters.mocked_rpc_calls++;
      try{
        const result=await pg.transaction(async tx=>{
          await tx.exec('SET LOCAL ROLE service_role');
          return (await tx.query(`SELECT public.${name}(${keys.map((key,i)=>key+' => $'+(i+1)).join(',')}) AS value`,
            keys.map(key=>args[key]!==null&&typeof args[key]==='object'?JSON.stringify(args[key]):args[key]))).rows[0].value;
        });return Response.json(result);
      }catch(error){return Response.json({message:error.message},{status:400});}
    };
    const {app}=await import('../../../apps/api/dist/http/app.js');
    server=app.listen(0,'127.0.0.1');await new Promise(ok=>server.once('listening',ok));origin='http://127.0.0.1:'+server.address().port;
    return {root,pg,origin,counters,close};
  }catch(error){await close();throw error;}
}
