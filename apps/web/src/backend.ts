import cloudbase from '@cloudbase/js-sdk';

const env = import.meta.env.VITE_CLOUDBASE_ENV_ID;
const accessKey = import.meta.env.VITE_PUBLISHABLE_KEY;
if (!env || !accessKey) throw new Error('CloudBase Web configuration is incomplete');

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
export type Transaction = {
  id: string; type: string; amount_minor: number; occurred_at: string; category_code: string;
  merchant: string; note: string; account_id: string; version: number;
};

type Session = { access_token: string; user?: { id?: string } };
export async function activeSession(): Promise<Session | null> {
  const { data, error } = await auth.getSession();
  if (error || !data?.session || data.session.user?.is_anonymous) return null;
  return data.session as Session;
}

async function request<T>(session: Session, path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`/api/v1${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${session.access_token}`, 'Content-Type': 'application/json', ...init?.headers },
  });
  const body = await response.json().catch(() => null);
  if (!response.ok) throw new Error(body?.message ?? `请求失败（${response.status}）`);
  return body.data as T;
}

export const getAccounts = async (session: Session) => request<Account[]>(session, '/accounts');
export const getTransactions = async (session: Session) => request<Transaction[]>(session, '/transactions');

export async function createWithKey<T>(session: Session, path: string, payload: unknown): Promise<T> {
  const identity = session.user?.id ?? 'unknown';
  const intentId = `sl-intent:${identity}:${path}`;
  const serialized = JSON.stringify(payload);
  const previous = sessionStorage.getItem(intentId);
  let intent: { key: string; payload: string } | null = null;
  try { intent = previous ? JSON.parse(previous) : null; } catch { /* Corrupt local intent is ignored. */ }
  if (intent && intent.payload !== serialized) {
    throw new Error('上次保存结果尚不明确。请先刷新核对，再到“我的”明确取消旧操作。');
  }
  if (!intent) {
    intent = { key: crypto.randomUUID(), payload: serialized };
    sessionStorage.setItem(intentId, JSON.stringify(intent));
  }
  const result = await request<T>(session, path, {
    method: 'POST', headers: { 'Idempotency-Key': intent.key }, body: serialized,
  });
  sessionStorage.removeItem(intentId);
  return result;
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
