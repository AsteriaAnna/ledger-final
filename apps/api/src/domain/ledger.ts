export type ShareRef = { fund_owner: 'self'; fund_type: 'liquid' | 'savings' } |
  { fund_owner: 'partner'; fund_type: 'savings' };
export type Allocation = ShareRef & { amount_minor: number };

export class DomainError extends Error {
  constructor(public status: number, public code: string, message: string) { super(message); }
}

const accountTypes = new Set(['cash', 'bank_card', 'wechat_balance', 'alipay_balance', 'other']);
const categories = new Set(['food', 'shopping', 'transport', 'education', 'health', 'entertainment', 'utilities', 'other']);
const allowed = (value: Record<string, unknown>, keys: string[]) =>
  Object.keys(value).every((key) => keys.includes(key));
const object = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value);
const cents = (value: unknown, allowZero = false): value is number =>
  typeof value === 'number' && Number.isSafeInteger(value) && (allowZero ? value >= 0 : value > 0);

function shareRef(value: unknown): ShareRef | null {
  if (!object(value) || !allowed(value, ['fund_owner', 'fund_type'])) return null;
  if (value.fund_owner === 'self' && (value.fund_type === 'liquid' || value.fund_type === 'savings')) {
    return { fund_owner: 'self', fund_type: value.fund_type };
  }
  return value.fund_owner === 'partner' && value.fund_type === 'savings' ?
    { fund_owner: 'partner', fund_type: 'savings' } : null;
}

