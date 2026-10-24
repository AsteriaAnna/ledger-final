"""Executable design reference, not a server or production importer.
Run with --wechat FILE --alipay FILE [--report PRIVATE.md].
Requires openpyxl. Real files/reports stay outside this repository.
"""
import argparse
import calendar
import json
from collections import Counter
from copy import deepcopy
from datetime import datetime, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path
import re
import openpyxl

TZ = timezone(timedelta(hours=8))
NOW = datetime(2026, 10, 24, 23, 59, tzinfo=TZ)  # Injected validation clock.
SHARES = ('liquid', 'own_savings', 'partner_savings')
DISPOSITIONS = ('created', 'linked_existing', 'duplicate_existing', 'unsupported',
                'ineffective', 'needs_review', 'failed')
CATEGORIES = {'餐饮美食': 'food', '日用百货': 'shopping', '服饰装扮': 'shopping',
              '家居家装': 'shopping', '数码电器': 'shopping', '交通出行': 'transport',
              '教育培训': 'education', '医疗健康': 'health', '文化休闲': 'entertainment',
              '运动户外': 'entertainment', '充值缴费': 'utilities'}


class RuleError(Exception):
    pass


def require(condition, code):
    if not condition:
        raise RuleError(code)


def amount(value):
    require(not isinstance(value, bool), 'VALIDATION_ERROR')
    n = Decimal(str(value).strip()) * 100
    require(n.is_finite() and n == n.to_integral_value() and n > 0, 'VALIDATION_ERROR')
    return int(n)


def aware(value):
    d = value if isinstance(value, datetime) else datetime.fromisoformat(str(value).strip())
    return (d.replace(tzinfo=TZ) if d.tzinfo is None else d.astimezone(TZ))


def atomic(fn):
    def call(self, *args, **kwargs):
        snapshot = deepcopy(self.__dict__)
        try:
            return fn(self, *args, **kwargs)
        except Exception:
            self.__dict__.clear()
            self.__dict__.update(snapshot)
            raise
    return call


class Ledger:
    """In-memory rule reference: no persistence, HTTP, authentication or concurrency proof."""
    def __init__(self):
        self.accounts = {}
        self.transactions = {}
        self.next_id = 1

    def account(self, key, owner, shares, opening='2026-01-01'):
        require(len(shares) == 3 and all(isinstance(x, int) and x >= 0 for x in shares), 'VALIDATION_ERROR')
        self.accounts[key] = dict(owner=owner, shares=list(shares), baseline=list(shares), opening=opening, opening_shares=list(shares))

    def access(self, user, keys):
        require(all(k in self.accounts and self.accounts[k]['owner'] == user for k in keys), 'FORBIDDEN')

    def invariant(self):
        require(all(all(v >= 0 for v in a['shares']) for a in self.accounts.values()), 'FUNDS_ALLOCATION_NOT_POSSIBLE')
        for t in self.transactions.values():
            for key, plan in t['plans'].items():
                expected = t['amount'] * (-1 if t['type'] == 'expense' or
                           (t['type'] == 'transfer' and key == t['accounts'][0]) else 1)
                require(sum(plan) == expected, 'EFFECT_NOT_CONSERVED')

    @atomic
    def adjust(self, user, key, from_share, to_share, n):
        self.access(user, [key]); require(n > 0 and from_share in range(3) and to_share in range(3) and from_share != to_share, 'VALIDATION_ERROR')
        a = self.accounts[key]
        a['shares'][from_share] -= n; a['shares'][to_share] += n
        a['baseline'][from_share] -= n; a['baseline'][to_share] += n
        self.invariant()

    def allocation(self, key, n, mode):
        a = self.accounts[key]; plan = [0, 0, 0]
        if mode == 'debit':
            left = n
            for i in range(3):
                take = min(left, a['shares'][i]); plan[i] = -take; left -= take
            require(left == 0, 'FUNDS_ALLOCATION_NOT_POSSIBLE')
        elif mode == 'refund':
            left = n
            for i in (2, 1):
                take = min(left, max(a['baseline'][i] - a['shares'][i], 0))
                plan[i] = take; left -= take
            plan[0] = left
        else:
            plan[0] = n
        return plan

    def plans(self, t):
        result = {}
        for index, key in enumerate(t['accounts']):
            if t['when'].date().isoformat() < self.accounts[key]['opening']:
                continue
            if t['type'] == 'transfer':
                plan = [-t['amount'], 0, 0] if index == 0 else [t['amount'], 0, 0]
            else:
                mode = 'debit' if t['type'] == 'expense' else 'refund' if t['type'] == 'refund' else 'income'
                plan = self.allocation(key, t['amount'], mode)
            result[key] = plan
        return result

    def apply(self, plans, sign=1):
        for key, plan in plans.items():
            self.accounts[key]['shares'] = [v + sign * d for v, d in zip(self.accounts[key]['shares'], plan)]
        self.invariant()

    @atomic
    def create(self, user, kind, n, when, keys, official=False, refund_kind=None, affects=None):
        self.access(user, keys)
        require(kind in ('expense', 'income', 'transfer', 'refund') and type(n) is int and n > 0, 'VALIDATION_ERROR')
        require(when.tzinfo is not None and when <= NOW, 'VALIDATION_ERROR')
        require(len(keys) == (2 if kind == 'transfer' else 1) and len(set(keys)) == len(keys), 'VALIDATION_ERROR')
        if kind == 'refund':
            require(official, 'REFUND_REQUIRES_OFFICIAL_SOURCE')
            require(refund_kind in ('merchant_refund', 'transfer_return') and type(affects) is bool, 'VALIDATION_ERROR')
        else:
            require(refund_kind is None and affects is None, 'VALIDATION_ERROR')
        t = dict(owner=user, type=kind, amount=n, when=when, accounts=list(keys),
                 refund_kind=refund_kind, affects=affects, official=official, version=1, plans={})
        t['plans'] = self.plans(t); self.apply(t['plans'])
        key = f't{self.next_id}'; self.next_id += 1
        self.transactions[key] = t; self.invariant()
        return key

    @atomic
    def edit(self, user, key, version, **changes):
        require(key in self.transactions and self.transactions[key]['owner'] == user, 'FORBIDDEN')
        t = self.transactions[key]
        require(version == t['version'], 'RESOURCE_VERSION_CONFLICT')
        require(set(changes) <= {'amount', 'when', 'accounts', 'affects'}, 'VALIDATION_ERROR')
        proposed = deepcopy(t); proposed.update(changes)
        require(type(proposed['amount']) is int and proposed['amount'] > 0 and proposed['when'].tzinfo is not None and proposed['when'] <= NOW, 'VALIDATION_ERROR')
        self.access(user, proposed['accounts'])
        require(len(proposed['accounts']) == len(t['accounts']) and len(set(proposed['accounts'])) == len(t['accounts']), 'VALIDATION_ERROR')
        if 'affects' in changes:
            require(t['type'] == 'refund' and type(changes['affects']) is bool, 'VALIDATION_ERROR')
        if all(proposed[field] == t[field] for field in changes):
            return  # Validated no-op: no new version or allocation.
        financial = 'amount' in changes or 'accounts' in changes
        before_active = {k for k in t['accounts'] if t['when'].date().isoformat() >= self.accounts[k]['opening']}
        after_active = {k for k in proposed['accounts'] if proposed['when'].date().isoformat() >= self.accounts[k]['opening']}
        if financial or before_active != after_active:
            if t['type'] == 'expense' and set(changes) <= {'amount'}:
                delta = proposed['amount'] - t['amount']
                plans = deepcopy(t['plans'])
                for a in before_active:
                    extra = self.allocation(a, abs(delta), 'debit' if delta > 0 else 'refund')
                    self.apply({a: extra})
                    plans[a] = [x+y for x, y in zip(plans[a], extra)]
                proposed['plans'] = plans
            else:
                self.apply(t['plans'], -1)
                proposed['plans'] = self.plans(proposed); self.apply(proposed['plans'])
        proposed['version'] += 1
        self.transactions[key] = proposed; self.invariant()

    @atomic
    def delete(self, user, key):
        require(key in self.transactions and self.transactions[key]['owner'] == user, 'FORBIDDEN')
        self.apply(self.transactions[key]['plans'], -1)
        del self.transactions[key]; self.invariant()

    @atomic
    def change_type(self, user, key, version, kind, accounts):
        require(key in self.transactions and self.transactions[key]['owner'] == user, 'FORBIDDEN')
        old=self.transactions[key]
        require(old['version']==version,'RESOURCE_VERSION_CONFLICT')
        require(old['type']!='refund' and kind in ('income','expense','transfer'),'VALIDATION_ERROR')
        self.access(user,accounts)
        require(len(accounts)==(2 if kind=='transfer' else 1) and len(set(accounts))==len(accounts),'VALIDATION_ERROR')
        self.apply(old['plans'],-1)
        updated=deepcopy(old);updated.update(type=kind,accounts=list(accounts),plans={},version=version+1)
        updated['plans']=self.plans(updated);self.apply(updated['plans'])
        self.transactions[key]=updated;self.invariant()

    @atomic
    def opening_state(self,user,key,opening,shares):
        self.access(user,[key]);a=self.accounts[key]
        require(aware(opening)<=NOW and len(shares)==3 and all(type(v) is int and v>=0 for v in shares),'VALIDATION_ERROR')
        # This compact reference has no chronological manual-adjustment journal.
        # Reject that unrepresented reconstruction rather than fabricate one.
        require(a['baseline']==a['opening_shares'],'OPENING_STATE_RECALCULATION_CONFLICT')
        a.update(opening=opening,opening_shares=list(shares),baseline=list(shares),shares=list(shares))
        try:
            for tid,t in sorted(self.transactions.items(),key=lambda item:(item[1]['when'],item[0])):
                if key not in t['accounts']:
                    continue
                t['plans'].pop(key,None)
                if t['when'].date().isoformat()>=opening:
                    plan=self.plans(t)[key]
                    self.apply({key:plan});t['plans'][key]=plan
            self.invariant()
        except RuleError:
            raise RuleError('OPENING_STATE_RECALCULATION_CONFLICT')


