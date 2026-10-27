import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parseAccount, parseAccountPatch, parseExpense, parseExpensePatch,
  parseFundAdjustment } from '../src/domain/ledger.js';

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

test('opening supports three distinct shares but never partner liquid funds', () => {
  const input = { name: '三份额', account_type: 'cash', custodian: 'partner',
    opening_state: { opening_date: '2026-10-01', opening_balance_minor: 300,
      opening_allocations: [
        { fund_owner: 'self', fund_type: 'liquid', amount_minor: 100 },
        { fund_owner: 'self', fund_type: 'savings', amount_minor: 100 },
        { fund_owner: 'partner', fund_type: 'savings', amount_minor: 100 },
      ] } };
  assert.equal(parseAccount(input).opening_state.opening_allocations.length, 3);
  assert.throws(() => parseAccount({ ...input, opening_state: { ...input.opening_state,
    opening_allocations: [{ fund_owner: 'partner', fund_type: 'liquid', amount_minor: 300 }] } }));
});

test('manual expense accepts only strict positive integer cents and no extra fields', () => {
  const base = { type: 'expense', account_id: 'account-a', amount_minor: 2580, occurred_at: '2026-10-20T12:30:00+08:00' };
  assert.equal(parseExpense(base).category_code, 'other');
  assert.throws(() => parseExpense({ ...base, amount_minor: 25.8 }));
  assert.throws(() => parseExpense({ ...base, user_id: 'forged' }));
});

test('maintenance patches reject forged balances and invalid money', () => {
  assert.deepEqual(parseAccountPatch({ name: ' 新名称 ' }), { name: '新名称' });
  assert.throws(() => parseAccountPatch({ balance_minor: 1 }));
  assert.deepEqual(parseExpensePatch({ amount_minor: 1500, note: '' }), { amount_minor: 1500, note: '' });
  assert.throws(() => parseExpensePatch({ amount_minor: 1.5 }));
  assert.throws(() => parseExpensePatch({ source_account_profile_id: 'forged' }));
});

test('fund adjustment distinguishes savings owners and rejects illegal shares', () => {
  const input = { from: { fund_owner: 'self', fund_type: 'liquid' },
    to: { fund_owner: 'self', fund_type: 'savings' }, amount_minor: 1250 };
  assert.equal(parseFundAdjustment(input).amount_minor, 1250);
  assert.throws(() => parseFundAdjustment({ ...input, amount_minor: 0 }));
  assert.throws(() => parseFundAdjustment({ ...input, to: input.from }));
  assert.equal(parseFundAdjustment({ ...input, from: { fund_owner: 'partner', fund_type: 'savings' } }).from.fund_owner, 'partner');
  assert.throws(() => parseFundAdjustment({ ...input, from: { fund_owner: 'partner', fund_type: 'liquid' } }));
});
