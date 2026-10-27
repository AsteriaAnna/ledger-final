import assert from 'node:assert/strict';
import { test } from 'node:test';
import { allocateExpense, parseAccount, parseExpense, type Share } from '../src/domain/ledger.js';

test('opening allocations must equal the initial balance and cannot repeat a share', () => {
  const base = {
    name: '现金', account_type: 'cash',
    opening_state: { opening_date: '2026-10-01', opening_balance_minor: 10000,
      opening_allocations: [{ fund_owner: 'self', fund_type: 'liquid', amount_minor: 10000 }] },
  };
  assert.equal(parseAccount(base).opening_state.opening_balance_minor, 10000);
  assert.throws(() => parseAccount({ ...base, opening_state: { ...base.opening_state, opening_balance_minor: 10001 } }));
  assert.throws(() => parseAccount({ ...base, opening_state: { ...base.opening_state, opening_allocations: [base.opening_state.opening_allocations[0], base.opening_state.opening_allocations[0]] } }));
});

test('expense exhausts liquid funds before savings and refuses overdraft', () => {
  const shares: Share[] = [
    { fund_owner: 'self', fund_type: 'liquid', amount_minor: 1000, savings_baseline_minor: null, savings_gap_minor: null },
    { fund_owner: 'self', fund_type: 'savings', amount_minor: 5000, savings_baseline_minor: 5000, savings_gap_minor: 0 },
  ];
  assert.deepEqual(allocateExpense(shares, 2580), { liquid: 1000, savings: 1580,
    notices: [{ code: 'OWN_SAVINGS_USED', amount_minor: 1580 }] });
  assert.throws(() => allocateExpense(shares, 6001));
});

test('manual expense accepts only strict positive integer cents and no extra fields', () => {
  const base = { type: 'expense', account_id: 'account-a', amount_minor: 2580, occurred_at: '2026-10-20T12:30:00+08:00' };
  assert.equal(parseExpense(base).category_code, 'other');
  assert.throws(() => parseExpense({ ...base, amount_minor: 25.8 }));
  assert.throws(() => parseExpense({ ...base, user_id: 'forged' }));
});
