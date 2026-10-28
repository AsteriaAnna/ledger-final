import assert from 'node:assert/strict';
import {test} from 'node:test';
import {parseOfficialFile,sourceCents} from '../src/modules/imports/parser.js';
import {contractInput} from '../src/domain/contracts.js';
import {officialWorkbook,wxRow} from './fixtures/official.js';
import ExcelJS from 'exceljs';
test('official parser preserves exact cents, complete IDs and raw evidence; header position is discovered',async()=>{
  const file=await officialWorkbook('wechat',[wxRow('id-refund-1\\t','商户退款','收入','0.44'),wxRow('id-refund-2','商户退款','收入','0.26')],{extraHeaderRows:9});
  const p=await parseOfficialFile(file,'官方.xlsx');
  assert.equal(p.rows.length,2);assert.equal(p.rows[0].official_transaction_id,'id-refund-1');
  assert.equal(p.rows[0].evidence.raw_fields['交易单号'],'id-refund-1\\t');
  assert.equal(p.rows[0].candidate.amount_minor+p.rows[1].candidate.amount_minor,70);
  assert.equal(p.rows[0].candidate.refund_kind,'merchant_refund');assert.equal(p.coverage.structural_complete,true);
  assert.equal(sourceCents('40.79'),4079);assert.equal(sourceCents('1.001'),null);
});
test('incomplete coverage and unsupported or uncertain semantics never masquerade as posted rows',async()=>{
  const p=await parseOfficialFile(await officialWorkbook('wechat',[wxRow('1','转账','收入'),wxRow('2','零钱提现','支出','10','银行','提现已到账','服务费¥1.00'),
    wxRow('3','商户消费','支出','1','亲情卡'),wxRow('4','商户消费','支出','1','零钱','未知状态')],{declared:5}),'账单.xlsx');
  assert.equal(p.coverage.structural_complete,false);assert.equal(p.rows[0].base_reason,'TRANSFER_ROLE_REQUIRED');
  assert.equal(p.rows[1].base_disposition,'unsupported');assert.equal(p.rows[2].base_disposition,'unsupported');assert.equal(p.rows[3].base_reason,'UNKNOWN_SOURCE_STATE');
});
test('alipay discounts do not change actual amount and waiting receipt remains expense',async()=>{
  const p=await parseOfficialFile(await officialWorkbook('alipay',[[ '2026-10-10 12:00:00','日用百货','合成商户','','合成商品','支出','40.79','农业银行储蓄卡(2372)&闪购支付红包','等待确认收货','long-refund-suffix-xyz','','']]),'账单.xlsx');
  assert.equal(p.rows[0].candidate.amount_minor,4079);assert.equal(p.rows[0].candidate.type,'expense');assert.equal(p.rows[0].candidate.canonical_method_key,'农业银行储蓄卡(2372)');
  assert.deepEqual(p.rows[0].evidence.discount_tags,['闪购支付红包']);
});
test('upload limits and closed decision structures reject invalid inputs before persistence',async()=>{
  await assert.rejects(()=>parseOfficialFile(Buffer.from('not a workbook'),'账单.xlsx'));
  await assert.rejects(()=>parseOfficialFile(Buffer.alloc(10*1024*1024+1),'账单.xlsx'));
  assert.throws(()=>contractInput('Resolution',{action:'resume',user_id:'forged'}));
  assert.throws(()=>contractInput('Resolution',{action:'select_source_profile',profile_version:0,profile_id:'a',create_label:'b'}));
  assert.throws(()=>contractInput('MappingPut',{source_account_profile_id:'p',canonical_method_key:'k',account_id:'a',expected_version:-1}));
});
test('numeric official identifiers are not silently converted into source identity',async()=>{
  const workbook=new ExcelJS.Workbook();await workbook.xlsx.load(await officialWorkbook('wechat',[wxRow('full-text-id')] ) as any);
  workbook.worksheets[0].getCell('I7').value=123456789012345678;
  const result=await parseOfficialFile(Buffer.from(await workbook.xlsx.writeBuffer()),'账单.xlsx');
  assert.equal(result.rows[0].base_disposition,'failed');
  assert.equal(typeof result.rows[0].evidence.raw_fields['交易单号'],'number');
});
