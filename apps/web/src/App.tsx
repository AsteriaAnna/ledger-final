import { useEffect, useState } from 'react';
import { activeSession, auth, clearUserIntent, createWithKey, getAccounts, getTransactions, pendingIntents, type Account, type Transaction } from './backend';

type Session = NonNullable<Awaited<ReturnType<typeof activeSession>>>;
type Page = 'home' | 'accounts' | 'transactions' | 'imports' | 'me';
const pages: [Page, string][] = [['home', '首页'], ['accounts', '账户'], ['transactions', '账单'], ['imports', '导入'], ['me', '我的']];
const types: [string, string][] = [['cash', '现金'], ['bank_card', '银行卡'], ['wechat_balance', '微信零钱'], ['alipay_balance', '支付宝余额'], ['other', '其他']];
const categories: [string, string][] = [['food', '餐饮'], ['shopping', '购物'], ['transport', '交通'], ['education', '教育'], ['health', '医疗'], ['entertainment', '娱乐'], ['utilities', '生活缴费'], ['other', '其他']];

const money = (minor: number) => `¥${(minor / 100).toFixed(2)}`;
function minor(value: string): number {
  if (!/^\d+(?:\.\d{1,2})?$/.test(value)) throw new Error('金额请输入最多两位小数。');
  const [yuan, fen = ''] = value.split('.');
  const cents = Number(`${yuan}${fen.padEnd(2, '0')}`);
  if (!Number.isSafeInteger(cents)) throw new Error('金额过大。');
  return cents;
}
function todayShanghai(): string {
  const parts = new Intl.DateTimeFormat('en-US', { timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(new Date());
  const value = Object.fromEntries(parts.map(({ type, value }) => [type, value]));
  return `${value.year}-${value.month}-${value.day}`;
}
function nowShanghai(): string {
  return new Date(Date.now() + 8 * 60 * 60 * 1000).toISOString().slice(0, 16);
}
function pageFromHash(): Page {
  const value = location.hash.slice(2);
  return pages.some(([key]) => key === value) ? value as Page : 'accounts';
}

export function App() {
  const [page, setPage] = useState<Page>(pageFromHash);
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('');
  const [accounts, setAccounts] = useState<Account[]>([]);
  const [transactions, setTransactions] = useState<Transaction[]>([]);
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [accountName, setAccountName] = useState('');
  const [accountType, setAccountType] = useState('cash');
  const [openingDate, setOpeningDate] = useState(todayShanghai);
  const [liquid, setLiquid] = useState('0.00');
  const [savings, setSavings] = useState('0.00');
  const [expenseAccount, setExpenseAccount] = useState('');
  const [expenseAmount, setExpenseAmount] = useState('');
  const [expenseDate, setExpenseDate] = useState(nowShanghai);
  const [category, setCategory] = useState('other');
  const [merchant, setMerchant] = useState('');
  const [note, setNote] = useState('');

  useEffect(() => {
    const onHash = () => setPage(pageFromHash());
    window.addEventListener('hashchange', onHash);
    activeSession().then((value) => setSession(value)).catch(() => setMessage('登录状态读取失败，请刷新重试。')).finally(() => setLoading(false));
    return () => window.removeEventListener('hashchange', onHash);
  }, []);

  async function refresh(current: Session) {
    const [nextAccounts, nextTransactions] = await Promise.all([getAccounts(current), getTransactions(current)]);
    setAccounts(nextAccounts);
    setTransactions(nextTransactions);
    setExpenseAccount((value) => value || nextAccounts[0]?.id || '');
  }

  useEffect(() => {
    if (!session) return;
    refresh(session).catch((error) => setMessage(error.message));
  }, [session]);

  async function login(event: React.FormEvent) {
    event.preventDefault(); setBusy(true); setMessage('');
    try {
      const result = await auth.signInWithPassword({ username, password });
      if (result.error || !result.data?.session) throw new Error(result.error?.message ?? '登录失败。');
      setSession(result.data.session as Session); setPassword(''); location.hash = '#/accounts';
    } catch (error) { setMessage(error instanceof Error ? error.message : '登录失败。'); }
    finally { setBusy(false); }
  }

  async function logout() {
    if (session) clearUserIntent(session);
    await auth.signOut(); setSession(null); setAccounts([]); setTransactions([]); setPassword(''); location.hash = '#/me';
  }

  async function saveAccount(event: React.FormEvent) {
    event.preventDefault(); if (!session) return;
    setBusy(true); setMessage('');
    try {
      const openingLiquid = minor(liquid), openingSavings = minor(savings);
      const total = openingLiquid + openingSavings;
      if (!Number.isSafeInteger(total)) throw new Error('初始金额过大。');
      await createWithKey<Account>(session, '/accounts', {
        name: accountName, account_type: accountType, custodian: 'self',
        opening_state: { opening_date: openingDate, opening_balance_minor: total,
          opening_allocations: [
            { fund_owner: 'self', fund_type: 'liquid', amount_minor: openingLiquid },
            { fund_owner: 'self', fund_type: 'savings', amount_minor: openingSavings },
          ] },
      });
      setAccountName(''); setLiquid('0.00'); setSavings('0.00');
      try { await refresh(session); setMessage('账户已保存。'); }
      catch { setMessage('账户已保存，读取失败。请点“刷新”重试读取。'); }
    } catch (error) { setMessage(error instanceof Error ? error.message : '保存失败。'); }
    finally { setBusy(false); }
  }

  async function saveExpense(event: React.FormEvent) {
    event.preventDefault(); if (!session) return;
    setBusy(true); setMessage('');
    try {
      await createWithKey(session, '/transactions', {
        type: 'expense', account_id: expenseAccount, amount_minor: minor(expenseAmount),
        occurred_at: `${expenseDate}:00+08:00`, category_code: category, merchant, note,
      });
      setExpenseAmount(''); setMerchant(''); setNote('');
      try { await refresh(session); setMessage('支出已保存，账户余额已更新。'); }
      catch { setMessage('支出已保存，读取失败。请点“刷新”重试读取。'); }
    } catch (error) { setMessage(error instanceof Error ? error.message : '保存失败。'); }
    finally { setBusy(false); }
  }

  return <div className="shell">
    <header className="top"><div><strong>星账</strong><span>看清每一笔钱</span></div>{session && <button className="text-button" onClick={() => refresh(session).then(() => setMessage('已刷新。')).catch((error) => setMessage(error.message))}>刷新</button>}</header>
    <nav>{pages.map(([key, label]) => <a key={key} className={page === key ? 'active' : ''} href={`#/${key}`}>{label}</a>)}</nav>
    <main>
      {loading ? <p>正在恢复登录状态…</p> : !session ? <section className="card auth-card"><h1>登录星账</h1><p>使用已开通的账号继续。</p><form onSubmit={login}><label>用户名<input value={username} onChange={(event) => setUsername(event.target.value)} autoComplete="username" required /></label><label>密码<input value={password} onChange={(event) => setPassword(event.target.value)} autoComplete="current-password" type="password" required /></label><button disabled={busy}>登录</button></form></section> : <>
        {page === 'accounts' && <><div className="section-head"><div><p className="eyebrow">实际账户</p><h1>我的账户</h1></div><span>{accounts.length} 个账户</span></div><div className="cards">{accounts.map((account) => <article className="card" key={account.id}><div className="card-head"><h2>{account.name}</h2><span>{types.find(([type]) => type === account.account_type)?.[1]}</span></div><p className="balance">{money(account.balance_minor)}</p><p className="muted">起始日 {account.opening_state.opening_date}</p><div className="shares">{account.fund_shares.map((share) => <div key={share.fund_type}><span>{share.fund_type === 'liquid' ? '流动资金' : '存款'}</span><strong>{money(share.amount_minor)}</strong></div>)}</div></article>)}</div><section className="card form-card"><h2>创建实际账户</h2><p className="muted">初始资金只建立账户基准，不计为收入。</p><form onSubmit={saveAccount}><label>账户名称<input value={accountName} maxLength={80} onChange={(event) => setAccountName(event.target.value)} placeholder="例如：日常现金" required /></label><label>账户类型<select value={accountType} onChange={(event) => setAccountType(event.target.value)}>{types.map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></label><label>起始日期<input type="date" max={todayShanghai()} value={openingDate} onChange={(event) => setOpeningDate(event.target.value)} required /></label><div className="two"><label>本人流动资金（元）<input inputMode="decimal" value={liquid} onChange={(event) => setLiquid(event.target.value)} required /></label><label>本人存款（元）<input inputMode="decimal" value={savings} onChange={(event) => setSavings(event.target.value)} required /></label></div><button disabled={busy}>保存账户</button></form></section></>}
        {page === 'transactions' && <><div className="section-head"><div><p className="eyebrow">手动记账</p><h1>账单</h1></div><span>{transactions.length} 笔</span></div><section className="card form-card"><h2>记一笔支出</h2><form onSubmit={saveExpense}><label>付款账户<select value={expenseAccount} onChange={(event) => setExpenseAccount(event.target.value)} required><option value="">请选择账户</option>{accounts.map((account) => <option key={account.id} value={account.id}>{account.name} · {money(account.balance_minor)}</option>)}</select></label><div className="two"><label>金额（元）<input inputMode="decimal" value={expenseAmount} onChange={(event) => setExpenseAmount(event.target.value)} required /></label><label>时间（北京时间）<input type="datetime-local" max={nowShanghai()} value={expenseDate} onChange={(event) => setExpenseDate(event.target.value)} required /></label></div><label>分类<select value={category} onChange={(event) => setCategory(event.target.value)}>{categories.map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label><label>商户<input value={merchant} onChange={(event) => setMerchant(event.target.value)} /></label><label>备注<input value={note} onChange={(event) => setNote(event.target.value)} /></label><button disabled={busy || !accounts.length}>保存支出</button></form></section><div className="cards">{transactions.map((transaction) => <article className="card transaction" key={transaction.id}><div><strong>{transaction.merchant || categories.find(([value]) => value === transaction.category_code)?.[1] || '支出'}</strong><p className="muted">{transaction.occurred_at.slice(0, 16).replace('T', ' ')} · {accounts.find((account) => account.id === transaction.account_id)?.name}</p></div><strong>−{money(transaction.amount_minor)}</strong></article>)}</div></>}
        {page === 'me' && <section className="card"><h1>我的</h1><p>已登录：{username || session.user?.id}</p>{pendingIntents(session) > 0 && <p><button className="secondary" onClick={() => { clearUserIntent(session); setMessage('未确认的本地操作已取消。请先检查账户和账单，确认没有重复记录。'); }}>我已核对，取消未确认操作</button></p>}<button className="secondary" onClick={logout}>退出登录</button></section>}
        {page === 'home' && <section className="card"><h1>当前资金</h1><p className="balance">{money(accounts.reduce((sum, account) => sum + account.balance_minor, 0))}</p><p className="muted">按当前账户余额汇总；月度统计将在后续增量接入。</p></section>}
        {page === 'imports' && <section className="card"><h1>官方账单导入</h1><p>账户与手动记账链路完成后接入微信、支付宝官方文件。</p></section>}
      </>}
      {message && <p className="message" role="status">{message}</p>}
    </main>
  </div>;
}
