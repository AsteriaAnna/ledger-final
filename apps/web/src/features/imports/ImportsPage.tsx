import { useEffect, useState } from 'react';
import { request, type Account, type Session, type Transaction, type ManualType } from '../../api/client';
import { money } from '../../lib/format';
import { TransactionAccounts, transactionAccounts } from '../transactions/TransactionAccounts';
import { getImport, mappings, putMapping, resolveImport, review, uploadFile,
  type ImportBatch, type ImportResponse, type ImportRow, type Mapping } from './api';

const outcomes:Record<string,string>={created:'已入账',linked_existing:'已关联已有账单',duplicate_existing:'已有来源，未重复入账',
  unsupported:'本期不支持',ineffective:'无资金影响',needs_review:'待处理',failed:'本行未入账'};
const reasons:Record<string,string>={SOURCE_PROFILE_REQUIRED:'请确认来源账号档案',ACCOUNT_MAPPING_REQUIRED:'请选择渠道对应的实际账户',
  TRANSFER_ROLE_REQUIRED:'请确认这是收入、支出还是本人账户间转账',SAME_EVENT_CONFIRMATION_REQUIRED:'发现同日同额候选，请确认是否为同一事件',
  SOURCE_CHANGED:'官方重要事实发生变化，请核对。已保存账单不会自动改写',SAME_EXPORT_CONFLICT:'同一导出时间出现不同事实，请确认采用这份观察',
  UNKNOWN_SOURCE_STATE:'尚不能解释这个官方状态',ACCOUNT_EVIDENCE_CONFLICT:'账户线索互相冲突，请检查原始字段',
  INVALID_SOURCE_FIELDS:'单号、金额、方向或时间不完整',UNSUPPORTED_PAYMENT_METHOD:'本期不支持亲情卡、花呗和信用消费',
  TRANSFER_FEE_UNSUPPORTED:'本期不支持带手续费或费用不明的转账',INEFFECTIVE_SOURCE_STATE:'交易失败或关闭，不改变资金',
  FUNDS_ALLOCATION_NOT_POSSIBLE:'可用资金不足，本行没有入账。补充或调整账户后可继续',POSTING_FAILED:'本行保存失败，可稍后继续',
  INCOMPLETE_COVERAGE:'导出范围或声明行数不完整，本批不做缺失核对'};