def structure_complete(batch, rows):
    return (batch['export_type'] == 'all_transactions' and len(rows)==batch['declared_count'] and
        len({r['official_transaction_id'] for r in rows})==len(rows) and
        batch['declared_from'] <= batch['effective_to'] and
        all(r['disposition'] != 'failed' and r['official_transaction_id'] and
            batch['declared_from'] <= r.get('source_occurred_at',NOW) <= batch['effective_to'] for r in rows))


def parse_file(path):
    values = list(openpyxl.load_workbook(path, data_only=True).active.values)
    title = ' '.join(str(x) for row in values[:18] for x in row if x is not None)
    platform = 'wechat' if '微信支付' in title else 'alipay' if '支付宝' in title else None
    require(platform is not None, 'UNSUPPORTED_SOURCE_FILE')
    wx = platform == 'wechat'
    h = next(i for i, r in enumerate(values) if '交易时间' in r and ('交易类型' if wx else '交易分类') in r)
    metadata = '\n'.join(str(x) for row in values[:h] for x in row if x is not None)
    dates = re.search(r'起始时间：\[([^]]+)\].*?终止时间：\[([^]]+)\]', metadata)
    exported = re.search(r'导出时间：\[([^]]+)\]', metadata)
    count = re.search(r'共\s*(\d+)\s*笔记录', metadata)
    require(bool(dates and exported and count), 'INVALID_SOURCE_FIELDS')
    batch = dict(platform=platform, declared_from=aware(dates[1]), declared_to=aware(dates[2]),
                 exported_at=aware(exported[1]), declared_count=int(count[1]),
                 export_type='all_transactions' if ('全部账单' in metadata or '[全部]' in metadata) else 'partial',
                 raw_metadata=metadata)
    rows = []
    for line, values_row in enumerate(values[h+1:], h+2):
        if all(x is None for x in values_row):
            continue
        raw = {k: v for k, v in zip(values[h], values_row) if k is not None}
        v = {k: '' if x is None else str(x).strip() for k, x in raw.items()}
        kind = v['交易类型' if wx else '交易分类']; status = v['当前状态' if wx else '交易状态']
        method = v['支付方式' if wx else '收/付款方式']; desc = v['商品' if wx else '商品说明']
        sid = re.sub(r'(?:\\t|\s)+$', '', v['交易单号' if wx else '交易订单号'])
        row = dict(platform=platform, row=line, raw_fields=raw, official_transaction_id=sid,
                   source_kind=kind, source_status=status, source_direction=v['收/支'],
                   source_note=v['备注'], merchant_order_id=v['商户单号' if wx else '商家订单号'],
                   counterparty=v['交易对方'], description=desc,
                   counterparty_account=v.get('对方账号'), raw_method=method, refund_kind=None,
                   affects_spending=None, keys=[], accounts=[], type=None, accounting_semantics=None,
                   category_code=CATEGORIES.get(kind, 'other'), reason=None, disposition=None)
        try:
            row['amount_minor'] = amount(raw['金额(元)' if wx else '金额'])
            row['source_occurred_at'] = aware(raw['交易时间'])
            require(sid and row['source_occurred_at'] <= batch['exported_at'], 'INVALID_SOURCE_FIELDS')
        except (ValueError, RuleError, ArithmeticError):
            row.update(disposition='failed', reason='INVALID_SOURCE_FIELDS'); rows.append(row); continue
        row['occurred_at'] = row['source_occurred_at']
        tokens = method.split('&'); row['discount_tags'] = [x for x in tokens if '红包' in x]
        key = '&'.join(x for x in tokens if '红包' not in x)
        if status == '已存入零钱':
            if key not in ('', '/', '零钱'):
                row.update(disposition='needs_review', reason='ACCOUNT_EVIDENCE_CONFLICT')
            key = '微信零钱'
        elif key == '零钱':
            key = '微信零钱'
        row['keys'] = [key] if key not in ('', '/') else []
        row['account_evidence'] = '当前状态=已存入零钱' if status == '已存入零钱' else '渠道剥离优惠'
        if '亲情卡' in method or any('花呗' in str(x) or '信用卡' in str(x) for x in (method, desc, v['交易对方'])):
            row.update(disposition='unsupported', reason='UNSUPPORTED_PAYMENT_METHOD')
        elif any(x in status for x in ('失败', '关闭')):
            row.update(disposition='ineffective')
        else:
            known = (status in {'支付成功','已存入零钱','对方已收钱','已全额退款','对方已退还','充值完成','提现已到账','已收钱','已转账'} or bool(re.fullmatch(r'已退款\(?¥[\d.]+\)?', status))) if wx else status in {'交易成功','等待确认收货','退款成功'}
            if not known:
                row.update(disposition='needs_review', reason='UNKNOWN_SOURCE_STATE')
            elif ('退款' in kind if wx else status == '退款成功'):
                row['type'] = 'refund'; row['accounting_semantics'] = 'refund_inflow'
                row['refund_kind'] = 'transfer_return' if kind == '转账-退款' else 'merchant_refund'
                row['affects_spending'] = row['refund_kind'] == 'merchant_refund'
            elif wx and kind in ('零钱充值', '零钱提现'):
                fee = re.search(r'服务费¥([\d.]+)', v['备注'])
                fee_minor = int(Decimal(fee[1])*100) if fee else None
                row['fee_hint_minor'] = fee_minor
                if kind == '零钱提现' and fee_minor != 0:
                    row.update(disposition='unsupported', reason='TRANSFER_FEE_UNSUPPORTED')
                else:
                    row['type'] = 'transfer'; row['accounting_semantics'] = 'internal_transfer'
                    row['keys'] = [key, '微信零钱'] if kind == '零钱充值' else ['微信零钱', key]
            elif wx and kind == '转账':
                row.update(disposition='needs_review', reason='TRANSFER_ROLE_REQUIRED')
            else:
                row['type'] = {'收入':'income','支出':'expense'}.get(v['收/支'])
                row['accounting_semantics'] = 'ordinary'
                if row['type'] is None:
                    row.update(disposition='needs_review', reason='INVALID_SOURCE_FIELDS')
        rows.append(row)
    batch['effective_to'] = min(batch['declared_to'], batch['exported_at'])
    batch['structural_complete'] = structure_complete(batch,rows)
    batch['rows'] = rows
    return batch


