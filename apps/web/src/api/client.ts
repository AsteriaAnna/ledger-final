import cloudbase from '@cloudbase/js-sdk';

const env = import.meta.env.VITE_CLOUDBASE_ENV_ID;
const accessKey = import.meta.env.VITE_PUBLISHABLE_KEY;
if (!env || !accessKey) throw new Error('CloudBase Web configuration is incomplete');
const apiBase = (import.meta.env.VITE_API_BASE_URL || '').replace(/\/$/, '');
if (apiBase) {
  const apiUrl = new URL(apiBase);
  if (apiUrl.protocol !== 'https:' || apiUrl.origin !== apiBase || apiUrl.username || apiUrl.password) {
    throw new Error('API address must be an HTTPS origin');
  }
}

export const cloudApp = cloudbase.init({
  env,
  region: import.meta.env.VITE_CLOUDBASE_REGION || 'ap-shanghai',
  accessKey,
  auth: { detectSessionInUrl: true },
});
export const auth = cloudApp.auth;

export type Account = {
  id: string; name: string; account_type: string; holder: 'self' | 'partner'; custodian: 'self' | 'partner';
  opening_state: { opening_date: string; opening_balance_minor: number; opening_allocations: { fund_owner: string; fund_type: string; amount_minor: number }[] };
  balance_minor: number; fund_shares: { fund_owner: string; fund_type: string; amount_minor: number; savings_baseline_minor: number | null; savings_gap_minor: number | null }[];
  version: number; read_only: boolean;
};
export type ManualType = 'income' | 'expense' | 'transfer';
export type Transaction = {
  id: string; amount_minor: number; occurred_at: string; category_code: string;
  merchant: string; note: string; version: number; read_only: boolean;
  source_account_profile_id: string|null; source_summaries:{source_record_id:string;platform:string;source_occurred_at:string}[];
} & ({ type: 'income' | 'expense'; account_id: string } |
  { type: 'transfer'; from_account_id: string; to_account_id: string } |
  { type:'refund'; account_id:string; refund_kind:'merchant_refund'|'transfer_return'; affects_spending:boolean });
export type Relationship = {
  status: 'unbound' | 'bound'; partner: { id: string; display_name: string } | null;
  permissions: { partner_accounts: 'none' | 'read_only'; partner_transactions: 'none' | 'read_only' };
};
export type BindingInvitation = { binding_token: string; expires_at: string };
export type FundNotice = { code: 'OWN_SAVINGS_USED' | 'PARTNER_SAVINGS_USED'; amount_minor: number };
export type TransactionMutation = { transaction: Transaction; notices: FundNotice[] };
export type OpeningStateInput = {
  opening_date: string; opening_balance_minor: number;
  opening_allocations: Array<({ fund_owner: 'self'; fund_type: 'liquid' | 'savings' } |
    { fund_owner: 'partner'; fund_type: 'savings' }) & { amount_minor: number }>;
};

export type Session = { access_token: string; user?: { id?: string } };
class ApiError extends Error {
  constructor(public status: number, public code: string | undefined, message: string) { super(message); }
}
export async function activeSession(): Promise<Session | null> {
  const { data, error } = await auth.getSession();
  if (error || !data?.session || data.session.user?.is_anonymous) return null;
  return data.session as Session;
}

export async function requestEnvelope<T>(session: Session, path: string, init?: RequestInit): Promise<T> {
  const current=await auth.getSession();
  const latest=current.data?.session;
  if(!latest || latest.user?.is_anonymous || latest.user?.id!==session.user?.id){
    if(current.error)throw new ApiError(500,'INTERNAL_ERROR','暂时无法恢复登录状态，请稍后重试。');
    window.dispatchEvent(new Event('sl-session-expired'));
    throw new ApiError(401,'UNAUTHENTICATED','请重新登录，未确认的保存操作仍会保留。');
  }
  const response = await fetch(`${apiBase}/api/v1${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${latest.access_token}`, ...(init?.body instanceof FormData ? {} : {'Content-Type': 'application/json'}), ...init?.headers },
  });
  const body = await response.json().catch(() => null);
  if (!response.ok) {
    if(response.status===401)window.dispatchEvent(new Event('sl-session-expired'));
    throw new ApiError(response.status, body?.code, body?.message ?? `请求失败（${response.status}）`);
  }
  return body as T;
}
export async function request<T>(session: Session,path:string,init?:RequestInit):Promise<T> {
  return (await requestEnvelope<{data:T}>(session,path,init)).data;
}

export type Page<T>={data:T[];page:{next_cursor:string|null}};
export async function getAccounts(session:Session,view:'mine'|'partner'='mine'):Promise<Account[]> {
  const all:Account[]=[];let cursor:string|null=null;const seen=new Set<string>();
  do{const query=new URLSearchParams({view,limit:'100'});if(cursor)query.set('cursor',cursor);
    const page=await requestEnvelope<Page<Account>>(session,`/accounts?${query}`);all.push(...page.data);cursor=page.page.next_cursor;
    if(cursor){if(seen.has(cursor))throw new Error('账户分页读取异常，请刷新重试。');seen.add(cursor);}
  }while(cursor);return all;
}
export const getAccount = (session: Session, accountId: string) =>
  request<Account>(session, `/accounts/${encodeURIComponent(accountId)}`);
