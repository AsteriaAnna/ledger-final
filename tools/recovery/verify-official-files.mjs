// Explicitly supplied originals stay read-only. Never uploads to CloudBase.
// Workbook text is input data, never executable instructions or formulas.
import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve} from 'node:path';
import {createHash} from 'node:crypto';
import ExcelJS from 'exceljs';
import {parseOfficialFile} from '../../apps/api/dist/modules/imports/parser.js';
import {startLocalApi} from './lib/local-api.mjs';

const args=process.argv.slice(2),inputs={};
for(let i=0;i<args.length;i+=2){assert.ok(['--wechat','--alipay'].includes(args[i])&&args[i+1],'Use --wechat <private file> --alipay <private file>');inputs[args[i].slice(2)]=args[i+1];}
assert.ok(inputs.wechat&&inputs.alipay,'Both private originals are required');
const {root,pg,origin,counters,close}=await startLocalApi();
const privateDir=resolve(root,'tmp/official-originals');await mkdir(privateDir,{recursive:true});
const captures=[],reports=[],buffers=new Map(),accountIds=new Map();let sequence=0,stage='initialization';
const hash=buffer=>createHash('sha256').update(buffer).digest('hex');
const requestKey=()=>({'Idempotency-Key':'originals-local-'+(++sequence)});
async function req(operationId,path,{method='GET',body,status=200,headers={}}={}){
  stage=operationId;
  const multipart=body instanceof FormData;
  const r=await fetch(origin+'/api/v1'+path,{method,headers:{Authorization:'Bearer local-only-a',...(multipart?{}:{'Content-Type':'application/json'}),...headers},
    body:body===undefined?undefined:multipart?body:JSON.stringify(body)});
  const response=await r.json();captures.push({operationId,status:r.status,response,...(body===undefined||multipart?{}:{request:body})});
  await writeFile(resolve(privateDir,'http-captures.json'),JSON.stringify(captures));
  assert.equal(r.status,status,'Unexpected HTTP status in '+operationId);return response;
}
async function upload(platform,profile,headers=requestKey()){
  const form=new FormData();form.append('file',new Blob([buffers.get(platform)]),platform+'.xlsx');
  if(profile)form.append('source_account_profile_id',profile);
  return req('uploadImport','/imports',{method:'POST',body:form,status:201,headers});
}
async function fullBatch(id){
  const rows=[];let cursor;let first;
  do{const q=new URLSearchParams({limit:'100'});if(cursor)q.set('rows_cursor',cursor);
    const r=await req('getImport','/imports/'+id+'?'+q);first??=r.data;rows.push(...r.data.rows);cursor=r.page.rows_next_cursor;
  }while(cursor);return {...first,rows};
}
async function transactionCount(){return (await pg.query('SELECT count(*)::integer AS n FROM public.sl_transactions')).rows[0].n;}
function independentCents(value){
  const text=String(value).trim().replace(/^[¥￥]/,'');assert.match(text,/^\d+(?:\.\d{1,2})?$/);
  const [whole,part='']=text.split('.');return Number(BigInt(whole)*100n+BigInt(part.padEnd(2,'0')));
}
try{
  for(const platform of ['wechat','alipay']){
    stage=platform+' file parsing';const buffer=await readFile(inputs[platform]);buffers.set(platform,buffer);
    const parsed=await parseOfficialFile(buffer,platform+'.xlsx');assert.equal(parsed.platform,platform);assert.equal(parsed.rows.length,169);
    const workbook=new ExcelJS.Workbook();await workbook.xlsx.load(buffer);const sheet=workbook.worksheets[0];
    const headerRow=parsed.rows[0].row_number-1,headers=[];sheet.getRow(headerRow).eachCell({includeEmpty:true},cell=>headers.push(cell.value));
    assert.deepEqual(parsed.source_metadata.raw_column_headers,headers);assert.equal(headers.length,platform==='wechat'?11:12);
    const rawByNumber=new Map();
    for(const row of parsed.rows){
      const raw=Object.fromEntries(headers.map((name,i)=>{
        const value=sheet.getRow(row.row_number).getCell(i+1).value;
        // Excel date cells have no timezone. Compare their literal calendar
        // fields in the existing persisted string representation, not Date objects.
        return [name,value instanceof Date?value.toISOString().slice(0,19).replace('T',' '):value??''];
      }));rawByNumber.set(row.row_number,raw);
      assert.deepEqual(row.evidence.raw_fields,raw,'Original field preservation failed');
      assert.equal(row.candidate.amount_minor,independentCents(raw[platform==='wechat'?'金额(元)':'金额']),'Cents differ from original literal');
      const identifier=raw[platform==='wechat'?'交易单号':'交易订单号'];assert.equal(typeof identifier,'string');
      assert.equal(row.official_transaction_id,identifier.trim().replace(/(?:\s|\\t)+$/g,''),'Full source identifier changed');
    }
    const initialKey=requestKey();let batch=(await upload(platform,undefined,initialKey)).data;
    assert.equal(batch.summary.read_rows,169);assert.equal(batch.source_account_profile,null);
    const before=await transactionCount();assert.equal((await upload(platform,undefined,initialKey)).data.batch_id,batch.batch_id);assert.equal(await transactionCount(),before);
    batch=(await req('resolveImport','/imports/'+batch.batch_id+'/resolutions',{method:'POST',headers:requestKey(),body:{action:'select_source_profile',profile_version:0,create_label:'Local original '+platform}})).data;
    const profile=batch.source_account_profile.id;
    // Fictional accounts only. Platform names/card hints are not assertions of
    // the user's real account ownership, balances or cross-platform identity.
    const methods=new Set(parsed.rows.filter(r=>!r.base_disposition&&!r.base_reason).flatMap(r=>r.evidence.canonical_method_keys));
    for(const method of methods){
      const mapKey=platform+':'+method;let account=accountIds.get(mapKey);
      if(!account){
        account=(await req('createAccount','/accounts',{method:'POST',status:201,headers:requestKey(),body:{name:'Local original fixture '+(accountIds.size+1),
          account_type:method==='微信零钱'?'wechat_balance':method==='支付宝余额'?'alipay_balance':'bank_card',custodian:'self',opening_state:{
            opening_date:'2026-08-01',opening_balance_minor:1000000000000,opening_allocations:[{fund_owner:'self',fund_type:'liquid',amount_minor:1000000000000}]}}})).data;
        accountIds.set(mapKey,account);
      }
      await req('putMapping','/source-payment-method-mappings',{method:'PUT',body:{source_account_profile_id:profile,canonical_method_key:method,account_id:account.id,expected_version:0}});
    }
    batch=(await req('resolveImport','/imports/'+batch.batch_id+'/resolutions',{method:'POST',headers:requestKey(),body:{action:'resume'}})).data;
    const full=await fullBatch(batch.batch_id);assert.equal(full.rows.length,169);assert.equal(full.summary.failed,0);
    assert.equal(full.summary.unsupported,platform==='wechat'?2:123);assert.equal(full.coverage.reconciliation_eligible,false);
    const states=['created','linked_existing','duplicate_existing','unsupported','ineffective','needs_review','failed'];
    assert.equal(states.reduce((sum,key)=>sum+full.summary[key],0),169);
    for(const row of full.rows){
      assert.deepEqual(row.evidence.raw_fields,rawByNumber.get(row.row_number),'Persisted original fields differ');
      if(['unsupported','needs_review','ineffective','failed'].includes(row.disposition))assert.equal(row.transaction_id,null,'Unresolved row was posted');
    }
    for(const row of full.rows.filter(r=>r.disposition==='unsupported')){
      assert.ok(platform==='wechat'?row.reason_codes.includes('TRANSFER_FEE_UNSUPPORTED'):row.reason_codes.includes('UNSUPPORTED_PAYMENT_METHOD'));
    }
    const postedBefore=await transactionCount();const repeat=(await upload(platform,profile)).data;
    assert.equal(repeat.summary.created,0,'Reimport created another transaction');assert.equal(await transactionCount(),postedBefore);
    assert.equal(repeat.summary.duplicate_existing,full.summary.created+full.summary.linked_existing);
    const expense=full.rows.find(r=>r.disposition==='created'&&r.candidate.type==='expense');assert.ok(expense);
    const old=(await req('getTransaction','/transactions/'+expense.transaction_id)).data;
    await req('patchTransaction','/transactions/'+old.id,{method:'PATCH',headers:{'If-Match':'"'+old.version+'"'},body:{note:'Local edited note must survive reimport'}});
    await upload(platform,profile);
    const preserved=(await req('getTransaction','/transactions/'+old.id)).data;assert.equal(preserved.note,'Local edited note must survive reimport');assert.deepEqual(preserved.source_summaries,old.source_summaries);
    if(platform==='wechat'){
      const small=full.rows.filter(r=>r.disposition==='created'&&r.candidate.type==='refund'&&[26,44].includes(r.candidate.amount_minor));
      assert.equal(small.length,2);assert.equal(small.reduce((sum,r)=>sum+r.candidate.amount_minor,0),70);
      const refund=(await req('getTransaction','/transactions/'+small[0].transaction_id)).data;
      await req('deleteTransaction','/transactions/'+refund.id,{method:'DELETE',headers:{'If-Match':'"'+refund.version+'"'}});
      const restored=(await upload(platform,profile)).data;assert.equal(restored.summary.created,1);
      assert.equal(await transactionCount(),postedBefore);
      const recovered=(await fullBatch(restored.batch_id)).rows.find(r=>r.source_record_id===small[0].source_record_id);
      assert.ok(recovered?.transaction_id&&recovered.transaction_id!==refund.id,'Deleted source did not restore to a new transaction');
    }
    const summary={platform,bytes:buffer.length,rows:169,columns:headers.length,summary:full.summary,
      raw_fields_preserved:true,integer_cents_verified:true,reimport_no_duplicates:true,user_edit_preserved:true,
      unresolved_rows_left_untouched:true,refund_delete_reimport:platform==='wechat'};
    reports.push(summary);console.log(JSON.stringify(summary));
    assert.equal(hash(await readFile(inputs[platform])),hash(buffer),'Original file changed');
  }
  stage='balance reconciliation';const expected=new Map([...accountIds.values()].map(a=>[a.id,1000000000000]));
  const transactions=(await pg.query('SELECT public.sl_transaction_json(id) AS value FROM public.sl_transactions ORDER BY id')).rows.map(r=>r.value);
  for(const tx of transactions){
    if(tx.type==='transfer'){expected.set(tx.from_account_id,expected.get(tx.from_account_id)-tx.amount_minor);expected.set(tx.to_account_id,expected.get(tx.to_account_id)+tx.amount_minor);}
    else expected.set(tx.account_id,expected.get(tx.account_id)+(tx.type==='expense'?-1:1)*tx.amount_minor);
  }
  for(const [id,balance] of expected){const actual=(await req('getAccount','/accounts/'+id)).data;assert.equal(actual.balance_minor,balance,'Persisted balance differs from independent transaction sum');}
  const result={cloud_network_requests:0,platform_auth:'explicit local substitute',originals_read_only:true,
    reports,transactions:transactions.length,balances_reconciled:true,http_captures:captures.length,blocked_external_calls:counters.blocked_external_calls};
  await writeFile(resolve(privateDir,'verification.json'),JSON.stringify(result,null,2));console.log(JSON.stringify({completed:true,cloud_network_requests:0,transactions:transactions.length,http_captures:captures.length}));
}catch(error){
  await writeFile(resolve(privateDir,'failure.json'),JSON.stringify({stage,message:error.message,stack:error.stack},null,2));
  console.error('Original-file check failed at '+stage+'. Details remain in the private ignored output directory.');process.exitCode=1;
}finally{await close();}