class ImportReference:
    def __init__(self, ledger, user='self'):
        self.ledger = ledger; self.user = user; self.sources = {}; self.observations = []
        self.mapping = {}; self.requests = {}; self.bind_failure = False; self.profiles = {}

    def profile(self, key, owner='self'):
        self.profiles[key] = owner

    def profile_access(self, profile):
        require(self.profiles.get(profile) == self.user, 'FORBIDDEN')

    def map(self, profile, key, account):
        self.profile_access(profile)
        if key in ('微信零钱', '支付宝余额'):
            require(not any(p != profile and k == key and a == account for (p,k),a in self.mapping.items()), 'ACCOUNT_EVIDENCE_CONFLICT')
        self.ledger.access(self.user, [account]); self.mapping[(profile, key)] = account

    def transfer_role(self, row, kind, keys):
        require(row['reason'] == 'TRANSFER_ROLE_REQUIRED' and kind in ('income','expense','transfer'), 'VALIDATION_ERROR')
        incoming = row['source_direction'] == '收入'
        require(kind == 'transfer' or kind == ('income' if incoming else 'expense'), 'VALIDATION_ERROR')
        require(len(keys) == (2 if kind == 'transfer' else 1), 'VALIDATION_ERROR')
        if row['keys']:
            require(keys[-1 if incoming and kind == 'transfer' else 0] == row['keys'][0], 'ACCOUNT_EVIDENCE_CONFLICT')
        r=deepcopy(row);r.update(type=kind,keys=keys,accounting_semantics='internal_transfer' if kind=='transfer' else 'ordinary',disposition=None,reason=None)
        return r

    def link(self, profile, row, tid):
        self.profile_access(profile)
        require(tid in self.ledger.transactions and self.ledger.transactions[tid]['owner'] == self.user, 'FORBIDDEN')
        require(row['disposition'] not in ('unsupported','ineffective','failed'), 'VALIDATION_ERROR')
        t=self.ledger.transactions[tid]; accounts=[self.mapping.get((profile,k)) for k in row['keys']]
        require(t['type'] == row['type'] and t['amount'] == row['amount_minor'] and t['accounts'] == accounts, 'VALIDATION_ERROR')
        key=(profile,row['official_transaction_id'])
        require(key in self.sources and self.sources[key]['transaction'] in (None,tid), 'VALIDATION_ERROR')
        self.sources[key]['transaction']=tid
        return dict(row,disposition='linked_existing',transaction_id=tid)

    def fact(self, row):
        return (row.get('amount_minor'), row.get('source_occurred_at'), row['source_kind'], row['source_direction'], row['raw_method'])

    def one(self, profile, row, exported, confirm_new=False):
        r = deepcopy(row); key = (profile, r['official_transaction_id'])
        self.observations.append((key, exported, deepcopy(r['raw_fields'])))
        if r['disposition'] == 'failed':
            return dict(r,transaction_id=None)
        previous = self.sources.get(key)
        if previous and exported < previous['exported']:
            r = deepcopy(previous['row'])  # Process latest fact, never the stale payload.
        elif previous and exported == previous['exported'] and self.fact(r) != self.fact(previous['row']):
            return dict(r, disposition='needs_review', reason='SOURCE_FACT_CONFLICT', transaction_id=previous['transaction'])
        if previous and r['reason'] == 'TRANSFER_ROLE_REQUIRED' and previous['row']['type'] in ('income','expense','transfer'):
            prior=previous['row']
            r=self.transfer_role(r,prior['type'],prior['keys'])
        if previous and previous['transaction'] in self.ledger.transactions:
            if self.fact(r) != self.fact(previous['row']) or r['disposition'] in ('ineffective','unsupported','needs_review'):
                return dict(r, disposition='needs_review', reason='SOURCE_FACT_CONFLICT', transaction_id=previous['transaction'])
            previous['row'] = deepcopy(r); previous['exported'] = max(exported, previous['exported'])
            return dict(r, disposition='duplicate_existing', transaction_id=previous['transaction'])
        self.sources[key] = dict(row=deepcopy(r), exported=max(exported, previous['exported']) if previous else exported, transaction=None)
        if r['disposition'] in ('unsupported','ineffective','failed','needs_review'):
            return dict(r, transaction_id=None)
        accounts = [self.mapping.get((profile, k)) for k in r['keys']]
        if not accounts or any(a is None for a in accounts):
            return dict(r, disposition='needs_review', reason='SOURCE_MAPPING_REQUIRED', transaction_id=None)
        r['accounts'] = accounts
        candidates = [tid for tid,t in self.ledger.transactions.items() if
                      t['when'].date() == r['occurred_at'].date() and t['type'] == r['type'] and
                      t['amount'] == r['amount_minor'] and t['accounts'] == accounts]
        if candidates and not confirm_new:
            return dict(r, disposition='needs_review', reason='POSSIBLE_EXISTING_TRANSACTION', candidates=candidates, transaction_id=None)
        snapshot = deepcopy(self.ledger.__dict__)
        try:
            tid = self.ledger.create(self.user, r['type'], r['amount_minor'], r['occurred_at'], accounts,
                                     official=True, refund_kind=r['refund_kind'], affects=r['affects_spending'])
            require(not self.bind_failure, 'SIMULATED_BIND_FAILURE')
            self.sources[key]['transaction'] = tid
        except RuleError as e:
            self.ledger.__dict__.clear(); self.ledger.__dict__.update(snapshot)
            return dict(r, disposition='failed', reason=str(e), transaction_id=None)
        return dict(r, disposition='created', transaction_id=tid)

    def batch(self, profile, batch, request_key):
        self.profile_access(profile)
        fingerprint = (profile, batch['exported_at'], tuple((r['official_transaction_id'], str(self.fact(r)), r['source_status']) for r in batch['rows']))
        if request_key in self.requests:
            previous, result = self.requests[request_key]
            require(previous == fingerprint, 'IDEMPOTENCY_KEY_CONFLICT')
            return deepcopy(result)
        results = [self.one(profile, r, batch['exported_at']) for r in sorted(batch['rows'], key=lambda r:(r.get('occurred_at', NOW), r['official_transaction_id']))]
        counts = {d: sum(r['disposition'] == d for r in results) for d in DISPOSITIONS}
        require(sum(counts.values()) == len(batch['rows']), 'ROW_COUNT_NOT_CONSERVED')
        result = dict(rows=results, summary=counts, reconciliation_eligible=batch['structural_complete'] and not any(counts[d] for d in ('unsupported','needs_review','failed')))
        self.requests[request_key] = (fingerprint, deepcopy(result))
        return result


