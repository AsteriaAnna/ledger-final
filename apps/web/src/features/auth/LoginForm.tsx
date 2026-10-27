import { useState } from 'react';
import { auth, type Session } from '../../api/client';

export function LoginForm({ onLogin, onMessage }: {
  onLogin: (session: Session, username: string) => void; onMessage: (message: string) => void;
}) {
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);

  async function login(event: React.FormEvent) {
    event.preventDefault(); setBusy(true); onMessage('');
    try {
      const result = await auth.signInWithPassword({ username, password });
      if (result.error || !result.data?.session) throw new Error(result.error?.message ?? '登录失败。');
      onLogin(result.data.session as Session, username);
      setPassword('');
    } catch (error) { onMessage(error instanceof Error ? error.message : '登录失败。'); }
    finally { setBusy(false); }
  }

  return <section className="card auth-card"><h1>登录星账</h1><p>使用已开通的账号继续。</p>
    <form onSubmit={login}>
      <label>用户名<input value={username} onChange={(event) => setUsername(event.target.value)} autoComplete="username" required /></label>
      <label>密码<input value={password} onChange={(event) => setPassword(event.target.value)} autoComplete="current-password" type="password" required /></label>
      <button disabled={busy}>登录</button>
    </form>
  </section>;
}
