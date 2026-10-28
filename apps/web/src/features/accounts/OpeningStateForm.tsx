import { useState } from 'react';
import { putOpeningState, type Account, type OpeningStateInput, type Session } from '../../api/client';
import { minor, minorInput, money, todayShanghai } from '../../lib/format';

export function OpeningStateForm({ session, account, bound, onSaved, onClose, onMessage }: {
  session: Session; account: Account; bound: boolean;
  onSaved: () => Promise<void>; onClose: () => void; onMessage: (message: string) => void;
}) {
  const opening = account.opening_state;
  const initial = (owner: 'self' | 'partner', type: 'liquid' | 'savings') => minorInput(
    opening.opening_allocations.find(row => row.fund_owner === owner && row.fund_type === type)?.amount_minor ?? 0);
  const [date, setDate] = useState(opening.opening_date);
  const [liquid, setLiquid] = useState(() => initial('self', 'liquid'));
  const [savings, setSavings] = useState(() => initial('self', 'savings'));
  const [partner, setPartner] = useState(() => initial('partner', 'savings'));
  const [busy, setBusy] = useState(false);

  async function save(event: React.FormEvent) {
    event.preventDefault(); setBusy(true); onMessage('');
    try {
      const liquidMinor = minor(liquid), savingsMinor = minor(savings), partnerMinor = bound ? minor(partner) : 0;
      const total = liquidMinor + savingsMinor + partnerMinor;
      if (!Number.isSafeInteger(total)) throw new Error('初始金额过大。');
      const input: OpeningStateInput = { opening_date: date, opening_balance_minor: total,
        opening_allocations: [
          { fund_owner: 'self', fund_type: 'liquid', amount_minor: liquidMinor },
          { fund_owner: 'self', fund_type: 'savings', amount_minor: savingsMinor },
          ...(bound ? [{ fund_owner: 'partner' as const, fund_type: 'savings' as const, amount_minor: partnerMinor }] : []),
        ] };
      await putOpeningState(session, account, input);
      onClose();
      try { await onSaved(); onMessage('初始状态已保存，本账户的资金影响已重新核算。'); }
      catch { onMessage('初始状态已保存，读取失败。请点“刷新”。'); }
    } catch (error) { onMessage(error instanceof Error ? error.message : '修正失败。'); }
    finally { setBusy(false); }
  }

  return <section className="card form-card"><h2>修正「{account.name}」的初始状态</h2>
    <p className="muted">原初始余额 {money(opening.opening_balance_minor)}。新的初始余额由下列份额合计。</p>
    <p className="muted">保存后会按新起始日和初始份额重新核算本账户的资金影响。交易内容及其他账户保持原状；无法安全重建时保留原记录。</p>
    <form onSubmit={save}>
      <label>修正起始日期<input type="date" max={todayShanghai()} value={date} onChange={event => setDate(event.target.value)} required /></label>
      <label>初始本人流动资金（元）<input inputMode="decimal" value={liquid} onChange={event => setLiquid(event.target.value)} required /></label>
      <label>初始本人存款（元）<input inputMode="decimal" value={savings} onChange={event => setSavings(event.target.value)} required /></label>
      {bound && <label>初始对象存款（元）<input inputMode="decimal" value={partner} onChange={event => setPartner(event.target.value)} required /></label>}
      <div className="view-switch"><button disabled={busy}>保存初始状态</button>
        <button type="button" className="secondary" disabled={busy} onClick={onClose}>取消</button></div>
    </form>
  </section>;
}
