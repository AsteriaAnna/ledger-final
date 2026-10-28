import fs from 'node:fs';
import assert from 'node:assert/strict';
import cloudbase from '@cloudbase/js-sdk';
assert.ok(process.env.LEDGER_TEST_USERNAME?.startsWith('sl_stats_'),'Requires disposable stats credentials');
const config=Object.fromEntries(fs.readFileSync('apps/web/.env.local','utf8').split(/\r?\n/).filter(x=>x.includes('=')).map(x=>{const n=x.indexOf('=');return[x.slice(0,n),x.slice(n+1).replace(/^['"]|['"]$/g,'')]}));
const app=cloudbase.init({env:config.VITE_CLOUDBASE_ENV_ID,region:'ap-shanghai',accessKey:config.VITE_PUBLISHABLE_KEY});
const login=await app.auth.signInWithPassword({username:process.env.LEDGER_TEST_USERNAME,password:process.env.LEDGER_TEST_PASSWORD});
assert.ok(login.data?.session?.access_token);const token=login.data.session.access_token,captures=[];let seq=0;
const now=new Date(Date.now()+8*3600000),today=now.toISOString().slice(0,10),month=today.slice(0,7),time=today+'T00:00:00+08:00';
const key=()=>({'Idempotency-Key':'overview-http-'+(++seq)});
async function req(operationId,path,method='GET',request,expected=200,headers={},validRequest=true){
 const r=await fetch('http://127.0.0.1:3000/api/v1'+path,{method,headers:{Authorization:'Bearer '+token,'Content-Type':'application/json',...headers},body:request===undefined?undefined:JSON.stringify(request)});
 const body=await r.json();assert.equal(r.status,expected,operationId+': '+JSON.stringify(body));
 captures.push({operationId,status:r.status,response:body,...(request===undefined?{}:{request,validRequest})});
 fs.writeFileSync('tmp/overview-http-captures.json',JSON.stringify(captures));return 'data' in body?body.data:body;
}
let overview=await req('getOverview','/overview?month='+month);assert.equal(overview.funds.visible_total_minor,0);assert.equal(overview.funds.partner_savings_minor,null);
assert.equal(await req('getBudget','/budgets/'+month),null);
await req('getOverview','/overview?month=9999-12','GET',undefined,422);
await req('getBudget','/budgets/2026-13','GET',undefined,422);
await req('putBudget','/budgets/'+month,'PUT',{budget_minor:-1,expected_version:0},422,{},false);
await req('putBudget','/budgets/'+month,'PUT',{budget_minor:1,expected_version:0,user_id:'forged'},422,{},false);
const results=await Promise.all([1,2].map(async()=>{const r=await fetch('http://127.0.0.1:3000/api/v1/budgets/'+month,{method:'PUT',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify({budget_minor:1000,expected_version:0})});const response=await r.json();captures.push({operationId:'putBudget',status:r.status,response,request:{budget_minor:1000,expected_version:0}});return r.status;}));
assert.deepEqual(results.sort(),[200,409]);
let budget=await req('getBudget','/budgets/'+month);assert.equal(budget.version,1);
assert.deepEqual(await req('putBudget','/budgets/'+month,'PUT',{budget_minor:1000,expected_version:1}),budget);
budget=await req('putBudget','/budgets/'+month,'PUT',{budget_minor:2000,expected_version:1});assert.equal(budget.version,2);
await req('putBudget','/budgets/2027-01','PUT',{budget_minor:0,expected_version:0});
const accounts=[];for(const name of ['统计验证账户A','统计验证账户B','统计验证账户C'])accounts.push(await req('createAccount','/accounts','POST',{name,account_type:'cash',custodian:'self',opening_state:{opening_date:today,opening_balance_minor:100000,opening_allocations:[{fund_owner:'self',fund_type:'liquid',amount_minor:100000}]}},201,key()));
async function tx(input){return req('createTransaction','/transactions','POST',{occurred_at:time,...input},201,key());}
await tx({type:'expense',account_id:accounts[0].id,amount_minor:700,category_code:'food',merchant:'合成%餐饮'});
await tx({type:'expense',account_id:accounts[0].id,amount_minor:300,category_code:'transport',merchant:'合成交通'});
await tx({type:'income',account_id:accounts[0].id,amount_minor:2000});
await tx({type:'transfer',from_account_id:accounts[0].id,to_account_id:accounts[1].id,amount_minor:500});
overview=await req('getOverview','/overview?month='+month);assert.equal(overview.funds.visible_total_minor,301000);assert.equal(overview.personal_spending.month_spent_minor,1000);assert.equal(overview.personal_spending.daily_change_rate,null);
assert.equal(overview.personal_spending.daily_average_minor,Math.round(1000/Number(today.slice(8))));
assert.equal(overview.budget.remaining_minor,1000);
budget=await req('putBudget','/budgets/'+month,'PUT',{budget_minor:500,expected_version:2});overview=await req('getOverview','/overview?month='+month);assert.equal(overview.budget.over_budget_minor,500);
// Read full envelopes for pagination metadata, and validate every capture.
async function page(operationId,path){const r=await fetch('http://127.0.0.1:3000/api/v1'+path,{headers:{Authorization:'Bearer '+token}});const response=await r.json();assert.equal(r.status,200);captures.push({operationId,status:200,response});return response;}
let p=await page('listAccounts','/accounts?limit=1'),ids=[p.data[0].id];while(p.page.next_cursor){p=await page('listAccounts','/accounts?limit=1&cursor='+encodeURIComponent(p.page.next_cursor));ids.push(...p.data.map(a=>a.id));}assert.equal(new Set(ids).size,3);
p=await page('listTransactions','/transactions?limit=1&type=expense');const cursor=p.page.next_cursor;assert.ok(cursor);
const second=await page('listTransactions','/transactions?limit=1&type=expense&cursor='+encodeURIComponent(cursor));assert.notEqual(p.data[0].id,second.data[0].id);assert.equal(second.page.next_cursor,null);
await req('listTransactions','/transactions?type=income&cursor='+encodeURIComponent(cursor),'GET',undefined,422);
await req('listTransactions','/transactions?cursor='+encodeURIComponent(cursor+'x'),'GET',undefined,422);
assert.equal((await req('listTransactions','/transactions?from='+today+'&to='+today+'&category_code=food')).length,1);
assert.equal((await req('listTransactions','/transactions?type=transfer&account_id='+accounts[1].id)).length,1);
assert.equal((await req('listTransactions','/transactions?q=%25')).length,1);
await req('listAccounts','/accounts?limit=101','GET',undefined,422);await req('listTransactions','/transactions?from=2026-02-30','GET',undefined,422);
await req('getImport','/imports/missing?limit=101','GET',undefined,422);
assert.equal((await req('getAccount','/accounts/'+accounts[0].id)).balance_minor,100500);
fs.writeFileSync('tmp/overview-http-captures.json',JSON.stringify(captures));console.log('Overview/budget/filter/pagination real Auth HTTP assertions passed; captures:',captures.length);
await app.auth.signOut();process.exit(0);