function todayInShanghai(): string {
  const parts = new Intl.DateTimeFormat('en-US', { timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(new Date());
  const value = Object.fromEntries(parts.map(({ type, value }) => [type, value]));
  return `${value.year}-${value.month}-${value.day}`;
}

function validDate(value: unknown): value is string {
  return typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value) &&
    !Number.isNaN(Date.parse(`${value}T00:00:00Z`)) &&
    new Date(`${value}T00:00:00Z`).toISOString().slice(0, 10) === value;
}

export type OpeningState = { opening_date: string; opening_balance_minor: number; opening_allocations: Allocation[] };

export function parseOpeningState(opening: unknown): OpeningState {
  const bad = () => { throw new DomainError(422, 'VALIDATION_ERROR', '初始状态或资金份额不合法。'); };
  if (!object(opening) || !allowed(opening, ['opening_date', 'opening_balance_minor', 'opening_allocations'])) return bad();
  if (!validDate(opening.opening_date) || opening.opening_date > todayInShanghai() ||
    !cents(opening.opening_balance_minor, true) || !Array.isArray(opening.opening_allocations) ||
    opening.opening_allocations.length < 1 || opening.opening_allocations.length > 3) return bad();
  const allocations: Allocation[] = [];
  const seen = new Set<string>();
  for (const row of opening.opening_allocations) {
    if (!object(row) || !allowed(row, ['fund_owner', 'fund_type', 'amount_minor']) || !cents(row.amount_minor, true)) return bad();
    const ref = shareRef({ fund_owner: row.fund_owner, fund_type: row.fund_type });
    if (!ref || seen.has(`${ref.fund_owner}:${ref.fund_type}`)) return bad();
    seen.add(`${ref.fund_owner}:${ref.fund_type}`);
    allocations.push({ ...ref, amount_minor: row.amount_minor });
  }
  const total = allocations.reduce((sum, row) => sum + row.amount_minor, 0);
  if (total !== opening.opening_balance_minor || !Number.isSafeInteger(total)) return bad();
  const rank = (row: Allocation) => row.fund_owner === 'partner' ? 2 : row.fund_type === 'savings' ? 1 : 0;
  return { opening_date: opening.opening_date, opening_balance_minor: total,
    opening_allocations: allocations.sort((a, b) => rank(a) - rank(b)) };
}

export type AccountInput = {
  name: string; account_type: string; custodian: 'self' | 'partner'; opening_state: OpeningState;
};

export function parseAccount(input: unknown): AccountInput {
  const bad = () => { throw new DomainError(422, 'VALIDATION_ERROR', '账户信息不合法。'); };
  if (!object(input) || !allowed(input, ['name', 'account_type', 'custodian', 'opening_state']) ||
    typeof input.name !== 'string' || input.name.trim().length < 1 || input.name.length > 80 ||
    !accountTypes.has(String(input.account_type)) ||
    (input.custodian !== undefined && input.custodian !== 'self' && input.custodian !== 'partner')) return bad();
  return {
    name: input.name.trim(), account_type: input.account_type as string, custodian: input.custodian ?? 'self',
    opening_state: parseOpeningState(input.opening_state),
  };
}

export type ManualTransactionInput = ({ type: 'income' | 'expense'; account_id: string } |
  { type: 'transfer'; from_account_id: string; to_account_id: string }) & {
  amount_minor: number; occurred_at: string;
  category_code: string; merchant: string; note: string;
};

export function parseManualTransaction(input: unknown): ManualTransactionInput {
  const bad = () => { throw new DomainError(422, 'VALIDATION_ERROR', '收入、支出或转账内容不合法，请检查账户与金额。'); };
  if (!object(input) || !allowed(input, ['type', 'account_id', 'from_account_id', 'to_account_id', 'amount_minor', 'occurred_at', 'category_code', 'merchant', 'note']) ||
    (input.type !== 'expense' && input.type !== 'income' && input.type !== 'transfer') ||
    !cents(input.amount_minor) || typeof input.occurred_at !== 'string' ||
    !/^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$/.test(input.occurred_at) ||
    Number.isNaN(Date.parse(input.occurred_at)) || Date.parse(input.occurred_at) > Date.now() ||
    (input.category_code !== undefined && !categories.has(String(input.category_code))) ||
    (input.merchant !== undefined && typeof input.merchant !== 'string') ||
    (input.note !== undefined && typeof input.note !== 'string')) return bad();
  let accounts: { type: 'income' | 'expense'; account_id: string } |
    { type: 'transfer'; from_account_id: string; to_account_id: string };
  if (input.type === 'transfer') {
    if ('account_id' in input || typeof input.from_account_id !== 'string' || !input.from_account_id ||
      typeof input.to_account_id !== 'string' || !input.to_account_id || input.from_account_id === input.to_account_id) return bad();
    accounts = { type: 'transfer', from_account_id: input.from_account_id, to_account_id: input.to_account_id };
  } else {
    if ('from_account_id' in input || 'to_account_id' in input || typeof input.account_id !== 'string' || !input.account_id) return bad();
    accounts = { type: input.type, account_id: input.account_id };
  }
  return {
    ...accounts, amount_minor: input.amount_minor,
    occurred_at: input.occurred_at, category_code: (input.category_code as string | undefined) ?? 'other',
    merchant: (input.merchant as string | undefined) ?? '', note: (input.note as string | undefined) ?? '',
  };
}

export type AccountPatch = { name?: string; account_type?: string; custodian?: 'self' | 'partner' };
export function parseAccountPatch(input: unknown): AccountPatch {
  const bad = () => { throw new DomainError(422, 'VALIDATION_ERROR', '账户修改内容不合法。'); };
  if (!object(input) || !allowed(input, ['name', 'account_type', 'custodian'])) return bad();
  const patch: AccountPatch = {};
  if ('name' in input) {
    if (typeof input.name !== 'string' || input.name.trim().length < 1 || input.name.length > 80) return bad();
    patch.name = input.name.trim();
  }
  if ('account_type' in input) {
    if (!accountTypes.has(String(input.account_type))) return bad();
    patch.account_type = input.account_type as string;
  }
  if ('custodian' in input) {
    if (input.custodian !== 'self' && input.custodian !== 'partner') return bad();
    patch.custodian = input.custodian;
  }
  return patch;
}

export type FundAdjustment = {
  from: ShareRef;
  to: ShareRef;
  amount_minor: number;
};

export function parseFundAdjustment(input: unknown): FundAdjustment {
  const bad = () => { throw new DomainError(422, 'VALIDATION_ERROR', '资金调整内容不合法。'); };
  if (!object(input) || !allowed(input, ['from', 'to', 'amount_minor']) || !cents(input.amount_minor)) return bad();
  const from = shareRef(input.from), to = shareRef(input.to);
  if (!from || !to || (from.fund_owner === to.fund_owner && from.fund_type === to.fund_type)) return bad();
  return { from, to, amount_minor: input.amount_minor };
}

export type ManualTransactionPatch = {
  type?: 'income' | 'expense' | 'transfer'; source_account_profile_id?: null;
  from_account_id?: string; to_account_id?: string;
  amount_minor?: number; occurred_at?: string; account_id?: string;
  category_code?: string; merchant?: string; note?: string;
};
export function parseManualTransactionPatch(input: unknown): ManualTransactionPatch {
  const bad = () => { throw new DomainError(422, 'VALIDATION_ERROR', '账单修改内容不合法。'); };
  if (!object(input) || !allowed(input, ['type', 'amount_minor', 'occurred_at', 'account_id', 'from_account_id', 'to_account_id', 'category_code', 'merchant', 'note', 'source_account_profile_id'])) return bad();
  if ('type' in input && input.type !== 'expense' && input.type !== 'income' && input.type !== 'transfer') return bad();
  const patch: ManualTransactionPatch = {};
  if (input.type === 'income' || input.type === 'expense' || input.type === 'transfer') patch.type = input.type;
  if ('source_account_profile_id' in input) {
    if (input.source_account_profile_id !== null) return bad();
    patch.source_account_profile_id = null;
  }
  if ('amount_minor' in input) {
    if (!cents(input.amount_minor)) return bad();
    patch.amount_minor = input.amount_minor;
  }
  if ('occurred_at' in input) {
    if (typeof input.occurred_at !== 'string' ||
      !/^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$/.test(input.occurred_at) ||
      Number.isNaN(Date.parse(input.occurred_at)) || Date.parse(input.occurred_at) > Date.now()) return bad();
    patch.occurred_at = input.occurred_at;
  }
  for (const field of ['account_id', 'from_account_id', 'to_account_id'] as const) {
    if (field in input) {
      if (typeof input[field] !== 'string' || !input[field]) return bad();
      patch[field] = input[field];
    }
  }
  if (('account_id' in patch && ('from_account_id' in patch || 'to_account_id' in patch)) ||
    (patch.type === 'transfer' && 'account_id' in patch) ||
    ((patch.type === 'income' || patch.type === 'expense') && ('from_account_id' in patch || 'to_account_id' in patch)) ||
    (patch.from_account_id !== undefined && patch.from_account_id === patch.to_account_id)) return bad();
  if ('category_code' in input) {
    if (!categories.has(String(input.category_code))) return bad();
    patch.category_code = input.category_code as string;
  }
  for (const field of ['merchant', 'note'] as const) {
    if (field in input) {
      if (typeof input[field] !== 'string') return bad();
      patch[field] = input[field];
    }
  }
  return patch;
}

export function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (object(value)) return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`;
  return JSON.stringify(value);
}
