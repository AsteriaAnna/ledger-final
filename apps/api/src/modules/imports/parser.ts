import ExcelJS from 'exceljs';
import yauzl from 'yauzl';
import { createHash } from 'node:crypto';
import { DomainError } from '../../domain/ledger.js';

export type Json = Record<string, any>;
const fail = (message: string, status = 422): never => { throw new DomainError(status,
  status === 413 ? 'PAYLOAD_TOO_LARGE' : 'VALIDATION_ERROR', message); };
const categories: Record<string, string> = { 餐饮美食:'food', 日用百货:'shopping', 服饰装扮:'shopping',
  家居家装:'shopping', 数码电器:'shopping', 交通出行:'transport', 教育培训:'education', 医疗健康:'health',
  文化休闲:'entertainment', 运动户外:'entertainment', 充值缴费:'utilities' };
export function sourceCents(value: string): number | null {
  const s=value.trim().replace(/^[¥￥]/,'');
  if (!/^\d+(?:\.\d{1,2})?$/.test(s)) return null;
  const [a,b='']=s.split('.'); const n=BigInt(a)*100n+BigInt(b.padEnd(2,'0'));
  return n>0n && n<=BigInt(Number.MAX_SAFE_INTEGER) ? Number(n) : null;
}
function sourceTime(s: string): string | null {
  const t=s.trim().replace(' ','T');
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/.test(t)) return null;
  const d=new Date(t+'+08:00');
  return Number.isNaN(d.valueOf()) || new Date(d.valueOf()+8*3600000).toISOString().slice(0,19)!==t ? null : t+'+08:00';
}
function text(value: ExcelJS.CellValue): string {
  if (value===null || value===undefined) return '';
  if (value instanceof Date) return value.toISOString().slice(0,19).replace('T',' ');
  if (typeof value==='object') {
    if ('richText' in value) return value.richText.map(x=>x.text).join('');
    if ('text' in value) return String(value.text);
    // Formulae are never evaluated; source money/IDs must be literal values.
    return '[不支持的单元格]';
  }
  return String(value);
}
// Bound actual decompressed bytes before the workbook parser allocates cells.
async function inspectArchive(buffer: Buffer): Promise<void> {
  return new Promise((resolve,reject)=>yauzl.fromBuffer(buffer,{lazyEntries:true,validateEntrySizes:true,strictFileNames:true},(error,zip)=>{
    if(error || !zip) { reject(new DomainError(422,'VALIDATION_ERROR','无法读取XLSX文件。')); return; }
    let bytes=0,entries=0,closed=false;
    const stop=(error: Error)=>{if(!closed){closed=true;zip.close();reject(error);}};
    zip.on('error',()=>stop(new DomainError(422,'VALIDATION_ERROR','XLSX压缩结构不完整。')));
    zip.on('end',()=>{if(!closed){closed=true;resolve();}});
    zip.on('entry',entry=>{
      if(++entries>4096 || entry.uncompressedSize>64*1024*1024 || (entry.generalPurposeBitFlag&1)!==0){
        stop(new DomainError(413,'PAYLOAD_TOO_LARGE','文件展开后过大或已加密，请缩小导出范围。')); return; }
      zip.openReadStream(entry,(error,stream)=>{
        if(error || !stream){stop(new DomainError(422,'VALIDATION_ERROR','无法读取XLSX内容。'));return;}
        stream.on('data',(chunk:Buffer)=>{bytes+=chunk.length;if(bytes>64*1024*1024){stream.destroy();stop(new DomainError(413,'PAYLOAD_TOO_LARGE','文件展开后超过限制。'));}});
        stream.on('error',()=>stop(new DomainError(422,'VALIDATION_ERROR','XLSX内容不完整。')));
        stream.on('end',()=>{if(!closed)zip.readEntry();});
      });
    }); zip.readEntry();
  }));
}

