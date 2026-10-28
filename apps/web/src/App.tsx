import { useEffect, useState } from 'react';
import { activeSession, auth, clearUserIntent, getAccounts, getRelationship, getTransactions,
  pendingIntents, type Account, type Relationship, type Session, type Transaction } from './api/client';
import { AccountsPage } from './features/accounts/AccountsPage';
import { LoginForm } from './features/auth/LoginForm';
import { RelationshipPage } from './features/relationship/RelationshipPage';
import { TransactionsPage } from './features/transactions/TransactionsPage';
import { ImportsPage } from './features/imports/ImportsPage';
import { money } from './lib/format';

type Page = 'home' | 'accounts' | 'transactions' | 'imports' | 'me';
const pages: [Page, string][] = [['home', '首页'], ['accounts', '账户'], ['transactions', '账单'], ['imports', '导入'], ['me', '我的']];

function pageFromHash(): Page {
  const value = location.hash.slice(2);
  return pages.some(([key]) => key === value) ? value as Page : 'accounts';
}

export function App() {
  const [page, setPage] = useState<Page>(pageFromHash);
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const [message, setMessage] = useState('');
  const [accounts, setAccounts] = useState<Account[]>([]);
  const [transactions, setTransactions] = useState<Transaction[]>([]);
  const [relationship, setRelationship] = useState<Relationship | null>(null);
  const [username, setUsername] = useState('');
  const [refreshSequence, setRefreshSequence] = useState(0);

  useEffect(() => {
    const onHash = () => setPage(pageFromHash());
    window.addEventListener('hashchange', onHash);
    activeSession().then(setSession).catch(() => setMessage('登录状态读取失败，请刷新重试。'))
      .finally(() => setLoading(false));
    return () => window.removeEventListener('hashchange', onHash);
  }, []);

  async function refresh(current: Session) {
    // The first authenticated call provisions this identity once if needed.
    const nextRelationship = await getRelationship(current);
    const [nextAccounts, nextTransactions] = await Promise.all([getAccounts(current), getTransactions(current)]);
    setRelationship(nextRelationship);
    setAccounts(nextAccounts);
    setTransactions(nextTransactions);
    setRefreshSequence((value) => value + 1);
  }

  useEffect(() => {
    if (!session) return;
    refresh(session).catch((error) => setMessage(error.message));
  }, [session]);

  async function logout() {
    await auth.signOut();
    setSession(null); setAccounts([]); setTransactions([]); setRelationship(null);
    setUsername(''); location.hash = '#/me';
    // Pending write intents survive sign-out so the same user can safely retry.
  }

  return <div className="shell">
    <header className="top"><div><strong>星账</strong><span>看清每一笔钱</span></div>
      {session && <button className="text-button" onClick={() => refresh(session)
        .then(() => setMessage('已刷新。')).catch((error) => setMessage(error.message))}>刷新</button>}
    </header>
    <nav>{pages.map(([key, label]) => <a key={key} className={page === key ? 'active' : ''} href={`#/${key}`}>{label}</a>)}</nav>
    <main>
      {loading ? <p>正在恢复登录状态…</p> : !session ?
        <LoginForm onLogin={(value, name) => { setSession(value); setUsername(name); location.hash = '#/accounts'; }} onMessage={setMessage} /> : <>
          {page === 'accounts' && <AccountsPage session={session} accounts={accounts}
            bound={relationship?.status === 'bound'} refreshSequence={refreshSequence}
            onSaved={() => refresh(session)} onMessage={setMessage} />}
          {page === 'transactions' && <TransactionsPage session={session} accounts={accounts} transactions={transactions}
            bound={relationship?.status === 'bound'} refreshSequence={refreshSequence}
            onSaved={() => refresh(session)} onMessage={setMessage} />}
          {page === 'me' && <><RelationshipPage session={session} relationship={relationship}
            onBound={(value) => { setRelationship(value); setRefreshSequence((n) => n + 1); }} onMessage={setMessage} />
            <section className="card"><h2>我的</h2><p>已登录：{username || session.user?.id}</p>
              {pendingIntents(session) > 0 && <p><button className="secondary" onClick={() => {
                clearUserIntent(session); setMessage('未确认的本地操作已取消。请先检查账户和账单，确认没有重复记录。');
              }}>我已核对，取消未确认操作</button></p>}
              <button className="secondary" onClick={logout}>退出登录</button>
            </section></>}
          {page === 'home' && <section className="card"><h1>当前资金</h1>
            <p className="balance">{money(accounts.reduce((sum, account) => sum + account.balance_minor, 0))}</p>
            <p className="muted">只汇总本人的实际账户；对象资金另行查看。</p>
          </section>}
          {page === 'imports' && <ImportsPage session={session} accounts={accounts} transactions={transactions}
            onSaved={()=>refresh(session)} onMessage={setMessage}/>}
        </>}
      {message && <p className="message" role="status">{message}</p>}
    </main>
  </div>;
}