def stats(transactions, month, budget, now=NOW):
    y,m = map(int, month.split('-')); require((y,m) <= (now.year,now.month), 'VALIDATION_ERROR')
    days = now.day if (y,m) == (now.year,now.month) else calendar.monthrange(y,m)[1]
    selected = [t for t in transactions if t['when'].strftime('%Y-%m') == month and t['when'] <= now]
    expense = sum(t['amount'] for t in selected if t['type'] == 'expense')
    refunds = sum(t['amount'] for t in selected if t['type'] == 'refund' and t['affects'])
    net = expense-refunds
    rounded = lambda n: int(Decimal(n).quantize(Decimal('1'), rounding=ROUND_HALF_UP))
    return dict(expense=expense, refund_offset=refunds, net=net,
                daily=rounded(Decimal(net)/days), projected=rounded(Decimal(net)/days*calendar.monthrange(y,m)[1]),
                remaining=max(budget-net,0), over=max(net-budget,0))


def eligible_manual(t, batch, result, profile, explicit_profile=None, wallet_profile=None, has_source=False):
    return (result['reconciliation_eligible'] and not t['official'] and not has_source and
            (explicit_profile or wallet_profile) == profile and
            batch['declared_from'] <= t['when'] <= batch['effective_to'])


def reference_pilot_body(payload, patch=False, compare_version=None):
    """Trial request validation only, not HTTP or a production capability switch.
    Version behavior must be selected explicitly for a proposed PATCH scenario.
    """
    require(type(payload) is dict, 'VALIDATION_ERROR')
    if patch:
        require(type(compare_version) is bool, 'PILOT_DECISION_REQUIRED')
        allowed={'version','occurred_at','affects_spending','amount_minor','account_id','category_code','merchant','note'}
        required={'version'} if compare_version else set()
        if not compare_version:
            allowed.remove('version')
    else:
        require(payload.get('type') != 'refund', 'REFUND_REQUIRES_OFFICIAL_SOURCE')
        allowed={'type','accounting_semantics','amount_minor','occurred_at','account_id','from_account_id','to_account_id','category_code','merchant','note','source_account_profile_id'}
        required={'type','accounting_semantics','amount_minor','occurred_at'}
    require(set(payload)<=allowed and required<=set(payload), 'VALIDATION_ERROR')
    r=deepcopy(payload)
    for field in ('amount_minor','version'):
        if field in r:
            require(type(r[field]) is int and r[field]>0, 'VALIDATION_ERROR')
    for field in ('account_id','from_account_id','to_account_id','source_account_profile_id','category_code','merchant','note'):
        if field in r:
            require(type(r[field]) is str, 'VALIDATION_ERROR')
            if field not in ('merchant','note'):
                require(bool(r[field]), 'VALIDATION_ERROR')
    if 'category_code' in r:
        require(r['category_code'] in set(CATEGORIES.values())|{'other'},'VALIDATION_ERROR')
    if 'affects_spending' in r:
        require(type(r['affects_spending']) is bool,'VALIDATION_ERROR')
    if 'occurred_at' in r:
        require(type(r['occurred_at']) is str, 'VALIDATION_ERROR')
        try:
            stamp=datetime.fromisoformat(r['occurred_at'])
        except ValueError:
            raise RuleError('VALIDATION_ERROR')
        require(stamp.tzinfo is not None and stamp<=NOW,'VALIDATION_ERROR')
        r['occurred_at']=stamp.astimezone(TZ)
    if not patch:
        kind=r['type']
        require(kind in ('income','expense','transfer'),'VALIDATION_ERROR')
        require(r['accounting_semantics']==('internal_transfer' if kind=='transfer' else 'ordinary'),'VALIDATION_ERROR')
        accounts={'from_account_id','to_account_id'} if kind=='transfer' else {'account_id'}
        forbidden={'account_id'} if kind=='transfer' else {'from_account_id','to_account_id'}
        require(accounts<=set(r) and not forbidden&set(r),'VALIDATION_ERROR')
        if kind=='transfer':
            require(r['from_account_id']!=r['to_account_id'],'VALIDATION_ERROR')
        r.setdefault('category_code','other');r.setdefault('merchant','');r.setdefault('note','')
    return r