export async function parseOfficialFile(buffer: Buffer, filename: string): Promise<Json> {
  if(buffer.length>10*1024*1024) fail('文件不能超过10MiB。',413);
  if(!/\.xlsx$/i.test(filename) || buffer.subarray(0,2).toString()!=='PK') fail('请选择微信或支付宝官方XLSX账单。');
  await inspectArchive(buffer);
  const book=new ExcelJS.Workbook();
  try { await book.xlsx.load(buffer as any); } catch { fail('无法读取XLSX，请使用未加密的官方账单。'); }
  const sheets=book.worksheets.filter(s=>s.actualRowCount>0);
  if(sheets.length!==1) fail('文件应包含一个官方账单工作表。');
  const sheet=sheets[0];
  if(sheet.rowCount>10150 || sheet.columnCount>80) fail('明细超过10000行或表格过大。',413);
  const matrix:string[][]=[];
  sheet.eachRow({includeEmpty:true},row=>{const cells:string[]=[]; row.eachCell({includeEmpty:true},cell=>cells.push(text(cell.value)));matrix.push(cells);});
  const h=matrix.findIndex(r=>r.includes('交易时间') && (r.includes('交易类型') || r.includes('交易分类')));
  if(h<0 || h>150) fail('未找到官方账单明细表头。');
  const header=matrix[h].map(s=>s.trim()); const metadata=matrix.slice(0,h).map(r=>r.join(' ')).join('\n');
  const wx=header.includes('交易类型'); const platform=wx?'wechat':'alipay';
  if(!(wx?/微信支付/.test(metadata):/支付宝/.test(metadata))) fail('文件标题与明细格式不一致。');
  const required=wx?['交易时间','交易类型','交易对方','商品','收/支','金额(元)','支付方式','当前状态','交易单号','商户单号','备注']:
    ['交易时间','交易分类','交易对方','对方账号','商品说明','收/支','金额','收/付款方式','交易状态','交易订单号','商家订单号','备注'];
  if(required.some(k=>header.filter(x=>x===k).length!==1)) fail('官方文件缺少必要列或存在重复表头。');
  const findTime=(name:string)=>sourceTime(metadata.match(new RegExp(name+'[：:]\\s*\\[([^\\]]+)\\]'))?.[1]??'');
  const start=findTime('起始时间'),end=findTime('终止时间'),exported=findTime('导出时间');
  const count=metadata.match(/共\s*(\d+)\s*笔记录/); const declared=count?Number(count[1]):null;
  const exportType=/全部账单|\[全部\]/.test(metadata)?'all_transactions':/收入|支出/.test(metadata)?'partial':'unknown';
  const rows:Json[]=[];
  for(let i=h+1;i<matrix.length;i++) {
    if(matrix[i].every(s=>!s.trim()))continue;
    if(rows.length>=10000)fail('每次最多导入10000行明细。',413);
    const raw=Object.fromEntries(header.map((key,j)=>{const value=sheet.getRow(i+1).getCell(j+1).value;
      return [key,value===null||value===undefined?'':value instanceof Date?text(value):value];}));
    const r=Object.fromEntries(header.map((key,j)=>[key,(matrix[i][j]??'').trim()]));
    const kind=r[wx?'交易类型':'交易分类'],status=r[wx?'当前状态':'交易状态'],method=r[wx?'支付方式':'收/付款方式'];
    const desc=r[wx?'商品':'商品说明']; const id=r[wx?'交易单号':'交易订单号'].replace(/(?:\s|\\t)+$/g,'');
    const n=sourceCents(r[wx?'金额(元)':'金额']),time=sourceTime(r['交易时间']);
    const tokens=method.split('&').map(s=>s.trim());const discounts=tokens.filter(s=>s.includes('红包'));
    let key=tokens.filter(s=>!s.includes('红包')).join('&'); if(key==='零钱')key='微信零钱';if(key==='余额')key='支付宝余额';
    let reason:string|null=null,disposition:string|null=null;
    if(status==='已存入零钱') { if(!['','/','微信零钱'].includes(key))reason='ACCOUNT_EVIDENCE_CONFLICT';key='微信零钱'; }
    const keys=key && key!=='/'?[key]:[];
    const candidate:Json={type:null,accounting_semantics:null,amount_minor:n,source_occurred_at:time,occurred_at:time,
      category_code:categories[kind]??'other',merchant:r['交易对方'],note:[desc,r['备注']].filter(Boolean).join('；'),
      account_hint:keys[0]??null,from_account_hint:null,to_account_hint:null,account_id:null,from_account_id:null,to_account_id:null,
      refund_kind:null,affects_spending:null,canonical_method_key:keys[0]??null,from_canonical_method_key:null,to_canonical_method_key:null};
    if(typeof raw[wx?'交易单号':'交易订单号']!=='string' || !id || !n || !time || (exported && time>exported) || Date.parse(time)>Date.now()) {disposition='failed';reason='INVALID_SOURCE_FIELDS';}
    else if(/亲情卡|花呗|信用卡/.test(method+' '+desc+' '+r['交易对方'])){disposition='unsupported';reason='UNSUPPORTED_PAYMENT_METHOD';}
    else if(/失败|关闭/.test(status)){disposition='ineffective';reason='INEFFECTIVE_SOURCE_STATE';}
    else {
      const known=wx?(/^(支付成功|已存入零钱|对方已收钱|已全额退款|对方已退还|充值完成|提现已到账|已收钱|已转账)$/.test(status)||/^已退款\(?[¥￥]?[\d.]+\)?$/.test(status)):
        ['交易成功','等待确认收货','退款成功'].includes(status);
      if(!known)reason='UNKNOWN_SOURCE_STATE';
      else if(wx?kind.includes('退款'):status==='退款成功') {candidate.type='refund';candidate.refund_kind=kind==='转账-退款'?'transfer_return':'merchant_refund';candidate.affects_spending=candidate.refund_kind==='merchant_refund';}
      else if(wx && ['零钱充值','零钱提现'].includes(kind)) {
        const fee=r['备注'].match(/服务费[¥￥]?\s*([\d.]+)/); const zeroFee=fee && /^0(?:\.0{1,2})?$/.test(fee[1]);
        if((fee && !zeroFee) || (kind==='零钱提现'&&!zeroFee)){disposition='unsupported';reason='TRANSFER_FEE_UNSUPPORTED';}
        else {candidate.type='transfer';candidate.canonical_method_key=null;candidate.account_hint=null;
          const pair=kind==='零钱充值'?[key,'微信零钱']:['微信零钱',key];
          [candidate.from_canonical_method_key,candidate.to_canonical_method_key]=pair.map(x=>x && x!=='/'?x:null);
          [candidate.from_account_hint,candidate.to_account_hint]=[candidate.from_canonical_method_key,candidate.to_canonical_method_key];
          keys.splice(0,keys.length,...pair.filter(x=>x&&x!=='/'));}
      } else if(wx && kind==='转账')reason='TRANSFER_ROLE_REQUIRED';
      else {candidate.type=({'收入':'income','支出':'expense'} as Json)[r['收/支']]??null;if(!candidate.type)reason='INVALID_SOURCE_FIELDS';}
    }
    candidate.accounting_semantics=candidate.type==='transfer'?'internal_transfer':candidate.type==='refund'?'refund_inflow':candidate.type?'ordinary':null;
    const evidence={source_kind:kind,source_status:status,source_direction:r['收/支'],account_evidence:method,
      discount_tags:discounts,merchant_order_id:r[wx?'商户单号':'商家订单号']||null,raw_fields:raw,canonical_method_keys:[...new Set(keys)]};
    rows.push({row_number:i+1,official_transaction_id:id,candidate,evidence,
      base_disposition:disposition??(reason?'needs_review':null),base_reason:reason,
      fact_hash:createHash('sha256').update(JSON.stringify([n,time,kind,r['收/支'],key,disposition==='ineffective',candidate.type])).digest('hex')});
  }
  const ids=rows.map(r=>r.official_transaction_id); const complete=!!(start&&end&&exported&&declared===rows.length&&new Set(ids).size===rows.length&&
    ids.every(Boolean)&&exportType==='all_transactions'&&start<=end&&start<=exported&&rows.every(r=>r.candidate.source_occurred_at && r.candidate.source_occurred_at>=start && r.candidate.source_occurred_at<=((end!<exported!)?end!:exported!)));
  return {platform,file_hash:createHash('sha256').update(buffer).digest('hex'),source_metadata:{raw_header:metadata,raw_column_headers:matrix[h]},
    identity_hint:!wx?(metadata.match(/支付宝(?:账号|账户)[：:]\s*\[?([^\]\n]+)/)?.[1]?.trim()??null):null,
    coverage:{structural_complete:complete,declared_from:start,declared_to:end,exported_at:exported,export_type:exportType,
      effective_from:start,effective_to:end&&exported?(end<exported?end:exported):null,declared_record_count:declared,
      parsed_record_count:rows.length,reconciliation_eligible:false,blockers:complete?[]:['INCOMPLETE_COVERAGE']},rows};
}
