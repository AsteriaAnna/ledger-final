export type Allocation = { fund_owner: 'self'; fund_type: 'liquid' | 'savings'; amount_minor: number };
export type Share = Allocation & { savings_baseline_minor: number | null; savings_gap_minor: number | null };

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
  custodian: 'self';
  opening_state: { opening_date: string; opening_balance_minor: number; opening_allocations: Allocation[] };
};

export function parseAccount(input: unknown): AccountInput {
  const bad = () => { throw new DomainError(422, 'VALIDATION_ERROR', '账户信息或初始份额不合法。'); };
  if (!object(input) || !allowed(input, ['name', 'account_type', 'custodian', 'opening_state'])) return bad();
  const opening = input.opening_state;
  if (!object(opening) || !allowed(opening, ['opening_date', 'opening_balance_minor', 'opening_allocations'])) return bad();
  if (typeof input.name !== 'string' || input.name.trim().length < 1 || input.name.length > 80 ||
    !accountTypes.has(String(input.account_type)) || (input.custodian !== undefined && input.custodian !== 'self') ||
    !validDate(opening.opening_date) || opening.opening_date > todayInShanghai() ||
    !cents(opening.opening_balance_minor, true) || !Array.isArray(opening.opening_allocations) ||
    opening.opening_allocations.length < 1 || opening.opening_allocations.length > 3) return bad();
  const allocations: Allocation[] = [];
  const seen = new Set<string>();
  for (const row of opening.opening_allocations) {
    if (!object(row) || !allowed(row, ['fund_owner', 'fund_type', 'amount_minor']) || row.fund_owner !== 'self' ||
      (row.fund_type !== 'liquid' && row.fund_type !== 'savings') || !cents(row.amount_minor, true) ||
      seen.has(row.fund_type)) return bad();
    seen.add(row.fund_type);
    allocations.push({ fund_owner: 'self', fund_type: row.fund_type, amount_minor: row.amount_minor });
  }
  if (allocations.reduce((sum, row) => sum + row.amount_minor, 0) !== opening.opening_balance_minor ||
    !Number.isSafeInteger(allocations.reduce((sum, row) => sum + row.amount_minor, 0))) return bad();
  return {
    name: input.name.trim(), account_type: input.account_type as string, custodian: 'self',
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

export function allocateExpense(shares: Share[], amount: number): { liquid: number; savings: number; notices: { code: string; amount_minor: number }[] } {
  if (!cents(amount)) throw new DomainError(422, 'VALIDATION_ERROR', '金额必须为正整数分。');
  const liquid = shares.find((row) => row.fund_owner === 'self' && row.fund_type === 'liquid')?.amount_minor ?? 0;
  const savings = shares.find((row) => row.fund_owner === 'self' && row.fund_type === 'savings')?.amount_minor ?? 0;
  if (amount > liquid + savings) throw new DomainError(409, 'INSUFFICIENT_FUNDS', '账户可用资金不足。');
  const useLiquid = Math.min(liquid, amount);
  const useSavings = amount - useLiquid;
  return { liquid: useLiquid, savings: useSavings, notices: useSavings ? [{ code: 'OWN_SAVINGS_USED', amount_minor: useSavings }] : [] };
}

export function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (object(value)) return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`;
  return JSON.stringify(value);
}
