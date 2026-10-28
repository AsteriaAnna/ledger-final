import { type Account, type ManualType } from '../../api/client';
import { money } from '../../lib/format';

export const transactionAccounts = (type: ManualType, accountId: string, toId: string) =>
  type === 'transfer' ? { from_account_id: accountId, to_account_id: toId } : { account_id: accountId };

export function TransactionAccounts({ type, accounts, accountId, toId, onAccount, onTo }: {
  type: ManualType; accounts: Account[]; accountId: string; toId: string;
  onAccount: (id: string) => void; onTo: (id: string) => void;
}) {
  return <>
    <label>{type === 'transfer' ? '转出账户' : type === 'income' ? '到账账户' : '付款账户'}
      <select value={accountId} onChange={event => onAccount(event.target.value)} required>
        <option value="">请选择账户</option>
        {accounts.map(account => <option key={account.id} value={account.id}>{account.name} · {money(account.balance_minor)}</option>)}
      </select></label>
    {type === 'transfer' && <>
      <label>转入账户<select value={toId} onChange={event => onTo(event.target.value)} required>
        <option value="">请选择另一个本人账户</option>
        {accounts.filter(account => account.id !== accountId).map(account =>
          <option key={account.id} value={account.id}>{account.name} · {money(account.balance_minor)}</option>)}
      </select></label>
      <p className="muted">仅转出本人流动资金。需要转存款时，请先在账户内调整份额。本期支持无手续费转账。</p>
    </>}
  </>;
}
