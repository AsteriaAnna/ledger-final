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

export type AccountInput = {
  name: string;
  account_type: string;
  custodian: 'self' | 'partner';
  opening_state: { opening_date: string; opening_balance_minor: number; opening_allocations: Allocation[] };
};

export function parseAccount(input: unknown): AccountInput {
  const bad = () => { throw new DomainError(422, 'VALIDATION_ERROR', '账户信息或初始份额不合法。'); };
  if (!object(input) || !allowed(input, ['name', 'account_type', 'custodian', 'opening_state'])) return bad();
  const opening = input.opening_state;
  if (!object(opening) || !allowed(opening, ['opening_date', 'opening_balance_minor', 'opening_allocations'])) return bad();
  if (typeof input.name !== 'string' || input.name.trim().length < 1 || input.name.length > 80 ||
    !accountTypes.has(String(input.account_type)) ||
    (input.custodian !== undefined && input.custodian !== 'self' && input.custodian !== 'partner') ||
    !validDate(opening.opening_date) || opening.opening_date > todayInShanghai() ||
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
  if (allocations.reduce((sum, row) => sum + row.amount_minor, 0) !== opening.opening_balance_minor ||
    !Number.isSafeInteger(allocations.reduce((sum, row) => sum + row.amount_minor, 0))) return bad();
  return {
    name: input.name.trim(), account_type: input.account_type as string, custodian: input.custodian ?? 'self',
    opening_state: {
      opening_date: opening.opening_date,
      opening_balance_minor: opening.opening_balance_minor,
      opening_allocations: allocations,
    },
  };
}

export type ExpenseInput = {
  type: 'expense'; account_id: string; amount_minor: number; occurred_at: string;
  category_code: string; merchant: string; note: string;
};

export function parseExpense(input: unknown): ExpenseInput {
  const bad = () => { throw new DomainError(422, 'VALIDATION_ERROR', '支出信息不合法。'); };
  if (!object(input) || !allowed(input, ['type', 'account_id', 'amount_minor', 'occurred_at', 'category_code', 'merchant', 'note']) ||
    input.type !== 'expense' || typeof input.account_id !== 'string' || input.account_id.length < 1 ||
    !cents(input.amount_minor) || typeof input.occurred_at !== 'string' ||
    !/^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$/.test(input.occurred_at) ||
    Number.isNaN(Date.parse(input.occurred_at)) || Date.parse(input.occurred_at) > Date.now() ||
    (input.category_code !== undefined && !categories.has(String(input.category_code))) ||
    (input.merchant !== undefined && typeof input.merchant !== 'string') ||
    (input.note !== undefined && typeof input.note !== 'string')) return bad();
  return {
    type: 'expense', account_id: input.account_id, amount_minor: input.amount_minor,
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

export type ExpensePatch = {
  amount_minor?: number; occurred_at?: string; account_id?: string;
  category_code?: string; merchant?: string; note?: string;
};
export function parseExpensePatch(input: unknown): ExpensePatch {
  const bad = () => { throw new DomainError(422, 'VALIDATION_ERROR', '此版本只支持修改手动支出。'); };
  if (!object(input) || !allowed(input, ['type', 'amount_minor', 'occurred_at', 'account_id', 'category_code', 'merchant', 'note'])) return bad();
  if ('type' in input && input.type !== 'expense') return bad();
  const patch: ExpensePatch = {};
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
  if ('account_id' in input) {
    if (typeof input.account_id !== 'string' || !input.account_id) return bad();
    patch.account_id = input.account_id;
  }
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