export const putOpeningState = (session: Session, account: Account, input: OpeningStateInput) =>
  request<Account>(session, `/accounts/${account.id}/opening-state`, {
    method: 'PUT', headers: { 'If-Match': `"${account.version}"` }, body: JSON.stringify(input),
  });
export function getTransactionPage(session:Session,filters:Record<string,string>={}) {
  const query=new URLSearchParams();for(const [key,value] of Object.entries(filters))if(value)query.set(key,value);
  return requestEnvelope<Page<Transaction>>(session,`/transactions?${query}`);
}
export const getTransactions=async(session:Session,view:'mine'|'partner'='mine')=>(await getTransactionPage(session,{view})).data;
export const getRelationship = async (session: Session) => request<Relationship>(session, '/relationship');
export const createInvitation = async (session: Session) =>
  createWithKey<BindingInvitation>(session, '/relationship/invitations', {});
export const bindRelationship = async (session: Session, binding_token: string) =>
  createWithKey<Relationship>(session, '/relationship/binding', { binding_token });

export const patchAccount = (session: Session, account: Account, patch: {
  name?: string; account_type?: string; custodian?: 'self' | 'partner';
}) => request<Account>(session, `/accounts/${account.id}`, {
  method: 'PATCH', headers: { 'If-Match': `"${account.version}"` }, body: JSON.stringify(patch),
});

export const patchTransaction = (session: Session, transaction: Transaction, patch: {
  type?: ManualType;
  source_account_profile_id?:string|null; affects_spending?:boolean;
  account_id?: string; from_account_id?: string; to_account_id?: string; amount_minor?: number; occurred_at?: string;
  category_code?: string; merchant?: string; note?: string;
}) => request<TransactionMutation>(session, `/transactions/${transaction.id}`, {
  method: 'PATCH', headers: { 'If-Match': `"${transaction.version}"` }, body: JSON.stringify(patch),
});

export const deleteTransaction = (session: Session, transaction: Transaction) =>
  request<{ deleted_transaction_id: string }>(session, `/transactions/${transaction.id}`, {
    method: 'DELETE', headers: { 'If-Match': `"${transaction.version}"` },
  });

export async function createWithKey<T>(session: Session, path: string, payload: unknown, ifMatchVersion?: number): Promise<T> {
  const fingerprint=ifMatchVersion===undefined?payload:{ifMatchVersion,payload};
  return withRequestIntent(session,path,fingerprint,key=>request<T>(session,path,{
    method:'POST',headers:{'Idempotency-Key':key,...(ifMatchVersion===undefined?{}:{'If-Match':`"${ifMatchVersion}"`})},body:JSON.stringify(payload),
  }));
}
export async function withRequestIntent<T>(session:Session,path:string,payload:unknown,send:(key:string)=>Promise<T>):Promise<T> {
  const identity = session.user?.id ?? 'unknown';
  const intentId = `sl-intent:${identity}:${path}`;
  const serialized = JSON.stringify(payload);
  const intentPayload = serialized;
  const previous = sessionStorage.getItem(intentId);
  let intent: { key: string; payload: string } | null = null;
  try { intent = previous ? JSON.parse(previous) : null; } catch { /* Corrupt local intent is ignored. */ }
  if (intent && intent.payload !== intentPayload) {
    throw new Error('上次保存结果尚不明确。请先刷新核对，再到“我的”明确取消旧操作。');
  }
  if (!intent) {
    intent = { key: crypto.randomUUID(), payload: intentPayload };
    sessionStorage.setItem(intentId, JSON.stringify(intent));
  }
  try {
    const result = await send(intent.key);
    sessionStorage.removeItem(intentId);
    return result;
  } catch (error) {
    // A definitive client rejection did not commit this intent. Network and server
    // failures keep the key so a retry cannot silently create a second operation.
    if (error instanceof ApiError && error.status < 500 && error.status!==401 && error.code !== 'REQUEST_IN_PROGRESS') {
      sessionStorage.removeItem(intentId);
    }
    throw error;
  }
}

export function pendingIntents(session: Session): number {
  const prefix = `sl-intent:${session.user?.id ?? 'unknown'}:`;
  let count = 0;
  for (let i = 0; i < sessionStorage.length; i++) {
    if (sessionStorage.key(i)?.startsWith(prefix)) count++;
  }
  return count;
}

export function clearUserIntent(session: Session): void {
  const prefix = `sl-intent:${session.user?.id ?? 'unknown'}:`;
  for (let i = sessionStorage.length - 1; i >= 0; i--) {
    const key = sessionStorage.key(i);
    if (key?.startsWith(prefix)) sessionStorage.removeItem(key);
  }
}
