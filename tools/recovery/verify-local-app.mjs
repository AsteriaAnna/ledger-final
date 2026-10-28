// Offline HTTP -> original RPC -> local PostgreSQL check. No real CloudBase
// identity, key or private .env is loaded. Unexpected network calls fail closed.
import assert from 'node:assert/strict';
import {readFile,readdir,writeFile,mkdir} from 'node:fs/promises';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {PGlite} from '@electric-sql/pglite';

const root=fileURLToPath(new URL('../../',import.meta.url));
process.env.CLOUDBASE_ENV_ID='synthetic-local-only';
process.env.CLOUDBASE_API_KEY='synthetic-local-only-server-key';
process.env.CURSOR_SECRET='synthetic-local-only-pagination-secret';
process.env.LEDGER_CONTRACT_PATH=resolve(root,'openapi.yaml');
process.env.WEB_DIST_PATH=resolve(root,'apps/web/dist');
const pg=await PGlite.create();const nativeFetch=globalThis.fetch;
const captures=[];let origin='',server,mockedAuth=0,mockedRpc=0;
try{
  await pg.exec('CREATE ROLE anon;CREATE ROLE authenticated;CREATE ROLE service_role BYPASSRLS;');
  for(const name of (await readdir(resolve(root,'cloudbase/migrations'))).filter(n=>n.endsWith('.sql')).sort()){
    await pg.exec(await readFile(resolve(root,'cloudbase/migrations',name),'utf8'));
  }
  globalThis.fetch=async(input,init)=>{
    const url=new URL(typeof input==='string'?input:input.url??String(input));
    if(origin&&url.origin===origin)return nativeFetch(input,{...init,redirect:'error'});
    assert.equal(url.origin,'https://synthetic-local-only.api.tcloudbasegateway.com','External network request blocked');
    if(url.pathname==='/auth/v1/user/me'){
      mockedAuth++;const token=new Headers(init?.headers).get('Authorization');
      const user=token==='Bearer local-only-a'?'local-only-a':token==='Bearer local-only-b'?'local-only-b':null;
      return user?Response.json({sub:user,name:'Synthetic local user'}):Response.json({}, {status:401});
    }
    const name=url.pathname.replace('/v1/rdb/rest/rpc/','');assert.match(name,/^sl_[a-z_]+$/);
    assert.equal(new Headers(init?.headers).get('Authorization'),'Bearer synthetic-local-only-server-key');
    const args=JSON.parse(init.body);const keys=Object.keys(args);keys.forEach(key=>assert.match(key,/^p_[a-z_]+$/));mockedRpc++;
    try{
      const result=await pg.transaction(async tx=>{
        await tx.exec('SET LOCAL ROLE service_role');
        return (await tx.query(`SELECT public.${name}(${keys.map((key,i)=>key+' => $'+(i+1)).join(',')}) AS value`,
          keys.map(key=>args[key]!==null&&typeof args[key]==='object'?JSON.stringify(args[key]):args[key]))).rows[0].value;
      });return Response.json(result);
    }catch(error){return Response.json({message:error.message},{status:400});}
  };
  const {app}=await import('../../apps/api/dist/http/app.js');
  server=app.listen(0,'127.0.0.1');await new Promise(ok=>server.once('listening',ok));origin='http://127.0.0.1:'+server.address().port;
  const shell=await fetch(origin+'/');assert.equal(shell.status,200);const html=await shell.text();
  const asset=html.match(/src="([^"]+\.js)"/);assert.ok(asset);assert.equal((await fetch(origin+asset[1])).status,200);
  async function req(operationId,path,{user='a',method='GET',body,status=200,headers={}}={}){
    const r=await fetch(origin+'/api/v1'+path,{method,headers:{Authorization:'Bearer local-only-'+user,'Content-Type':'application/json',...headers},body:body===undefined?undefined:JSON.stringify(body)});
    const response=await r.json();assert.equal(r.status,status,operationId+': '+JSON.stringify(response));assert.equal(r.headers.get('cache-control'),'no-store');
    captures.push({operationId,status:r.status,response,...(body===undefined?{}:{request:body})});return response.data;
  }
  assert.deepEqual(await req('listAccounts','/accounts'),[]);
  assert.equal((await pg.query('SELECT count(*)::integer AS n FROM public.sl_users')).rows[0].n,0,'Read must not provision a user');
  const today=new Date(Date.now()+8*3600000).toISOString().slice(0,10);
  const account=await req('createAccount','/accounts',{method:'POST',status:201,headers:{'Idempotency-Key':'local-account'},body:{
    name:'Local release account',account_type:'cash',custodian:'self',opening_state:{opening_date:today,opening_balance_minor:10000,
      opening_allocations:[{fund_owner:'self',fund_type:'liquid',amount_minor:10000}]}}});
  const expense={type:'expense',account_id:account.id,amount_minor:2580,occurred_at:today+'T00:00:00+08:00',category_code:'food',merchant:'Synthetic meal',note:''};
  const first=await req('createTransaction','/transactions',{method:'POST',status:201,headers:{'Idempotency-Key':'local-expense'},body:expense});
  const again=await req('createTransaction','/transactions',{method:'POST',status:201,headers:{'Idempotency-Key':'local-expense'},body:expense});
  assert.equal(first.transaction.id,again.transaction.id);
  const refreshed=await req('getAccount','/accounts/'+account.id);assert.equal(refreshed.balance_minor,7420);
  const invitation=await req('createBindingInvitation','/relationship/invitations',{method:'POST',status:201,headers:{'Idempotency-Key':'local-invitation'},body:{}});
  await req('bindRelationship','/relationship/binding',{user:'b',method:'POST',headers:{'Idempotency-Key':'local-binding'},body:{binding_token:invitation.binding_token}});
  const partnerAccounts=await req('listAccounts','/accounts?view=partner',{user:'b'});assert.equal(partnerAccounts[0].read_only,true);assert.equal(partnerAccounts[0].balance_minor,7420);
  await req('patchAccount','/accounts/'+account.id,{user:'b',method:'PATCH',status:404,headers:{'If-Match':'"'+refreshed.version+'"'},body:{name:'Must not overwrite'}});
  assert.equal((await req('getAccount','/accounts/'+account.id)).name,'Local release account');
  await req('putBudget','/budgets/'+today.slice(0,7),{method:'PUT',body:{budget_minor:5000,expected_version:0}});
  const overview=await req('getOverview','/overview?month='+today.slice(0,7));assert.equal(overview.personal_spending.month_spent_minor,2580);assert.equal(overview.budget.remaining_minor,2420);
  const summary={mode:'offline HTTP + original PG migrations; Auth/gateway explicitly mocked',cloud_network_requests:0,
    static_shell_and_asset:true,http_captures:captures.length,mocked_auth_calls:mockedAuth,mocked_rpc_calls:mockedRpc,
    account_balance_minor:7420,transactions:(await pg.query('SELECT count(*)::integer AS n FROM public.sl_transactions')).rows[0].n,
    partner_read_only_and_write_rejected:true,budget_remaining_minor:2420};assert.equal(summary.transactions,1);
  await mkdir(resolve(root,'tmp'),{recursive:true});
  await writeFile(resolve(root,'tmp/local-app-captures.json'),JSON.stringify(captures,null,2));
  await writeFile(resolve(root,'tmp/local-app-verification.json'),JSON.stringify(summary,null,2)+'\n');console.log(JSON.stringify(summary,null,2));
}catch(error){console.error(error.message);process.exitCode=1;}finally{
  if(server){server.closeAllConnections();await new Promise(ok=>server.close(ok));}
  globalThis.fetch=nativeFetch;await pg.close();
}
