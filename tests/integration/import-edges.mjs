import assert from 'node:assert/strict';
import {wxRow} from '../../apps/api/test-dist/test/fixtures/official.js';
export async function exerciseImportEdges({req,upload,resolve,current,createTx,a,profile,batch,income,key}) {
  const conflictId='same-export-'+crypto.randomUUID();
  const original=await upload([wxRow(conflictId,'其他','收入','7.01')],profile,{exported:'2026-10-28 00:00:00'});
  const conflict=await upload([wxRow(conflictId,'其他','收入','7.02')],profile,{exported:'2026-10-28 00:00:00'});
  const conflicting=conflict.rows[0];assert.ok(conflicting.reason_codes.includes('SAME_EXPORT_CONFLICT'));
  await resolve(conflict,{action:'accept_source_change',observation_id:conflicting.observation_id,expected_source_version:conflicting.source_version});
  assert.equal((await req('getTransaction','/transactions/'+original.rows[0].transaction_id)).amount_minor,701);
  const untouched=await req('getTransaction','/transactions/'+income.id);assert.equal(untouched.amount_minor,3050);
  const old=await current(batch),oldIncome=old.rows.find(r=>r.evidence.raw_fields['交易单号']==='income-id');
  await resolve(old,{action:'accept_source_change',observation_id:oldIncome.observation_id,expected_source_version:oldIncome.source_version},409);
  assert.deepEqual(await req('getTransaction','/transactions/'+income.id),untouched);
  const unsupportedBatch=await upload([wxRow('edge-unsupported-id','商户消费','支出','1','亲情卡')],profile,{exported:'2026-10-28 00:00:00'});
  const unsupported=unsupportedBatch.rows[0];
  await resolve(unsupportedBatch,{action:'create_transaction',observation_id:unsupported.observation_id,expected_source_version:unsupported.source_version},422);
  const troubleRows=[wxRow('failure-restored-id','商户消费','支出','8999999.99'),wxRow('partial-success-id','其他','收入','3.21')];
  let trouble=await upload(troubleRows,profile);
  assert.equal(trouble.summary.failed,1);assert.equal(trouble.summary.created,1);assert.equal(trouble.coverage.reconciliation_eligible,false);
  await createTx({type:'income',account_id:a.id,amount_minor:900000000,occurred_at:'2026-10-05T12:00:00+08:00',merchant:'合成恢复资金'});
  trouble=await resolve(trouble,{action:'resume'});assert.equal(trouble.summary.failed,0);assert.equal(trouble.summary.created,2);
  // A single weak candidate still needs a decision; forcing another event is explicit.
  let forced=await upload([wxRow('explicit-other-event-id','商户消费','支出','7.77','零钱','支付成功','','2026-10-15 12:00:00')],profile);
  assert.equal(forced.rows[0].disposition,'needs_review');assert.ok(forced.rows[0].candidate_transaction_ids.length>0);
  forced=await resolve(forced,{action:'create_transaction',observation_id:forced.rows[0].observation_id,expected_source_version:forced.rows[0].source_version});
  assert.equal(forced.rows[0].disposition,'created');assert.equal(forced.coverage.reconciliation_eligible,true);
  // A reconciliation delete that would overdraw is rejected without closing the item.
  const manual=await createTx({type:'income',account_id:a.id,source_account_profile_id:profile,amount_minor:5000,occurred_at:'2026-10-20T12:00:00+08:00',merchant:'合成核对收入'});
  const total=(await req('getAccount','/accounts/'+a.id)).balance_minor;
  await createTx({type:'expense',account_id:a.id,amount_minor:total-1000,occurred_at:'2026-10-21T12:00:00+08:00',merchant:'合成资金使用'});
  let full=await upload([wxRow('manual-link-id','商户消费','支出','7.77','零钱','支付成功','','2026-10-15 12:00:00')],profile);
  const item=full.reconciliation_items.find(i=>i.transaction_id===manual.transaction.id);assert.ok(item);
  const before=await req('getAccount','/accounts/'+a.id);
  await req('reviewReconciliation',`/imports/${full.batch_id}/reconciliation-reviews`,'POST',
    {reconciliation_item_id:item.id,expected_version:item.version,action:'delete_manual_transaction'},409,key());
  full=await current(full);assert.deepEqual(full.reconciliation_items.find(i=>i.id===item.id),item);
  assert.deepEqual(await req('getAccount','/accounts/'+a.id),before);
  console.log('Source conflicts, stale decisions, partial posting/retry, explicit new events and unsafe reconciliation passed');
}