export function ImportsPage({session,accounts,transactions,onSaved,onMessage}:{session:Session;accounts:Account[];transactions:Transaction[];
  onSaved:()=>Promise<void>;onMessage:(s:string)=>void}) {
  const storage=`sl-last-import:${session.user?.id??'unknown'}`;
  const [batch,setBatch]=useState<ImportBatch|null>(null),[page,setPage]=useState<ImportResponse['page']|null>(null);
  const [file,setFile]=useState<File|null>(null),[busy,setBusy]=useState(false),[label,setLabel]=useState(''),[profile,setProfile]=useState('');
  const [savedMappings,setMappings]=useState<Mapping[]>([]),[mapChoices,setMapChoices]=useState<Record<string,string>>({});
  const accept=(r:ImportResponse)=>{setBatch(r.data);setPage(r.page);localStorage.setItem(storage,r.data.batch_id);};
  async function reload(id:string){accept(await getImport(session,id));}
  async function act(work:()=>Promise<unknown>){setBusy(true);onMessage('');try{await work();try{await onSaved();}catch{onMessage('操作已保存，刷新账本失败。请点击刷新。');}}catch(e){onMessage(e instanceof Error?e.message:'操作失败。');}finally{setBusy(false);}}
  useEffect(()=>{const id=localStorage.getItem(storage);if(id)getImport(session,id).then(accept).catch(e=>onMessage(e.message));},[session]);
  useEffect(()=>{if(batch?.source_account_profile)mappings(session,batch.source_account_profile.id).then(setMappings).catch(e=>onMessage(e.message));else setMappings([]);},[session,batch?.source_account_profile?.id,batch?.summary.needs_review]);
  async function resolve(input:Record<string,unknown>){if(!batch)return;await resolveImport(session,batch.batch_id,input);await reload(batch.batch_id);}
  const keys=[...new Set((batch?.rows??[]).filter(r=>r.reason_codes.includes('ACCOUNT_MAPPING_REQUIRED')||r.reason_codes.includes('TRANSFER_ROLE_REQUIRED'))
    .flatMap(r=>r.evidence.canonical_method_keys))];
  const describe=(id:string)=>{const t=transactions.find(t=>t.id===id);return t?`${t.occurred_at.slice(0,10)} · ${t.merchant||'账单'} · ${money(t.amount_minor)}`:'查看候选详情后确认';};
  return <>
    <div className="section-head"><div><p className="eyebrow">官方来源</p><h1>导入账单</h1></div></div>
    <section className="card form-card"><h2>微信 / 支付宝官方文件</h2>
      <p>请选择官方XLSX账单，每次不超过10MiB、10000行。先确认来源账号，再映射钱实际所在的账户。</p>
      <form onSubmit={e=>{e.preventDefault();if(file)void act(async()=>{accept(await uploadFile(session,file,profile||undefined));onMessage('文件已处理，请查看每行结果。');});}}>
        <label>官方XLSX文件<input type="file" accept=".xlsx" required onChange={e=>setFile(e.target.files?.[0]??null)}/></label>
        {!!batch?.profile_candidates.length&&<label>这份文件的来源账号<select value={profile} onChange={e=>setProfile(e.target.value)}>
          <option value="">导入后确认</option>{batch.profile_candidates.map(p=><option key={p.id} value={p.id}>{p.platform==='wechat'?'微信':'支付宝'} · {p.label}</option>)}</select></label>}
        <button disabled={busy||!file}>{busy?'正在处理…':'读取并处理文件'}</button>
      </form>
    </section>
    {batch&&<>
      <section className="card"><div className="section-head"><h2>本次导入</h2><button className="secondary" disabled={busy} onClick={()=>void act(()=>reload(batch.batch_id))}>刷新导入结果</button></div>
        <p>{batch.platform==='wechat'?'微信':'支付宝'} · {batch.source_account_profile?.label??'来源账号待确认'} · 实读 {batch.summary.read_rows} 行</p>
        <p>{Object.entries(outcomes).map(([key,name])=>`${name} ${batch.summary[key]??0}`).join('；')}</p>
        <p className="muted">{batch.coverage.reconciliation_eligible?'范围核对条件已满足。':'本批暂不进行手动账单缺失核对：'+batch.coverage.blockers.map(r=>reasons[r]??r).join('；')}</p>
        <details><summary>文件头与覆盖范围</summary>
          <p>声明范围：{String(batch.coverage.declared_from??'未识别')} 至 {String(batch.coverage.declared_to??'未识别')}</p>
          <p>导出时间：{String(batch.coverage.exported_at??'未识别')}；实际核对终点：{String(batch.coverage.effective_to??'未确定')}</p>
          <p>声明 {String(batch.coverage.declared_record_count??'未知')} 行，实读 {String(batch.coverage.parsed_record_count)} 行；{batch.coverage.structural_complete?'结构与范围完整':'结构或范围待核对'}</p>
          <pre>{String(batch.source_metadata.raw_header??'')}</pre>
        </details>
      </section>
      {!batch.source_account_profile&&<section className="card form-card"><h2>确认来源账号</h2><p>档案代表导出文件的微信或支付宝账号，昵称不会作为唯一身份。</p>
        {!!batch.profile_candidates.length&&<><label>已有档案<select value={profile} onChange={e=>setProfile(e.target.value)}><option value="">请选择</option>
          {batch.profile_candidates.map(p=><option key={p.id} value={p.id}>{p.label}</option>)}</select></label>
          <button disabled={busy||!profile} onClick={()=>void act(()=>resolve({action:'select_source_profile',profile_version:batch.profile_version,profile_id:profile}))}>使用这个来源档案</button></>}
        <label>新档案名称<input value={label} maxLength={80} onChange={e=>setLabel(e.target.value)}/></label>
        <button disabled={busy||!label.trim()} onClick={()=>void act(()=>resolve({action:'select_source_profile',profile_version:batch.profile_version,create_label:label.trim()}))}>创建并使用档案</button>
      </section>}
      {!!keys.length&&batch.source_account_profile&&<section className="card form-card"><h2>渠道对应哪个实际账户</h2>
        <p>银行卡可经确认跨平台复用；不同来源账号的零钱或余额不能串用。保存后自动继续处理就绪行。</p>
        {keys.map(key=>{const previous=savedMappings.find(m=>m.canonical_method_key===key);return <form key={key} onSubmit={e=>{e.preventDefault();void act(async()=>{
          await putMapping(session,{source_account_profile_id:batch.source_account_profile!.id,canonical_method_key:key,
            account_id:mapChoices[key]??previous?.account_id,expected_version:previous?.version??0});
          await resolve({action:'resume'});setMappings(await mappings(session,batch.source_account_profile!.id));
        });}}><label>{key}<select required value={mapChoices[key]??previous?.account_id??''} onChange={e=>setMapChoices({...mapChoices,[key]:e.target.value})}>
          <option value="">请选择本人实际账户</option>{accounts.map(a=><option key={a.id} value={a.id}>{a.name}</option>)}</select></label>
          <button disabled={busy||!(mapChoices[key]??previous?.account_id)}>保存映射并继续</button></form>;})}
      </section>}
      <section className="card"><div className="section-head"><h2>逐行结果</h2><button className="secondary" disabled={busy||!batch.source_account_profile} onClick={()=>void act(()=>resolve({action:'resume'}))}>继续处理就绪行</button></div>
        {batch.rows.map(row=><ImportRowCard key={row.observation_id} row={row} accounts={accounts} session={session} busy={busy}
          describe={describe} perform={input=>act(()=>resolve(input))}/>)}
        {page?.rows_next_cursor&&<button className="secondary" disabled={busy} onClick={()=>void act(async()=>{
          const next=await getImport(session,batch.batch_id,`?rows_cursor=${page.rows_next_cursor}`);
          setBatch({...next.data,rows:[...batch.rows,...next.data.rows],reconciliation_items:batch.reconciliation_items});setPage({...page,rows_next_cursor:next.page.rows_next_cursor});
        })}>显示后续行</button>}
      </section>
      {!!batch.reconciliation_items.length&&<section className="card"><h2>未找到对应来源的手动账单</h2><p>这不是自动删除。请保留已核对的账单，或确认删除并撤回其资金影响。</p>
        {batch.reconciliation_items.map(item=><div className="card" key={item.id}><p>{describe(item.transaction_id)} · {item.status==='pending_confirmation'?'待确认':item.status==='kept_manual'?'已保留':'已匹配来源'}</p>
          {item.status!=='matched_to_source'&&<div className="view-switch"><button disabled={busy} onClick={()=>void act(async()=>{await review(session,batch.batch_id,{reconciliation_item_id:item.id,expected_version:item.version,action:'keep_manual'});await reload(batch.batch_id);})}>保留手动账单</button>
          <button className="secondary" disabled={busy} onClick={()=>{if(window.confirm('删除这笔未匹配来源的手动账单，并撤回它的资金影响？'))void act(async()=>{await review(session,batch.batch_id,{reconciliation_item_id:item.id,expected_version:item.version,action:'delete_manual_transaction'});await reload(batch.batch_id);});}}>删除手动账单</button></div>}</div>)}
        {page?.reconciliation_next_cursor&&<button disabled={busy} onClick={()=>void act(async()=>{
          const next=await getImport(session,batch.batch_id,`?reconciliation_cursor=${page.reconciliation_next_cursor}`);
          setBatch({...batch,reconciliation_items:[...batch.reconciliation_items,...next.data.reconciliation_items]});setPage({...page,reconciliation_next_cursor:next.page.reconciliation_next_cursor});
        })}>显示后续核对项</button>}
      </section>}
    </>}
  </>;
}

