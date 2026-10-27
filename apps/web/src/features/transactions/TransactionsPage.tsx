import { useEffect, useState } from 'react';
import { createWithKey, deleteTransaction, getAccounts, getTransactions, patchTransaction,
  type Account, type Session, type Transaction, type TransactionMutation, type FundNotice } from '../../api/client';
import { minor, money, nowShanghai } from '../../lib/format';

const categories: [string, string][] = [['food', '餐饮'], ['shopping', '购物'], ['transport', '交通'], ['education', '教育'], ['health', '医疗'], ['entertainment', '娱乐'], ['utilities', '生活缴费'], ['other', '其他']];
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
  const [amount, setAmount] = useState('');
  const [date, setDate] = useState(nowShanghai);
  const [category, setCategory] = useState('other');
  const [merchant, setMerchant] = useState('');
  const [note, setNote] = useState('');
  const [editing, setEditing] = useState<{ transaction: Transaction; accountId: string; amount: string;
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
        type: 'expense', account_id: accountId, amount_minor: minor(amount),
        occurred_at: `${date}:00+08:00`, category_code: category, merchant, note,
      });
      setAmount(''); setMerchant(''); setNote('');
      try { await onSaved(); onMessage(`支出已保存，账户余额已更新。${noticeText(result.notices)}`); }
      catch { onMessage('支出已保存，读取失败。请点“刷新”重试读取。'); }
    } catch (error) { onMessage(error instanceof Error ? error.message : '保存失败。'); }
    finally { setBusy(false); }
  }

  async function saveEdit(event: React.FormEvent) {
    event.preventDefault();
    if (!editing) return;
    setBusy(true); onMessage('');
    try {
      const result = await patchTransaction(session, editing.transaction, {
        account_id: editing.accountId, amount_minor: minor(editing.amount),
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
    {view === 'mine' && <section className="card form-card"><h2>记一笔支出</h2><form onSubmit={save}>
      <label>付款账户<select value={accountId} onChange={(event) => setAccountId(event.target.value)} required><option value="">请选择账户</option>
        {accounts.map((account) => <option key={account.id} value={account.id}>{account.name} · {money(account.balance_minor)}</option>)}</select></label>
      <div className="two"><label>金额（元）<input inputMode="decimal" value={amount} onChange={(event) => setAmount(event.target.value)} required /></label>
        <label>时间（北京时间）<input type="datetime-local" max={nowShanghai()} value={date} onChange={(event) => setDate(event.target.value)} required /></label></div>
      <label>分类<select value={category} onChange={(event) => setCategory(event.target.value)}>{categories.map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>
      <label>商户<input value={merchant} onChange={(event) => setMerchant(event.target.value)} /></label>
      <label>备注<input value={note} onChange={(event) => setNote(event.target.value)} /></label>
      <button disabled={busy || !accounts.length}>保存支出</button>
    </form></section>}
    <div className="cards">{visibleTransactions.map((transaction) => <article className="card transaction" key={transaction.id}>
      <div><strong>{transaction.merchant || categories.find(([value]) => value === transaction.category_code)?.[1] || '支出'}</strong>
        <p className="muted">{transaction.occurred_at.slice(0, 16).replace('T', ' ')} · {visibleAccounts.find((account) => account.id === transaction.account_id)?.name}{transaction.read_only ? ' · 只读' : ''}</p></div>
      <div><strong>−{money(transaction.amount_minor)}</strong>
        {!transaction.read_only && <div className="view-switch">
          <button className="secondary" disabled={busy} onClick={() => setEditing({ transaction,
            accountId: transaction.account_id, amount: (transaction.amount_minor / 100).toFixed(2),
            date: transaction.occurred_at.slice(0, 16), category: transaction.category_code,
            merchant: transaction.merchant, note: transaction.note })}>编辑</button>
          <button className="secondary" disabled={busy} onClick={() => remove(transaction)}>删除</button>
        </div>}</div>
    </article>)}</div>
    {view === 'mine' && editing && <section className="card form-card"><h2>编辑支出</h2>
      <form onSubmit={saveEdit}>
        <label>付款账户<select value={editing.accountId} onChange={(event) =>
          setEditing({ ...editing, accountId: event.target.value })}>{accounts.map((account) =>
            <option key={account.id} value={account.id}>{account.name}</option>)}</select></label>
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
        <div className="view-switch"><button disabled={busy}>保存修改</button>
          <button type="button" className="secondary" onClick={() => setEditing(null)}>取消</button></div>
      </form>
    </section>}
  </>;
}
