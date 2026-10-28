import { useEffect, useState } from 'react';
import { createWithKey, deleteTransaction, getAccounts, getTransactions, patchTransaction,
  type Account, type Session, type Transaction, type TransactionMutation, type FundNotice, type ManualType } from '../../api/client';
import { minor, minorInput, money, nowShanghai } from '../../lib/format';
import { TransactionAccounts, transactionAccounts } from './TransactionAccounts';
import { SourceProfileSelect } from '../imports/SourceProfileSelect';

const categories: [string, string][] = [['food', '餐饮'], ['shopping', '购物'], ['transport', '交通'], ['education', '教育'], ['health', '医疗'], ['entertainment', '娱乐'], ['utilities', '生活缴费'], ['other', '其他']];
const typeNames = { income: '收入', expense: '支出', transfer: '转账',refund:'退款' };
const noticeText = (notices: FundNotice[]) => notices.map(notice =>
  `已使用${notice.code === 'OWN_SAVINGS_USED' ? '本人' : '对象'}存款 ${money(notice.amount_minor)}。`).join('');

export function TransactionsPage({ session, accounts, transactions, bound, refreshSequence, onSaved, onMessage }: {
  session: Session; accounts: Account[]; transactions: Transaction[]; bound: boolean; refreshSequence: number;
  onSaved: () => Promise<void>; onMessage: (message: string) => void;
}) {
  const [view, setView] = useState<'mine' | 'partner'>('mine');
  const [partnerAccounts, setPartnerAccounts] = useState<Account[]>([]);
  const [partnerTransactions, setPartnerTransactions] = useState<Transaction[]>([]);
  const [busy, setBusy] = useState(false);
  const [accountId, setAccountId] = useState('');
  const [type, setType] = useState<ManualType>('expense');
  const [toId, setToId] = useState('');
  const [sourceProfile,setSourceProfile]=useState('');
  const [amount, setAmount] = useState('');
  const [date, setDate] = useState(nowShanghai);
  const [category, setCategory] = useState('other');
  const [merchant, setMerchant] = useState('');
  const [note, setNote] = useState('');
  const [editing, setEditing] = useState<{ transaction: Transaction; type: ManualType|'refund'; accountId: string; toId: string; amount: string;
    sourceProfile:string; affectsSpending:boolean;
    date: string; category: string; merchant: string; note: string } | null>(null);

  useEffect(() => { if (!accountId && accounts[0]) setAccountId(accounts[0].id); }, [accountId, accounts]);
  useEffect(() => {
    if (view !== 'partner' || !bound) return;
    let live = true;
    Promise.all([getAccounts(session, 'partner'), getTransactions(session, 'partner')])
      .then(([nextAccounts, nextTransactions]) => {
        if (live) { setPartnerAccounts(nextAccounts); setPartnerTransactions(nextTransactions); }
      }).catch((error) => { if (live) onMessage(error.message); });
    return () => { live = false; };
  }, [view, bound, session, refreshSequence]);

  async function save(event: React.FormEvent) {
    event.preventDefault(); setBusy(true); onMessage('');
    try {
      const result = await createWithKey<TransactionMutation>(session, '/transactions', {
        type, ...transactionAccounts(type, accountId, toId), amount_minor: minor(amount),
        ...(sourceProfile?{source_account_profile_id:sourceProfile}:{}),
        occurred_at: `${date}:00+08:00`, category_code: category, merchant, note,
      });
      setAmount(''); setMerchant(''); setNote('');
      try { await onSaved(); onMessage(`${typeNames[type]}已保存，账户余额已更新。${noticeText(result.notices)}`); }
      catch { onMessage('账单已保存，读取失败。请点“刷新”重试读取。'); }
    } catch (error) { onMessage(error instanceof Error ? error.message : '保存失败。'); }
    finally { setBusy(false); }
  }

  async function saveEdit(event: React.FormEvent) {
    event.preventDefault();
    if (!editing) return;
    setBusy(true); onMessage('');
    try {
      const result = await patchTransaction(session, editing.transaction, {
        ...(editing.type==='refund'?{affects_spending:editing.affectsSpending}:{type:editing.type}),
        source_account_profile_id:editing.sourceProfile||null,
        ...transactionAccounts(editing.type==='refund'?'income':editing.type, editing.accountId, editing.toId), amount_minor: minor(editing.amount),
        occurred_at: `${editing.date}:00+08:00`, category_code: editing.category,
        merchant: editing.merchant, note: editing.note,
      });
      setEditing(null);
      try { await onSaved(); onMessage(`账单已更新。${noticeText(result.notices)}`); }
      catch { onMessage('账单已更新，读取失败。请点“刷新”。'); }
    } catch (error) { onMessage(error instanceof Error ? error.message : '修改失败。'); }
    finally { setBusy(false); }
  }

  async function remove(transaction: Transaction) {
    if (!window.confirm('删除这笔账单并撤销它的资金影响？')) return;
    setBusy(true); onMessage('');
    try {
      await deleteTransaction(session, transaction);
      setEditing(null);
      try { await onSaved(); onMessage('账单已删除，资金已重新核算。'); }
      catch { onMessage('账单已删除，读取失败。请点“刷新”。'); }
    } catch (error) { onMessage(error instanceof Error ? error.message : '删除失败。'); }
    finally { setBusy(false); }
  }

  const visibleAccounts = view === 'mine' ? accounts : partnerAccounts;
  const visibleTransactions = view === 'mine' ? transactions : partnerTransactions;
  return <>
    <div className="section-head"><div><p className="eyebrow">手动记账</p><h1>{view === 'mine' ? '我的账单' : '对象账单'}</h1></div><span>{visibleTransactions.length} 笔</span></div>
    {bound && <div className="view-switch"><button className={view === 'mine' ? 'active' : 'secondary'} onClick={() => setView('mine')}>我的</button>
      <button className={view === 'partner' ? 'active' : 'secondary'} onClick={() => setView('partner')}>对象 · 只读</button></div>}
    {view === 'mine' && <section className="card form-card"><h2>记一笔{typeNames[type]}</h2><form onSubmit={save}>
      <label>记账类型<select value={type} onChange={event => setType(event.target.value as ManualType)}>
        <option value="expense">支出</option><option value="income">收入</option><option value="transfer">内部转账</option></select></label>
      <TransactionAccounts type={type} accounts={accounts} accountId={accountId} toId={toId}
        onAccount={id => { setAccountId(id); if (id === toId) setToId(''); }} onTo={setToId} />
      <SourceProfileSelect session={session} value={sourceProfile} onChange={setSourceProfile}/>
      <div className="two"><label>金额（元）<input inputMode="decimal" value={amount} onChange={(event) => setAmount(event.target.value)} required /></label>
        <label>时间（北京时间）<input type="datetime-local" max={nowShanghai()} value={date} onChange={(event) => setDate(event.target.value)} required /></label></div>
      <label>分类<select value={category} onChange={(event) => setCategory(event.target.value)}>{categories.map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>
      <label>商户<input value={merchant} onChange={(event) => setMerchant(event.target.value)} /></label>
      <label>备注<input value={note} onChange={(event) => setNote(event.target.value)} /></label>
      <button disabled={busy || !accounts.length || (type === 'transfer' && (!toId || toId === accountId))}>保存{typeNames[type]}</button>
    </form></section>}
    <div className="cards">{visibleTransactions.map((transaction) => <article className="card transaction" key={transaction.id}>
      <div><strong>{typeNames[transaction.type]} · {transaction.merchant || categories.find(([value]) => value === transaction.category_code)?.[1] || '其他'}</strong>
        <p className="muted">{transaction.occurred_at.slice(0, 16).replace('T', ' ')} · {transaction.type === 'transfer' ?
          `${visibleAccounts.find(account => account.id === transaction.from_account_id)?.name} → ${visibleAccounts.find(account => account.id === transaction.to_account_id)?.name}` :
          visibleAccounts.find(account => account.id === transaction.account_id)?.name}{transaction.read_only ? ' · 只读' : ''}</p></div>
      <div><strong>{transaction.type === 'income'||transaction.type==='refund' ? '+' : transaction.type === 'expense' ? '−' : ''}{money(transaction.amount_minor)}</strong>
        {transaction.type==='refund'&&<p>{transaction.affects_spending?'抵减花销':'不抵减花销'} · {transaction.refund_kind==='merchant_refund'?'商户退款':'转账退回'}</p>}
        {!!transaction.source_summaries?.length&&<details><summary>官方来源</summary>{transaction.source_summaries.map(s=><p key={s.source_record_id}>{s.platform==='wechat'?'微信':'支付宝'} · 原始时间 {s.source_occurred_at}</p>)}</details>}
        {!transaction.read_only && <div className="view-switch">
          <button className="secondary" disabled={busy} onClick={() => setEditing({ transaction, type: transaction.type,
            accountId: transaction.type === 'transfer' ? transaction.from_account_id : transaction.account_id,
            toId: transaction.type === 'transfer' ? transaction.to_account_id : '', amount: minorInput(transaction.amount_minor),
            sourceProfile:transaction.source_account_profile_id??'',affectsSpending:transaction.type==='refund'?transaction.affects_spending:false,
            date: transaction.occurred_at.slice(0, 16), category: transaction.category_code,
            merchant: transaction.merchant, note: transaction.note })}>编辑</button>
          <button className="secondary" disabled={busy} onClick={() => remove(transaction)}>删除</button>
        </div>}</div>
    </article>)}</div>
    {view === 'mine' && editing && <section className="card form-card"><h2>编辑账单</h2>
      <form onSubmit={saveEdit}>
        {editing.type==='refund'?<p>官方退款 · 类型与来源子类型保持不变。</p>:<label>编辑记账类型<select value={editing.type} onChange={event =>
          setEditing({ ...editing, type: event.target.value as ManualType })}>
          <option value="expense">支出</option><option value="income">收入</option><option value="transfer">内部转账</option></select></label>}
        {editing.type==='refund'&&<label><input type="checkbox" checked={editing.affectsSpending} onChange={e=>setEditing({...editing,affectsSpending:e.target.checked})}/>抵减个人花销</label>}
        <TransactionAccounts type={editing.type==='refund'?'income':editing.type} accounts={accounts} accountId={editing.accountId} toId={editing.toId}
          onAccount={id => setEditing({ ...editing, accountId: id, toId: id === editing.toId ? '' : editing.toId })}
          onTo={id => setEditing({ ...editing, toId: id })} />
        <SourceProfileSelect session={session} value={editing.sourceProfile} onChange={id=>setEditing({...editing,sourceProfile:id})}/>
        <div className="two"><label>金额（元）<input required inputMode="decimal" value={editing.amount} onChange={(event) =>
          setEditing({ ...editing, amount: event.target.value })} /></label>
          <label>时间（北京时间）<input required type="datetime-local" max={nowShanghai()} value={editing.date}
            onChange={(event) => setEditing({ ...editing, date: event.target.value })} /></label></div>
        <label>分类<select value={editing.category} onChange={(event) =>
          setEditing({ ...editing, category: event.target.value })}>{categories.map(([value, label]) =>
            <option key={value} value={value}>{label}</option>)}</select></label>
        <label>商户<input value={editing.merchant} onChange={(event) =>
          setEditing({ ...editing, merchant: event.target.value })} /></label>
        <label>备注<input value={editing.note} onChange={(event) =>
          setEditing({ ...editing, note: event.target.value })} /></label>
        <div className="view-switch"><button disabled={busy || (editing.type === 'transfer' && (!editing.toId || editing.toId === editing.accountId))}>保存修改</button>
          <button type="button" className="secondary" onClick={() => setEditing(null)}>取消</button></div>
      </form>
    </section>}
  </>;
}