function ImportRowCard({row,accounts,session,busy,perform,describe}:{row:ImportRow;accounts:Account[];session:Session;busy:boolean;
  perform:(input:Record<string,unknown>)=>Promise<void>;describe:(id:string)=>string}) {
  const [type,setType]=useState<ManualType>(row.evidence.source_direction==='收入'?'income':'expense');
  const [accountId,setAccount]=useState(''),[toId,setTo]=useState(''),[candidate,setCandidate]=useState(''),[detail,setDetail]=useState<Transaction|null>(null),[detailError,setDetailError]=useState('');
  const command=(action:string,extra={})=>perform({action,observation_id:row.observation_id,expected_source_version:row.source_version,...extra});
  return <article className="card"><strong>第{row.row_number}行 · {outcomes[row.disposition]}</strong>
    <p>{row.candidate.occurred_at?.slice(0,16).replace('T',' ')} · {row.candidate.merchant} · {row.candidate.amount_minor===null?'金额待核对':money(row.candidate.amount_minor)}</p>
    {row.reason_codes.map(reason=><p key={reason}>{reasons[reason]??reason}</p>)}
    <details><summary>查看官方原始字段</summary><pre>{JSON.stringify(row.evidence.raw_fields,null,2)}</pre></details>
    {row.allowed_actions.includes('set_transfer_role')&&<form onSubmit={e=>{e.preventDefault();void command('set_transfer_role',{type,...transactionAccounts(type,accountId,toId)});}}>
      <label>确认转账角色<select value={type} onChange={e=>setType(e.target.value as ManualType)}><option value="income">收入</option><option value="expense">支出</option><option value="transfer">本人内部转账</option></select></label>
      <TransactionAccounts type={type} accounts={accounts} accountId={accountId} toId={toId} onAccount={setAccount} onTo={setTo}/>
      <button disabled={busy||!accountId||(type==='transfer'&&(!toId||toId===accountId))}>确认角色并继续</button>
    </form>}
    {row.allowed_actions.includes('link_existing_transaction')&&<>
      <label>同事件候选<select value={candidate} onChange={e=>{setCandidate(e.target.value);setDetail(null);}}><option value="">请选择候选账单</option>
        {row.candidate_transaction_ids.map((id,i)=><option key={id} value={id}>候选{i+1} · {describe(id)}</option>)}</select></label>
      <button className="secondary" disabled={!candidate||busy} onClick={()=>{setDetailError('');void request<Transaction>(session,`/transactions/${candidate}`).then(setDetail).catch(e=>setDetailError(e.message));}}>查看候选账单</button>
      {detailError&&<p role="status">{detailError}</p>}
      {detail&&<p>{detail.occurred_at} · {detail.merchant} · {money(detail.amount_minor)} · {detail.note}</p>}
      <div className="view-switch"><button disabled={busy||!candidate||!detail} onClick={()=>void command('link_existing_transaction',{transaction_id:candidate})}>确认关联同一事件</button>
        <button className="secondary" disabled={busy} onClick={()=>void command('create_transaction')}>确认是另一笔，单独入账</button></div>
    </>}
    {row.allowed_actions.includes('accept_source_change')&&<button disabled={busy} onClick={()=>void command('accept_source_change')}>确认来源变化，保留现有账单</button>}
  </article>;
}