def validate(wechat, alipay):
    tests=[]
    def check(name, condition):
        require(condition, name); tests.append(name)
    def rejects(name, fn, code):
        try:
            fn()
        except RuleError as e:
            check(name, str(e)==code)
        else:
            raise AssertionError(name)
    when = aware('2026-09-10T12:00:00+08:00')
    l=Ledger(); l.account('w','self',[10000,10000,10000]); l.account('b','self',[100000,0,0]); l.account('other','other',[100000,0,0])
    e=l.create('self','expense',25000,when,['w'])
    check('支出按流动/本人存款/对象存款扣减', l.accounts['w']['shares']==[0,0,5000])
    r=l.create('self','refund',12000,when,['w'],official=True,refund_kind='merchant_refund',affects=True)
    check('无原消费关联按派生缺口回补', l.accounts['w']['shares']==[0,7000,10000])
    l.adjust('self','w',1,0,2000)
    check('手动分配同步改变基准和份额，不另存目标表', l.accounts['w']['baseline'][1]==8000 and l.accounts['w']['shares']==[2000,5000,10000])
    l.edit('self',e,1,amount=20000)
    check('支出减少只处理差额并按当前缺口回补', l.accounts['w']['shares']==[4000,8000,10000])
    before=deepcopy(l.accounts)
    l.edit('self',r,1,affects=False)
    check('抵减开关不改变余额/份额',l.accounts==before)
    before=deepcopy(l.accounts); plans=deepcopy(l.transactions[r]['plans'])
    l.edit('self',r,2,when=aware('2026-08-10'))
    check('不跨起始日改日期保留原份额计划', l.accounts==before and l.transactions[r]['plans']==plans)
    rejects('并发旧version拒绝',lambda:l.edit('self',r,1,affects=True),'RESOURCE_VERSION_CONFLICT')
    rejects('字符串false拒绝',lambda:l.edit('self',r,3,affects='false'),'VALIDATION_ERROR')
    rejects('不能编辑来源原始时间',lambda:l.edit('self',r,3,source_occurred_at=when),'VALIDATION_ERROR')
    rejects('手动不能新建退款',lambda:l.create('self','refund',10,when,['w'],refund_kind='merchant_refund',affects=True),'REFUND_REQUIRES_OFFICIAL_SOURCE')
    rejects('不能写对象账户',lambda:l.create('self','income',10,when,['other']),'FORBIDDEN')
    for val in (0,-1,True):
        rejects('非法金额拒绝:'+str(val),lambda val=val:amount(val),'VALIDATION_ERROR')
    rejects('未来日期拒绝',lambda:l.create('self','income',10,NOW+timedelta(days=1),['w']),'VALIDATION_ERROR')
    rejects('普通类型不能带退款字段',lambda:l.create('self','income',10,when,['w'],affects=False),'VALIDATION_ERROR')
    snap=deepcopy(l.__dict__)
    rejects('份额不足整体回滚',lambda:l.create('self','expense',999999,when,['w']),'FUNDS_ALLOCATION_NOT_POSSIBLE')
    check('失败不残留半笔交易',snap==l.__dict__)
    l2=Ledger();l2.account('a','self',[0,0,0],opening='2026-09-01')
    t=l2.create('self','refund',100,when,['a'],official=True,refund_kind='merchant_refund',affects=True)
    l2.edit('self',t,1,when=aware('2026-08-01'))
    check('跨起始日变历史，保留交易且撤销资金',l2.accounts['a']['shares']==[0,0,0] and t in l2.transactions)
    l2.edit('self',t,2,when=when)
    check('历史改回有效重建自身资金',l2.accounts['a']['shares']==[100,0,0])
    spend=l2.create('self','expense',100,when,['a']);snap=deepcopy(l2.__dict__)
    rejects('已被使用退款不能不安全删除',lambda:l2.delete('self',t),'FUNDS_ALLOCATION_NOT_POSSIBLE')
    check('不安全撤销原子回滚',l2.__dict__==snap)
    l2.delete('self',spend);l2.delete('self',t)
    check('安全删除仅撤销自身',not l2.transactions and l2.accounts['a']['shares']==[0,0,0])
    lt=Ledger();lt.account('a','self',[1000,0,0]);lt.account('b','self',[0,0,0],opening='2026-10-01')
    tt=lt.create('self','transfer',100,when,['a','b'])
    check('转账两端独立起始日',lt.accounts['a']['shares'][0]==900 and lt.accounts['b']['shares'][0]==0 and set(lt.transactions[tt]['plans'])=={'a'})
    rows=wechat['rows']+alipay['rows']
    check('所有338行读出且有完整原始列',len(rows)==338 and all(len(r['raw_fields'])==(11 if r['platform']=='wechat' else 12) for r in rows))
    check('全部原始时间补为+08:00',all(r['source_occurred_at'].utcoffset()==timedelta(hours=8) for r in rows))
    check('排除123条渠道，2条费用转账明确不支持',sum(r['reason']=='UNSUPPORTED_PAYMENT_METHOD' for r in rows)==123 and sum(r['reason']=='TRANSFER_FEE_UNSUPPORTED' for r in rows)==2)
    refunds=[r for r in rows if r['type']=='refund']
    check('13条独立退款，无原消费字段',len(refunds)==13 and all('original_transaction_id' not in r for r in refunds))
    check('10条商户抵减/3条转账退回不抵减',sum(r['affects_spending'] for r in refunds)==10)
    wx=lambda n:next(r for r in wechat['rows'] if r['row']==n)
    ali=lambda n:next(r for r in alipay['rows'] if r['row']==n)
    check('0.44+0.26仅0.70，不按累计状态造流水',wx(32)['amount_minor']+wx(33)['amount_minor']==70)
    check('29条到账状态补零钱',sum(r['account_evidence']=='当前状态=已存入零钱' and r['keys']==['微信零钱'] for r in rows)==29)
    check('优惠剥离后实际扣款40.79',ali(66)['amount_minor']==4079 and ali(66)['keys']==['农业银行储蓄卡(2372)'] and ali(66)['discount_tags']==['闪购支付红包'])
    check('等待收货仍是支出',all(r['type']=='expense' for r in rows if r['source_status']=='等待确认收货' and r['disposition']!='unsupported'))
    check('支付宝核对终点不晚于导出',alipay['effective_to']==alipay['exported_at']<alipay['declared_to'])
    check('4条无费内部转账候选角色明确',sum(r['type']=='transfer' for r in rows)==4 and wx(146)['keys']==['微信零钱','农业银行储蓄卡(2372)'])
    # Source identity survives transaction deletion; real field row drives the full reference path.
    led=Ledger();led.account('wallet','self',[100000,0,0]);imp=ImportReference(led);imp.profile('profile-w')
    one=dict(wechat,rows=[deepcopy(wx(32))],declared_count=1)
    initial=imp.batch('profile-w',one,'first')
    check('缺账户映射进入待处理，未写账',initial['summary']['needs_review']==1 and not led.transactions)
    imp.map('profile-w','微信零钱','wallet')
    done=imp.batch('profile-w',one,'resume');tid=done['rows'][0]['transaction_id']
    check('映射补齐后独立退款恢复创建',done['summary']['created']==1 and led.transactions[tid]['type']=='refund')
    oldtime=imp.sources[('profile-w',wx(32)['official_transaction_id'])]['row']['source_occurred_at']
    led.edit('self',tid,1,when=aware('2026-08-15'),affects=False)
    dup=imp.batch('profile-w',one,'new-import')
    check('新键重导不覆盖用户日期/抵减，来源时间不变',dup['summary']['duplicate_existing']==1 and not led.transactions[tid]['affects'] and led.transactions[tid]['when'].month==8 and oldtime.month==9)
    led.delete('self',tid);restored=imp.batch('profile-w',one,'restore')
    check('保留SourceRecord删除后新键重导能恢复',restored['summary']['created']==1 and len(imp.sources)==1)
    snap=deepcopy(led.__dict__);imp.batch('profile-w',one,'restore')
    check('同幂等键重放不产生第二笔',led.__dict__==snap)
    changed=deepcopy(one);changed['rows'][0]['amount_minor']+=1
    rejects('同键不同请求拒绝',lambda:imp.batch('profile-w',changed,'restore'),'IDEMPOTENCY_KEY_CONFLICT')
    stale=deepcopy(one);stale['exported_at']-=timedelta(days=1);stale['rows'][0]['amount_minor']=999
    stale_result=imp.batch('profile-w',stale,'old-export')
    check('旧导出不覆盖较新来源事实',stale_result['summary']['duplicate_existing']==1 and imp.sources[('profile-w',wx(32)['official_transaction_id'])]['row']['amount_minor']==44)
    conflict=imp.batch('profile-w',changed,'conflict')
    check('同导出时间内容冲突明确待处理',conflict['rows'][0]['reason']=='SOURCE_FACT_CONFLICT')
    imp.profile('second-profile');led.account('wallet-2','self',[0,0,0])
    rejects('不同档案不能映射同一微信零钱账户',lambda:imp.map('second-profile','微信零钱','wallet'),'ACCOUNT_EVIDENCE_CONFLICT')
    imp.map('second-profile','微信零钱','wallet-2')
    check('不同来源账号零钱映射隔离',imp.mapping[('second-profile','微信零钱')] != imp.mapping[('profile-w','微信零钱')])
    imp.profile('foreign-profile',owner='other')
    rejects('不能使用他人来源档案',lambda:imp.batch('foreign-profile',one,'forged-profile'),'FORBIDDEN')
    rejects('映射不能指向他人账户',lambda:imp.map('profile-w','伪造渠道','missing'),'FORBIDDEN')
    fresh=Ledger();fresh.account('wallet','self',[100000,0,0]);fimp=ImportReference(fresh);fimp.profile('p');fimp.map('p','微信零钱','wallet');fimp.bind_failure=True
    failed=fimp.batch('p',one,'bind-failure')
    check('来源关联失败回滚账务',failed['summary']['failed']==1 and not fresh.transactions and fresh.accounts['wallet']['shares'][0]==100000)
    check('失败来源保留且无当前交易',len(fimp.sources)==1 and next(iter(fimp.sources.values()))['transaction'] is None)
    rf=dict(type='refund',amount=3000,affects=True,when=aware('2026-09-10'));ex=dict(type='expense',amount=10000,when=aware('2026-08-10'))
    st=stats([rf],'2026-09',20000)
    check('负净花销保留且预算剩余可大于预算',st['net']==-3000 and st['remaining']==23000)
    rf2=deepcopy(rf);rf2['when']=aware('2026-08-10')
    check('跨月退款抵减归记账月',stats([rf2,ex],'2026-08',20000)['net']==7000 and stats([rf2,ex],'2026-09',20000)['net']==0)
    rf2['affects']=False
    check('关闭抵减仅移除统计抵减',stats([rf2,ex],'2026-08',20000)['net']==10000)
    octex=dict(type='expense',amount=320000,when=aware('2026-10-10'))
    octstats=stats([octex],'2026-10',300000,now=aware('2026-10-20T23:59:00'))
    check('经典预算日均预测算术一致',octstats['daily']==16000 and octstats['projected']==496000 and octstats['over']==20000)
    tiny=dict(type='expense',amount=1,when=aware('2026-10-01'))
    tiny_stats=stats([tiny],'2026-10',100,now=aware('2026-10-03T23:59:00'))
    check('预测使用未提前舍入日均',tiny_stats['daily']==0 and tiny_stats['projected']==10)
    change_rate=lambda current,previous:None if previous==0 else (Decimal(current-previous)/Decimal(previous)).quantize(Decimal('0.0001'),rounding=ROUND_HALF_UP)
    check('日均变化率与零分母明确',change_rate(16000,15000)==Decimal('0.0667') and change_rate(100,0) is None)
    roles=imp.transfer_role(wx(20),'expense',['微信零钱'])
    check('向他人转账可明确为支出，非全部transfer',roles['type']=='expense' and roles['accounting_semantics']=='ordinary')
    role_l=Ledger();role_l.account('wallet','self',[100000,0,0]);ri=ImportReference(role_l);ri.profile('p');ri.map('p','微信零钱','wallet')
    unresolved=dict(wechat,rows=[deepcopy(wx(20))],declared_count=1)
    ri.batch('p',unresolved,'unresolved-role')
    resolved=ri.one('p',roles,wechat['exported_at'])
    check('角色补齐可以沿原来源继续，非同时间事实冲突',resolved['disposition']=='created')
    check('已确认转账角色重导不再要求选择',ri.batch('p',unresolved,'role-reimport')['summary']['duplicate_existing']==1)
    rejects('转出记录不能改为收入',lambda:imp.transfer_role(wx(20),'income',['微信零钱']),'VALIDATION_ERROR')
    manual=Ledger();manual.account('wallet','self',[100000,0,0]);mi=ImportReference(manual);mi.profile('p');mi.map('p','微信零钱','wallet')
    mt=manual.create('self','refund',44,wx(32)['occurred_at'],['wallet'],official=True,refund_kind='merchant_refund',affects=True)
    candidate=mi.batch('p',one,'candidate')['rows'][0]
    check('弱字段相同只有候选，不静默合并',candidate['reason']=='POSSIBLE_EXISTING_TRANSACTION' and len(manual.transactions)==1)
    linked=mi.link('p',candidate,mt)
    check('确认同一退款只关联来源不再入账',linked['disposition']=='linked_existing' and len(manual.transactions)==1)
    exp=manual.create('self','expense',44,when,['wallet'])
    rejects('退款不能关联原消费expense',lambda:mi.link('p',candidate,exp),'VALIDATION_ERROR')
    second=deepcopy(wx(32));second['official_transaction_id']='distinct-official-source'
    new_candidate=mi.one('p',second,one['exported_at'])
    check('相似但不同来源可要求用户明确决定',new_candidate['reason']=='POSSIBLE_EXISTING_TRANSACTION')
    check('确认确为另一笔后可创建，不陷入候选循环',mi.one('p',second,one['exported_at'],confirm_new=True)['disposition']=='created')
    later=deepcopy(one);later['exported_at']+=timedelta(hours=1);later['rows'][0]['source_status']='交易关闭';later['rows'][0]['type']=None;later['rows'][0]['refund_kind']=None;later['rows'][0]['affects_spending']=None;later['rows'][0]['disposition']='ineffective'
    status_l=Ledger();status_l.account('wallet','self',[10000,0,0]);si=ImportReference(status_l);si.profile('p');si.map('p','微信零钱','wallet')
    si.batch('p',later,'closed-first');success=deepcopy(one);success['exported_at']=later['exported_at']+timedelta(hours=1)
    check('关闭来源后变有效可以首次创建',si.batch('p',success,'success-later')['summary']['created']==1)
    result_led=Ledger();result_led.account('wallet','self',[100000000,0,0]);result_led.account('bank','self',[100000000,0,0])
    real=ImportReference(result_led)
    for profile in ('p-wechat','p-alipay'):
        real.profile(profile);real.map(profile,'农业银行储蓄卡(2372)','bank')
    real.map('p-wechat','微信零钱','wallet')
    outputs=[real.batch('p-wechat',wechat,'real-w'),real.batch('p-alipay',alipay,'real-a')]
    check('真实信息流逐行计数守恒',all(sum(o['summary'].values())==len(b['rows']) for o,b in zip(outputs,(wechat,alipay))))
    check('存在不支持/待处理则不作缺失结论',all(not o['reconciliation_eligible'] for o in outputs))
    check('正式候选有合法类型/语义/账户/时间',all(r['type'] in ('income','expense','transfer','refund') and r['accounting_semantics'] in ('ordinary','internal_transfer','refund_inflow') and r['accounts'] and r['occurred_at'].tzinfo for o in outputs for r in o['rows'] if r['disposition']=='created'))
    man=dict(owner='self',official=False,when=wx(32)['occurred_at'])
    clean_batch=deepcopy(one);clean_result={'reconciliation_eligible':True}
    check('银行卡仅有账户不生成平台缺失结论',not eligible_manual(man,clean_batch,clean_result,'p'))
    check('明确平台来源且覆盖完整才可核对',eligible_manual(man,clean_batch,clean_result,'p',explicit_profile='p'))
    check('已有来源不因日期编辑生成缺失项',not eligible_manual(man,clean_batch,clean_result,'p',explicit_profile='p',has_source=True))
    man['when']=alipay['exported_at']+timedelta(hours=1)
    check('导出后时间段不得判缺失',not eligible_manual(man,alipay,clean_result,'p',explicit_profile='p'))
    check('不支持行阻止本batch负向核对',not eligible_manual(man,alipay,outputs[1],'p',explicit_profile='p'))
    broken=deepcopy(one);broken['rows'][0].update(disposition='failed',reason='INVALID_SOURCE_FIELDS');broken['rows'][0].pop('amount_minor')
    badled=Ledger();badled.account('wallet','self',[1000,0,0]);badimp=ImportReference(badled);badimp.profile('p')
    check('错误行保留观察且不造成整批半笔写入',badimp.batch('p',broken,'bad-row')['summary']['failed']==1 and not badled.transactions and len(badimp.observations)==1)
    root=Path(__file__).resolve().parents[1]
    documents=list((root/'docs').glob('*.md'))
    check('仅六份核心文档且引用存在',len(documents)==6 and all(
        (p.parent/d.split('#')[0]).exists() for p in [root/'README.md']+documents
        for d in re.findall(r'\]\(([^)]+)\)',p.read_text()) if ':' not in d and not d.startswith('#')))
    api=(root/'docs/API_CONTRACT.md').read_text()
    examples=[json.loads(s) for s in re.findall(r'```json\n(.*?)\n```',api,re.S)]
    check('全部API示例JSON合法',bool(examples) and any(x.get('type')=='expense' for x in examples) and any('version' in x and 'affects_spending' in x for x in examples))
    for ex in examples:
        if 'occurred_at' in ex:
            check('API时间示例携带偏移:'+str(len(tests)),datetime.fromisoformat(ex['occurred_at']).tzinfo is not None)
        if 'data' in ex and 'summary' in ex['data']:
            data=ex['data'];summary=data['summary']
            check('API示例七类行数与read_rows守恒',sum(summary[d] for d in DISPOSITIONS)==summary['read_rows'])
            check('缺映射示例不开放创建动作',data['rows'][0]['candidate']['account_id'] is None and data['rows'][0]['allowed_actions']==[])
            check('API示例coverage有效终点不越导出',aware(data['coverage']['effective_to'])<=aware(data['coverage']['exported_at']))
    check('已取消的退款错误码不再存在',not any(code in api for code in ('INVALID_REFUND_LINK','REFUND_EXCEEDS_ORIGINAL','REFUND_ORIGINAL_NOT_RESOLVED')))
    mismatch=deepcopy(wechat);mismatch['declared_count']+=1
    check('声明数不符保留读取结果但禁止完整核对',not structure_complete(mismatch,mismatch['rows']) and len(mismatch['rows'])==169)
    duplicate=deepcopy(wechat);duplicate['rows'][1]['official_transaction_id']=duplicate['rows'][0]['official_transaction_id']
    check('同文件身份重复不宣称结构完整',not structure_complete(duplicate,duplicate['rows']))
    ct=Ledger();ct.account('a','self',[10000,0,0]);ct.account('b','self',[0,0,0])
    ctid=ct.create('self','expense',1000,when,['a'])
    ct.change_type('self',ctid,1,'transfer',['a','b'])
    check('支出改内部转账保留ID且两端守恒',len(ct.transactions)==1 and ct.accounts['a']['shares'][0]==9000 and ct.accounts['b']['shares'][0]==1000)
    ct.change_type('self',ctid,2,'income',['a'])
    check('转账改收入先撤销两端再入账',ct.accounts['a']['shares'][0]==11000 and ct.accounts['b']['shares'][0]==0)
    rejects('普通类型变更不能生成退款',lambda:ct.change_type('self',ctid,3,'refund',['a']),'VALIDATION_ERROR')
    rejects('官方退款不能变成普通收入',lambda:led.change_type('self',next(iter(led.transactions)),1,'income',['wallet']),'VALIDATION_ERROR')
    op=Ledger();op.account('a','self',[10000,0,0]);op.account('b','self',[500,0,0])
    ot=op.create('self','expense',1000,when,['a']);other=deepcopy(op.accounts['b'])
    op.opening_state('self','a','2026-10-01',[20000,0,0])
    check('改账户起始状态重建本账户历史影响',op.accounts['a']['shares'][0]==20000 and not op.transactions[ot]['plans'] and op.accounts['b']==other)
    op.opening_state('self','a','2026-01-01',[10000,0,0])
    check('起始状态改回能重建有效支出',op.accounts['a']['shares'][0]==9000)
    snapshot=deepcopy(op.__dict__)
    rejects('不安全起始重建明确拒绝',lambda:op.opening_state('self','a','2026-01-01',[0,0,0]),'OPENING_STATE_RECALCULATION_CONFLICT')
    check('起始重建失败整体回滚',op.__dict__==snapshot)
    manual_payload=next(x for x in examples if x.get('type')=='expense')
    command=reference_pilot_body(manual_payload)
    pilot=Ledger();pilot.account('account-a','self',[500000,0,0],opening='2026-10-01')
    pt=pilot.create('self',command['type'],command['amount_minor'],command['occurred_at'],[command['account_id']])
    check('创建试点示例准确扣款2580分',pilot.accounts['account-a']['shares'][0]==497420 and pilot.transactions[pt]['version']==1)
    for value in (0,None,'2580',True):
        bad=deepcopy(manual_payload);bad['amount_minor']=value
        rejects('试点请求严格金额:'+str(value),lambda bad=bad:reference_pilot_body(bad),'VALIDATION_ERROR')
    no_zone=deepcopy(manual_payload);no_zone['occurred_at']='2026-10-20T12:30:00'
    rejects('公共请求不自动补缺失时区',lambda:reference_pilot_body(no_zone),'VALIDATION_ERROR')
    extra=deepcopy(manual_payload);extra['user_id']='other'
    rejects('创建请求拒绝未声明授权字段',lambda:reference_pilot_body(extra),'VALIDATION_ERROR')
    bad_transfer=dict(type='transfer',accounting_semantics='internal_transfer',amount_minor=100,occurred_at=manual_payload['occurred_at'],from_account_id='account-a',to_account_id='account-a')
    rejects('创建请求禁止同账户转账',lambda:reference_pilot_body(bad_transfer),'VALIDATION_ERROR')
    pr=pilot.create('self','refund',44,aware('2026-09-27T12:08:36+08:00'),['account-a'],official=True,refund_kind='merchant_refund',affects=True)
    snap=deepcopy(pilot.__dict__)
    pilot.edit('self',pr,1)
    check('退款空PATCH不产生版本或资金变化',pilot.__dict__==snap)
    pilot.edit('self',pr,1,affects=True)
    check('退款相同值PATCH不产生版本或资金变化',pilot.__dict__==snap)
    pilot.edit('self',pr,1,affects=False)
    rejects('空改动不绕过所选版本分支检查',lambda:pilot.edit('self',pr,1),'RESOURCE_VERSION_CONFLICT')
    no_field=reference_pilot_body({'version':2},patch=True,compare_version=True)
    false_field=reference_pilot_body({'version':2,'affects_spending':False},patch=True,compare_version=True)
    check('PATCH省略与显式false分开', 'affects_spending' not in no_field and false_field['affects_spending'] is False)
    rejects('PATCH null不能冒充省略',lambda:reference_pilot_body({'version':2,'affects_spending':None},patch=True,compare_version=True),'VALIDATION_ERROR')
    rejects('PATCH源时间只读',lambda:reference_pilot_body({'version':2,'source_occurred_at':'2026-09-01T00:00:00+08:00'},patch=True,compare_version=True),'VALIDATION_ERROR')
    errors=[x for x in examples if 'code' in x]
    check('试点HTTP错误示例统一顶层code/message',bool(errors) and all(set(x)=={'code','message'} and type(x['code']) is str and type(x['message']) is str for x in errors))
    result_led.invariant()
    return tests,outputs


