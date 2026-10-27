import { useState } from 'react';
import { bindRelationship, createInvitation, type BindingInvitation, type Relationship, type Session } from '../../api/client';

export function RelationshipPage({ session, relationship, onBound, onMessage }: {
  session: Session; relationship: Relationship | null; onBound: (value: Relationship) => void;
  onMessage: (message: string) => void;
}) {
  const [invitation, setInvitation] = useState<BindingInvitation | null>(null);
  const [incomingToken, setIncomingToken] = useState('');
  const [busy, setBusy] = useState(false);

  async function invite() {
    setBusy(true); onMessage('');
    try { setInvitation(await createInvitation(session)); onMessage('绑定凭据已生成，10 分钟内交给对方使用。'); }
    catch (error) { onMessage(error instanceof Error ? error.message : '无法生成凭据。'); }
    finally { setBusy(false); }
  }

  async function bind(event: React.FormEvent) {
    event.preventDefault(); setBusy(true); onMessage('');
    try {
      const next = await bindRelationship(session, incomingToken.trim());
      onBound(next); setInvitation(null); setIncomingToken(''); onMessage('绑定成功。对象账户和账单现在可以只读查看。');
    } catch (error) { onMessage(error instanceof Error ? error.message : '绑定失败。'); }
    finally { setBusy(false); }
  }

  if (!relationship) return <section className="card"><h2>关系</h2><p>正在读取绑定状态…</p></section>;
  if (relationship.status === 'bound') return <section className="card"><h2>关系</h2>
    <p>已绑定：{relationship.partner?.display_name}</p>
    <p className="muted">双方可查看对方账户和账单；每人仍只写自己的账本。</p>
  </section>;

  return <section className="card form-card"><h2>关系绑定</h2>
    <p className="muted">双方都确认后才会绑定。凭据只通过你自己选择的方式交给对方，不会自动发送。</p>
    <button disabled={busy} onClick={invite}>生成我的绑定凭据</button>
    {invitation && <div className="invitation"><p>有效至 {new Date(invitation.expires_at).toLocaleString('zh-CN')}</p>
      <code>{invitation.binding_token}</code>
      <button className="secondary" onClick={() => navigator.clipboard.writeText(invitation.binding_token)
        .then(() => onMessage('凭据已复制。')).catch(() => onMessage('复制失败，请手动选择凭据。'))}>复制凭据</button>
    </div>}
    <form onSubmit={bind}><label>对方给我的绑定凭据
      <input value={incomingToken} onChange={(event) => setIncomingToken(event.target.value)} required /></label>
      <button disabled={busy}>确认绑定</button>
    </form>
  </section>;
}
