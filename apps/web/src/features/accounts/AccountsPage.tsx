import { useEffect, useState } from 'react';
import { createWithKey, getAccounts, patchAccount, type Account, type Session } from '../../api/client';
import { minor, money, todayShanghai } from '../../lib/format';

const types: [string, string][] = [['cash', '现金'], ['bank_card', '银行卡'], ['wechat_balance', '微信零钱'], ['alipay_balance', '支付宝余额'], ['other', '其他']];

export function AccountsPage({ session, accounts, bound, refreshSequence, onSaved, onMessage }: {
  session: Session; accounts: Account[]; bound: boolean; refreshSequence: number;
  onSaved: () => Promise<void>; onMessage: (message: string) => void;
}) {
  const [view, setView] = useState<'mine' | 'partner'>('mine');
  const [partnerAccounts, setPartnerAccounts] = useState<Account[]>([]);
  const [busy, setBusy] = useState(false);
  const [name, setName] = useState('');
  const [type, setType] = useState('cash');
  const [openingDate, setOpeningDate] = useState(todayShanghai);
  const [liquid, setLiquid] = useState('0.00');
  const [savings, setSavings] = useState('0.00');
  const [editing, setEditing] = useState<{ account: Account; name: string; type: string; custodian: 'self' | 'partner' } | null>(null);
  const [adjusting, setAdjusting] = useState<{ account: Account; from: 'liquid' | 'savings'; amount: string } | null>(null);

  useEffect(() => {
    if (view !== 'partner' || !bound) return;
    let live = true;
    getAccounts(session, 'partner').then((value) => { if (live) setPartnerAccounts(value); })
      .catch((error) => { if (live) onMessage(error.message); });
    return () => { live = false; };
  }, [view, bound, session, refreshSequence]);

  async function save(event: React.FormEvent) {
    event.preventDefault(); setBusy(true); onMessage('');
    try {
      const openingLiquid = minor(liquid), openingSavings = minor(savings);
      const total = openingLiquid + openingSavings;
      if (!Number.isSafeInteger(total)) throw new Error('初始金额过大。');
      await createWithKey<Account>(session, '/accounts', {
        name, account_type: type, custodian: 'self',
        opening_state: { opening_date: openingDate, opening_balance_minor: total,
          opening_allocations: [
            { fund_owner: 'self', fund_type: 'liquid', amount_minor: openingLiquid },
            { fund_owner: 'self', fund_type: 'savings', amount_minor: openingSavings },
          ] },
      });
      setName(''); setLiquid('0.00'); setSavings('0.00');
      try { await onSaved(); onMessage('账户已保存。'); }
      catch { onMessage('账户已保存，读取失败。请点“刷新”重试读取。'); }
    } catch (error) { onMessage(error instanceof Error ? error.message : '保存失败。'); }
    finally { setBusy(false); }
  }

  async function saveEdit(event: React.FormEvent) {
    event.preventDefault();
    if (!editing) return;
    setBusy(true); onMessage('');
    try {
      await patchAccount(session, editing.account, {
        name: editing.name, account_type: editing.type, custodian: editing.custodian,
      });
      setEditing(null);
      try { await onSaved(); onMessage('账户资料已更新。'); }
      catch { onMessage('账户资料已更新，读取失败。请点“刷新”。'); }
    } catch (error) { onMessage(error instanceof Error ? error.message : '修改失败。'); }
    finally { setBusy(false); }
  }

  async function saveAdjustment(event: React.FormEvent) {
    event.preventDefault();
    if (!adjusting) return;
    setBusy(true); onMessage('');
    try {
      const amount = minor(adjusting.amount);
      if (amount <= 0) throw new Error('调整金额必须大于零。');
      await createWithKey<Account>(session, `/accounts/${adjusting.account.id}/fund-adjustments`, {
        from: { fund_owner: 'self', fund_type: adjusting.from },
        to: { fund_owner: 'self', fund_type: adjusting.from === 'liquid' ? 'savings' : 'liquid' },
        amount_minor: amount,
      }, adjusting.account.version);
      setAdjusting(null);
      try { await onSaved(); onMessage('资金份额已调整，账户余额不变。'); }
      catch { onMessage('资金份额已调整，读取失败。请点“刷新”。'); }
    } catch (error) { onMessage(error instanceof Error ? error.message : '调整失败。'); }
    finally { setBusy(false); }
  }

  const visible = view === 'mine' ? accounts : partnerAccounts;
  return <>
    <div className="section-head"><div><p className="eyebrow">实际账户</p><h1>{view === 'mine' ? '我的账户' : '对象账户'}</h1></div><span>{visible.length} 个账户</span></div>
    {bound && <div className="view-switch"><button className={view === 'mine' ? 'active' : 'secondary'} onClick={() => setView('mine')}>我的</button>
      <button className={view === 'partner' ? 'active' : 'secondary'} onClick={() => setView('partner')}>对象 · 只读</button></div>}
    <div className="cards">{visible.map((account) => <article className="card" key={account.id}>
      <div className="card-head"><h2>{account.name}</h2><span>{types.find(([key]) => key === account.account_type)?.[1]}</span></div>
      <p className="balance">{money(account.balance_minor)}</p><p className="muted">起始日 {account.opening_state.opening_date}{account.read_only ? ' · 只读' : ''}</p>
      <div className="shares">{account.fund_shares.map((share) => <div key={`${share.fund_owner}:${share.fund_type}`}>
        <span>{share.fund_owner === 'self' ? '本人' : '对象'}{share.fund_type === 'liquid' ? '流动资金' : '存款'}</span>
        <strong>{money(share.amount_minor)}</strong>
      </div>)}</div>
      {!account.read_only && <div className="view-switch"><button className="secondary" disabled={busy} onClick={() =>
        setEditing({ account, name: account.name, type: account.account_type, custodian: account.custodian })}>修改资料</button>
        <button className="secondary" disabled={busy} onClick={() =>
          setAdjusting({ account, from: 'liquid', amount: '' })}>调整份额</button></div>}
    </article>)}</div>
    {view === 'mine' && editing && <section className="card form-card"><h2>修改账户资料</h2>
      <p className="muted">初始金额和份额需要单独的修正流程，这里只修改资料。</p>
      <form onSubmit={saveEdit}>
        <label>名称<input required maxLength={80} value={editing.name} onChange={(event) =>
          setEditing({ ...editing, name: event.target.value })} /></label>
        <label>类型<select value={editing.type} onChange={(event) =>
          setEditing({ ...editing, type: event.target.value })}>{types.map(([value, label]) =>
            <option value={value} key={value}>{label}</option>)}</select></label>
        {bound && <label>保管人<select value={editing.custodian} onChange={(event) =>
          setEditing({ ...editing, custodian: event.target.value as 'self' | 'partner' })}>
          <option value="self">本人</option><option value="partner">对象</option></select></label>}
        <div className="view-switch"><button disabled={busy}>保存修改</button>
          <button type="button" className="secondary" onClick={() => setEditing(null)}>取消</button></div>
      </form>
    </section>}
    {view === 'mine' && adjusting && <section className="card form-card"><h2>调整「{adjusting.account.name}」的资金份额</h2>
      <p className="muted">在本人流动资金和本人存款间划转，账户余额保持不变。存款基准会同步调整。</p>
      <form onSubmit={saveAdjustment}>
        <label>划转方向<select value={adjusting.from} onChange={(event) =>
          setAdjusting({ ...adjusting, from: event.target.value as 'liquid' | 'savings' })}>
          <option value="liquid">流动资金 → 存款</option><option value="savings">存款 → 流动资金</option></select></label>
        <label>金额（元）<input inputMode="decimal" value={adjusting.amount} onChange={(event) =>
          setAdjusting({ ...adjusting, amount: event.target.value })} required /></label>
        <div className="view-switch"><button disabled={busy}>确认调整</button>
          <button type="button" className="secondary" onClick={() => setAdjusting(null)}>取消</button></div>
      </form>
    </section>}
    {view === 'mine' && <section className="card form-card"><h2>创建实际账户</h2><p className="muted">初始资金只建立账户基准，不计为收入。</p>
      <form onSubmit={save}>
        <label>账户名称<input value={name} maxLength={80} onChange={(event) => setName(event.target.value)} placeholder="例如：日常现金" required /></label>
        <label>账户类型<select value={type} onChange={(event) => setType(event.target.value)}>{types.map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></label>
        <label>起始日期<input type="date" max={todayShanghai()} value={openingDate} onChange={(event) => setOpeningDate(event.target.value)} required /></label>
        <div className="two"><label>本人流动资金（元）<input inputMode="decimal" value={liquid} onChange={(event) => setLiquid(event.target.value)} required /></label>
          <label>本人存款（元）<input inputMode="decimal" value={savings} onChange={(event) => setSavings(event.target.value)} required /></label></div>
        <button disabled={busy}>保存账户</button>
      </form>
    </section>}
  </>;
}