def table(headers,rows):
    clean=lambda v:str(v).replace('|','／').replace('\n',' ')
    return '| '+' | '.join(headers)+' |\n|'+'|'.join(['---']*len(headers))+'|\n'+''.join('| '+' | '.join(clean(v) for v in row)+' |\n' for row in rows)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--wechat',required=True);parser.add_argument('--alipay',required=True);parser.add_argument('--report');args=parser.parse_args()
    wx=parse_file(args.wechat);ali=parse_file(args.alipay);require(wx['platform']=='wechat' and ali['platform']=='alipay','UNSUPPORTED_SOURCE_FILE')
    tests,outputs=validate(wx,ali)
    print({'checks_passed':len(tests),'read_rows':len(wx['rows'])+len(ali['rows']), 'reference_results':[o['summary'] for o in outputs]})
    if args.report:
        text='# 星账核心设计与流程验证\n\n仅为文档配套的内存参考模型，不是已部署API/数据库/真实用户账户验收。当前验证使用固定时钟及虚构账户映射；原始文件只读，无外部写账。\n\n'
        text+='\n'.join('- 通过：'+t for t in tests)+'\n\n## 真实字段信息流结果\n\n'
        text+=table(['平台','created','linked_existing','duplicate_existing','unsupported','ineffective','needs_review','failed'],[[b['platform']]+[o['summary'][d] for d in DISPOSITIONS] for b,o in zip((wx,ali),outputs)])
        text+='\ncreated仅指虚构账户的参考模型写入，不代表真实应用成功入账。同事件弱字段候选保留待确认，不能按候选唯一冒充准确率。\n\n'
        text+=table(['平台/行','时间','类型','整数分金额','渠道键','分类','退款抵减','结果','原因'],[[r['platform']+' '+str(r['row']),r.get('source_occurred_at'),r['type'],r.get('amount_minor'),r['keys'],r['category_code'],r['affects_spending'],r['disposition'],r['reason']] for o in outputs for r in o['rows']])
        Path(args.report).write_text(text)


if __name__=='__main__':
    main()
