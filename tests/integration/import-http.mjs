// Development-only synthetic HTTP test. Provision a disposable Auth user first.
// Run from repo root with LEDGER_TEST_USERNAME/PASSWORD; captures stay ignored.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import cloudbase from '@cloudbase/js-sdk';
import {officialWorkbook,wxRow} from '../../apps/api/test-dist/test/fixtures/official.js';
import {exerciseImportEdges} from './import-edges.mjs';
const config=Object.fromEntries(fs.readFileSync('apps/web/.env.local','utf8').split(/\r?\n/).filter(x=>x.includes('=')).map(x=>{const n=x.indexOf('=');return [x.slice(0,n),x.slice(n+1).replace(/^['"]|['"]$/g,'')]}));
assert.ok(process.env.LEDGER_TEST_USERNAME?.startsWith('sl_import_'),'Requires explicitly disposable test credentials');
const app=cloudbase.init({env:config.VITE_CLOUDBASE_ENV_ID,region:'ap-shanghai',accessKey:config.VITE_PUBLISHABLE_KEY});
const login=await app.auth.signInWithPassword({username:process.env.LEDGER_TEST_USERNAME,password:process.env.LEDGER_TEST_PASSWORD});
assert.ok(login.data?.session?.access_token,'synthetic login failed');const token=login.data.session.access_token;
const captures=[];let sequence=0;
async function req(operationId,path,method='GET',request,expected=200,headers={},validRequest=true){
 const r=await fetch('http://127.0.0.1:3000/api/v1'+path,{method,headers:{Authorization:'Bearer '+token,...(request instanceof FormData?{}:{'Content-Type':'application/json'}),...headers},body:request===undefined?undefined:request instanceof FormData?request:JSON.stringify(request)});
 const body=await r.json();assert.equal(r.status,expected,operationId+': '+JSON.stringify(body));
 captures.push({operationId,status:r.status,response:body,...(request===undefined||request instanceof FormData?{}:{request,validRequest})});
 fs.writeFileSync('tmp/import-http-captures.json',JSON.stringify(captures));return body.data??body;
}
const key=()=>({'Idempotency-Key':'synthetic-import-'+(++sequence)});
async function createTx(input){return req('createTransaction','/transactions','POST',input,201,key());}
async function account(name){return req('createAccount','/accounts','POST',{name,account_type:'cash',custodian:'self',opening_state:{opening_date:'2026-10-01',opening_balance_minor:100000,opening_allocations:[{fund_owner:'self',fund_type:'liquid',amount_minor:100000}]}},201,key());}
const a=await account('导入验证零钱'),b=await account('导入验证银行卡');
const rows=[wxRow('expense-id'),wxRow('refund-44','商户退款','收入','0.44'),wxRow('refund-26','商户退款','收入','0.26'),
 wxRow('return-id','转账-退款','收入','1.00'),wxRow('income-id','其他','收入','20.00'),
 wxRow('family-id','商户消费','支出','10','亲情卡'),wxRow('closed-id','商户消费','支出','10','零钱','交易关闭'),
 wxRow('unknown-id','商户消费','支出','10','零钱','未知状态'),wxRow('role-id','转账','收入','5.00'),
 wxRow('fee-id','零钱提现','支出','10','银行','提现已到账','服务费¥1.00')];
const fileCache=new Map();
async function upload(rows,profile,options={},idem=key()){
 const cacheKey=JSON.stringify({rows,options});if(!fileCache.has(cacheKey))fileCache.set(cacheKey,await officialWorkbook('wechat',rows,options));
 const buffer=fileCache.get(cacheKey);const form=new FormData();form.append('file',new Blob([buffer]),'合成官方账单.xlsx');if(profile)form.append('source_account_profile_id',profile);
 return req('uploadImport','/imports','POST',form,201,idem);
}
async function resolve(batch,input,expected=200,idem=key()){return req('resolveImport',`/imports/${batch.batch_id}/resolutions`,'POST',input,expected,idem);}
async function current(batch){return req('getImport',`/imports/${batch.batch_id}`);}
const idem=key();let batch=await upload(rows,undefined,{},idem);
assert.equal(batch.summary.read_rows,10);assert.equal(batch.source_account_profile,null);
assert.equal((await upload(rows,undefined,{},idem)).batch_id,batch.batch_id);
batch=await resolve(batch,{action:'select_source_profile',profile_version:0,create_label:'合成微信账号'});
const profile=batch.source_account_profile.id;
await req('putMapping','/source-payment-method-mappings','PUT',{source_account_profile_id:profile,canonical_method_key:'微信零钱',account_id:a.id,expected_version:0});
batch=await resolve(batch,{action:'resume'});
assert.equal(batch.summary.created,5,JSON.stringify(batch.summary));assert.equal(batch.summary.unsupported,2);assert.equal(batch.summary.ineffective,1);assert.equal(batch.summary.needs_review,2);
assert.equal(batch.coverage.reconciliation_eligible,false);
const role=batch.rows.find(r=>r.evidence.raw_fields['交易单号']==='role-id');
await resolve(batch,{action:'set_transfer_role',observation_id:role.observation_id,expected_source_version:role.source_version,type:'expense',account_id:a.id},422);
batch=await resolve(batch,{action:'set_transfer_role',observation_id:role.observation_id,expected_source_version:role.source_version,type:'income',account_id:a.id});
assert.equal(batch.summary.created,6);
const refund=batch.rows.find(r=>r.evidence.raw_fields['交易单号']==='refund-44');
let refundTx=await req('getTransaction','/transactions/'+refund.transaction_id);
assert.equal(refundTx.type,'refund');assert.equal(refundTx.refund_kind,'merchant_refund');assert.equal(refundTx.affects_spending,true);assert.equal(refundTx.amount_minor,44);
const balanceBefore=(await req('getAccount','/accounts/'+a.id)).balance_minor;
refundTx=(await req('patchTransaction','/transactions/'+refundTx.id,'PATCH',{affects_spending:false},200,{'If-Match':'"1"'})).transaction;
assert.equal((await req('getAccount','/accounts/'+a.id)).balance_minor,balanceBefore);
await req('patchTransaction','/transactions/'+refundTx.id,'PATCH',{type:'income'},422,{'If-Match':'"2"'});
const incomeRow=batch.rows.find(r=>r.evidence.raw_fields['交易单号']==='income-id');
let income=(await req('patchTransaction','/transactions/'+incomeRow.transaction_id,'PATCH',{amount_minor:3050,occurred_at:'2026-09-12T12:00:00+08:00'},200,{'If-Match':'"1"'})).transaction;
assert.equal(income.source_summaries[0].source_occurred_at,'2026-10-10T12:00:00+08:00');
let repeated=await upload(rows,profile);assert.equal(repeated.summary.duplicate_existing,6);
assert.equal((await req('getTransaction','/transactions/'+income.id)).amount_minor,3050);
await req('deleteTransaction','/transactions/'+refundTx.id,'DELETE',undefined,200,{'If-Match':'"2"'});
assert.equal((await current(batch)).rows.find(r=>r.observation_id===refund.observation_id).transaction_id,null);
repeated=await upload(rows,profile);const restored=repeated.rows.find(r=>r.evidence.raw_fields['交易单号']==='refund-44');
assert.ok(restored.transaction_id);assert.notEqual(restored.transaction_id,refundTx.id);assert.equal(restored.disposition,'created');
const changed=rows.map(r=>r[8]==='income-id'?wxRow('income-id','其他','收入','55.00'):r);
let newer=await upload(changed,profile,{exported:'2026-10-28 00:00:00'});
const difference=newer.rows.find(r=>r.evidence.raw_fields['交易单号']==='income-id');assert.ok(difference.reason_codes.includes('SOURCE_CHANGED'));
newer=await resolve(newer,{action:'accept_source_change',observation_id:difference.observation_id,expected_source_version:difference.source_version});
assert.equal((await req('getTransaction','/transactions/'+income.id)).amount_minor,3050);
const stale=await upload(rows,profile);assert.equal(stale.rows.find(r=>r.evidence.raw_fields['交易单号']==='income-id').disposition,'duplicate_existing');
// Weak fields never silently match a manual event. Link, then missing reconciliation.
await createTx({type:'expense',account_id:a.id,source_account_profile_id:profile,amount_minor:777,occurred_at:'2026-10-15T12:00:00+08:00',merchant:'手动同事件'});
const missing=await createTx({type:'expense',account_id:b.id,source_account_profile_id:profile,amount_minor:1234,occurred_at:'2026-10-16T12:00:00+08:00',merchant:'手动核对'});
const fullRows=[wxRow('manual-link-id','商户消费','支出','7.77','零钱','支付成功','','2026-10-15 12:00:00')];
let full=await upload(fullRows,profile);const match=full.rows[0];assert.equal(match.disposition,'needs_review');assert.equal(match.candidate_transaction_ids.length,1);
full=await resolve(full,{action:'link_existing_transaction',observation_id:match.observation_id,expected_source_version:match.source_version,transaction_id:match.candidate_transaction_ids[0]});
assert.equal(full.rows[0].disposition,'linked_existing');
full=await resolve(full,{action:'resume'});assert.equal(full.coverage.reconciliation_eligible,true);
let item=full.reconciliation_items.find(i=>i.transaction_id===missing.transaction.id);assert.ok(item);
const reviewInput={reconciliation_item_id:item.id,expected_version:item.version,action:'keep_manual'},reviewKey=key();
const kept=await req('reviewReconciliation',`/imports/${full.batch_id}/reconciliation-reviews`,'POST',reviewInput,200,reviewKey);
assert.equal(kept.status,'kept_manual');assert.deepEqual(await req('reviewReconciliation',`/imports/${full.batch_id}/reconciliation-reviews`,'POST',reviewInput,200,reviewKey),kept);
const overlap=await upload(fullRows,profile);assert.equal(overlap.reconciliation_items.find(i=>i.transaction_id===missing.transaction.id).id,item.id);
item=(await current(full)).reconciliation_items.find(i=>i.id===item.id);
await req('reviewReconciliation',`/imports/${full.batch_id}/reconciliation-reviews`,'POST',{reconciliation_item_id:item.id,expected_version:item.version,action:'delete_manual_transaction'},200,key());
await req('getTransaction','/transactions/'+missing.transaction.id,'GET',undefined,404);
// Wallets cannot be assigned to another source profile, while a bank can be reused.
let other=await upload([wxRow('other-profile-id')]);other=await resolve(other,{action:'select_source_profile',profile_version:0,create_label:'另一合成微信'});
await req('putMapping','/source-payment-method-mappings','PUT',{source_account_profile_id:other.source_account_profile.id,canonical_method_key:'微信零钱',account_id:a.id,expected_version:0},422);
await req('putMapping','/source-payment-method-mappings','PUT',{source_account_profile_id:other.source_account_profile.id,canonical_method_key:'合成银行卡',account_id:b.id,expected_version:0});
await req('getImport',`/imports/${batch.batch_id}?limit=2`);const form=new FormData();form.append('file',new Blob([new Uint8Array(10*1024*1024+1)]),'过大.xlsx');await req('uploadImport','/imports','POST',form,413,key());
await exerciseImportEdges({req,upload,resolve,current,createTx,a,profile,batch,income,key});
fs.writeFileSync('tmp/import-ui.xlsx',await officialWorkbook('wechat',[wxRow('browser-import-id','其他','收入','2.50')]));
console.log('Official import real HTTP assertions passed; captures:',captures.length,'profile:',profile);
await app.auth.signOut();process.exit(0);
