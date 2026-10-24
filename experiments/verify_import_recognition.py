"""Read-only XLSX experiment. No database, network, account writes or original-order matching.

Usage: python3 experiments/verify_import_recognition.py --wechat FILE --alipay FILE --report FILE
Dependency: openpyxl (already available in the analysis environment).
Report contains private transaction details; keep it outside the repository.
"""
import argparse
from collections import Counter
from copy import deepcopy
from datetime import datetime
from decimal import Decimal
from pathlib import Path
import re
import openpyxl


def minor(value):
    n = Decimal(str(value).strip()) * 100
    if not n.is_finite() or n != n.to_integral_value() or n < 0:
        raise ValueError('Invalid amount')
    return int(n)


def parse(path, platform):
    sheet = openpyxl.load_workbook(path, data_only=True).active
    values = list(sheet.values)
    header = next(i for i, row in enumerate(values)
                  if '交易时间' in row and ('交易类型' if platform == '微信' else '交易分类') in row)
    keys = values[header]
    result = []
    declared_text = ' '.join(str(x) for row in values[:header] for x in row if x is not None)
    match = re.search(r'共\s*(\d+)\s*笔记录', declared_text)
    for n, row in enumerate(values[header + 1:], header + 2):
        if all(x is None for x in row):
            continue
        raw = {k: v for k, v in zip(keys, row) if k is not None}
        v = {k: '' if x is None else str(x).strip() for k, x in raw.items()}
        wx = platform == '微信'
        method = v['支付方式' if wx else '收/付款方式']
        status = v['当前状态' if wx else '交易状态']
        source_kind = v['交易类型' if wx else '交易分类']
        desc = v['商品' if wx else '商品说明']
        excluded = ('亲情卡' if '亲情卡' in method else
                    '花呗' if any('花呗' in v.get(k, '') for k in
                                  ['收/付款方式', '商品说明', '交易对方']) else '')
        source_id = re.sub(r'(?:\\t|\s)+$', '', v['交易单号' if wx else '交易订单号'])
        # Remove coupon tokens only; unknown instruments are not guessed.
        pieces = method.split('&')
        discounts = [x for x in pieces if '红包' in x]
        base = '&'.join(x for x in pieces if '红包' not in x)
        if status == '已存入零钱':
            account, account_evidence = '微信零钱', '当前状态=已存入零钱'
            if base not in ('', '/', '零钱'):
                account, account_evidence = '', '账户证据冲突'
        elif base == '零钱':
            account, account_evidence = '微信零钱', '支付方式=零钱'
        elif re.fullmatch(r'.*银行储蓄卡\(\d{4}\)', base):
            account, account_evidence = base, '支付渠道剥离优惠标记'
        else:
            account, account_evidence = '', '账户映射待处理'
        timestamp = raw['交易时间']
        if not isinstance(timestamp, datetime):
            timestamp = datetime.fromisoformat(str(timestamp).strip())
        amount = minor(raw['金额(元)' if wx else '金额'])
        is_refund = ('退款' in source_kind if wx else status == '退款成功')
        closed = any(x in status for x in ['失败', '关闭'])
        refund_kind, affects = None, None
        if excluded:
            kind, outcome = 'excluded', '范围排除'
        elif closed:
            kind, outcome = 'ineffective', '未生效，不入账'
        elif is_refund:
            kind = 'refund'
            refund_kind = 'transfer_return' if source_kind == '转账-退款' else 'merchant_refund'
            affects = refund_kind == 'merchant_refund'
            outcome = '可提取独立退款；待实际Account映射及统一账务实现' if account else '退款到账账户待处理'
        elif wx and source_kind in ['零钱充值', '零钱提现']:
            kind, outcome = 'internal_transfer_candidate', '需识别两端与手续费，未完成账务验证'
        elif wx and source_kind == '转账':
            kind, outcome = 'transfer_direction_candidate', '转入/转出明确；内部转账或外部收支待确定'
        else:
            kind = {'收入': 'income', '支出': 'expense'}.get(v['收/支'], 'unknown')
            outcome = '字段已提取；正式入账待实现'
        result.append(dict(platform=platform, row=n, source_id=source_id,
                           source_occurred_at=timestamp.isoformat(), occurred_at=timestamp.isoformat(),
                           amount_minor=amount, account_hint=account, account_evidence=account_evidence,
                           type=kind, refund_kind=refund_kind, affects_spending=affects,
                           discount='；'.join(discounts), excluded=excluded, status=status,
                           source_kind=source_kind, counterparty=v['交易对方'], description=desc,
                           outcome=outcome))
    if not match or int(match[1]) != len(result):
        raise ValueError('Declared row count mismatch')
    if any(not r['source_id'] for r in result) or len({r['source_id'] for r in result}) != len(result):
        raise ValueError('Missing or duplicate source ID inside file')
    return result


def flow(r):
    if r['type'] in ('refund', 'income'):
        return r['amount_minor']
    if r['type'] == 'expense':
        return -r['amount_minor']
    if r['type'] == 'ineffective':
        return 0
    return None  # Not a completed account-transfer interpretation.


def spending(r):
    if r['type'] == 'refund':
        return -r['amount_minor'] if r['affects_spending'] else 0
    return r['amount_minor'] if r['type'] == 'expense' else 0


def ingest_candidate(state, r):
    # Test fixture profile, not a real user profile or account binding.
    key = (r['platform'], 'fixture-source-profile', r['source_id'])
    if key in state:
        state[key]['latest_observation'] = deepcopy(r)
        return False  # Preserve user-edited transaction fields.
    state[key] = {'transaction': deepcopy(r), 'latest_observation': deepcopy(r)}
    return True


def checks(rows):
    tests = []
    def check(name, condition):
        if not condition:
            raise AssertionError(name)
        tests.append(name)
    included = [r for r in rows if not r['excluded']]
    refunds = [r for r in included if r['type'] == 'refund']
    check('读取338行，纳入215行，排除123行', len(rows) == 338 and len(included) == 215)
    check('13条退款均有账户线索、金额、时间和子类型，无原消费字段',
          len(refunds) == 13 and all(r['account_hint'] and r['amount_minor'] > 0 and
          r['source_occurred_at'] and r['refund_kind'] and 'original_transaction_id' not in r for r in refunds))
    check('10条商户退款默认抵减，3条转账退回默认不抵减',
          sum(r['affects_spending'] for r in refunds) == 10 and
          sum(r['refund_kind'] == 'transfer_return' and not r['affects_spending'] for r in refunds) == 3)
    wx = lambda n: next(r for r in included if r['platform'] == '微信' and r['row'] == n)
    ali = lambda n: next(r for r in included if r['platform'] == '支付宝' and r['row'] == n)
    check('微信0.44+0.26退款仅增加0.70元，不重复使用累计状态', flow(wx(32)) + flow(wx(33)) == 70)
    blanks = [r for r in included if r['platform'] == '微信' and r['status'] == '已存入零钱']
    check('29条已存入零钱状态均提取到微信零钱', len(blanks) == 29 and all(r['account_hint'] == '微信零钱' for r in blanks))
    check('优惠不作为账户；支付宝66行实际扣款40.79元',
          ali(66)['discount'] == '闪购支付红包' and flow(ali(66)) == -4079 and
          '红包' not in ali(66)['account_hint'])
    waiting = [r for r in included if r['status'] == '等待确认收货']
    check('等待确认收货保留支出，不等待收货', bool(waiting) and all(r['type'] == 'expense' for r in waiting))
    closed = [r for r in included if r['type'] == 'ineffective']
    check('关闭记录保留来源且不产生资金变动', len(closed) == 1 and flow(closed[0]) == 0)
    sample = deepcopy(wx(32))
    state = {}
    check('首次纳入13条退款，重复纳入新增0条',
          sum(ingest_candidate(state, r) for r in refunds) == 13 and
          sum(ingest_candidate(state, r) for r in refunds) == 0)
    key = (sample['platform'], 'fixture-source-profile', sample['source_id'])
    edited = state[key]['transaction']
    edited['occurred_at'] = '2026-08-15T12:00:00'
    edited['affects_spending'] = False
    ingest_candidate(state, sample)
    check('重导不覆盖编辑日期和抵减开关，保留原始官方时间',
          edited['occurred_at'].startswith('2026-08') and not edited['affects_spending'] and
          edited['source_occurred_at'] == sample['source_occurred_at'])
    changed = deepcopy(sample); changed['affects_spending'] = False
    check('抵减开关只影响花销，不改变退款到账金额',
          spending(sample) == -44 and spending(changed) == 0 and flow(sample) == flow(changed) == 44)
    changed = deepcopy(sample); changed['occurred_at'] = '2026-08-15T12:00:00'
    check('跨月修改记账日期改变抵减月份，不覆盖官方时间',
          sample['occurred_at'][:7] == '2026-09' and changed['occurred_at'][:7] == '2026-08' and
          changed['source_occurred_at'] == sample['source_occurred_at'])
    ingest_candidate(state, wx(35))
    state.pop((wx(35)['platform'], 'fixture-source-profile', wx(35)['source_id']))
    check('删除一笔消费后独立退款仍在',
          sum(item['transaction']['type'] == 'refund' for item in state.values()) == 13)
    # Date-boundary projection only, not AccountFundMovement or fund-ownership simulation.
    start = '2026-09-01'
    applied = lambda r: flow(r) if r['occurred_at'][:10] >= start else 0
    check('记账日期跨起始日时切换historical_only/applied', applied(sample) == 44 and applied(changed) == 0)
    return tests


def table(headers, rows):
    def clean(v):
        return str(v).replace('|', '／').replace('\n', ' ')
    return '| ' + ' | '.join(headers) + ' |\n|' + '|'.join(['---'] * len(headers)) + '|\n' + ''.join(
        '| ' + ' | '.join(clean(x) for x in row) + ' |\n' for row in rows)


def run():
    p = argparse.ArgumentParser()
    p.add_argument('--wechat', required=True); p.add_argument('--alipay', required=True)
    p.add_argument('--report', required=True)
    args = p.parse_args()
    rows = parse(args.wechat, '微信') + parse(args.alipay, '支付宝')
    tests = checks(rows)
    included = [r for r in rows if not r['excluded']]
    refunds = [r for r in included if r['type'] == 'refund']
    summary = dict(read=len(rows), included=len(included), excluded=len(rows)-len(included),
                   kinds=dict(Counter(r['type'] for r in included)),
                   refunds=len(refunds), refund_flow_minor=sum(flow(r) for r in refunds),
                   refund_spending_offset_minor=-sum(spending(r) for r in refunds), checks=len(tests))
    print(summary)
    text = '''# 星账导入识别机制 v2.8：真实样本阶段结果

2026-10-24。此报告替代此前退款原单匹配实验的当前结论；不再开发原消费关联。

## 结论与范围

识别路径可行：退款独立记录到账账户、实际金额、官方原始时间、可编辑记账日期与抵减开关。只读实验不写数据库、不绑定真实Account、不生成资金归属份额。

亲情卡及花呗相关排除。金额按用户确认的实际变动口径读取，支付红包仅为优惠；等待确认收货保留支出。原消费状态里的累计退款额只作证据，不另造资金流入。

来源档案与实际Account映射、普通转账内外部语义、充值提现两端/手续费、资金份额回补缺口基准及正式导入闭环未验收。本轮不把这些说成已经处理成功。

'''
    text += table(['项目', '结果'], summary.items())
    text += '\n## 退款逐笔识别\n\n'
    text += table(['来源/Excel行', '实际到账账户线索', '金额元', '官方时间/默认记账时间', '子类型', '默认抵减'],
                  [[f"{r['platform']} {r['row']}", r['account_hint'], f"{r['amount_minor']/100:.2f}",
                    r['source_occurred_at'], r['refund_kind'], r['affects_spending']] for r in refunds])
    text += '\n## 阶段验证\n\n' + '\n'.join('- 通过：' + name for name in tests)
    text += '''

这些验证是实验脚本内的字段和规则检查，重复导入/删除/编辑用内存模型验证预期，并非生产数据库事务、API或同步测试。没有原单正确答案不再妨碍本轮退款提取，因为不建立原消费关系。

日期使用说明：occurred_at为记账日期，默认官方退款时间。改日期更新该月花销、预算及交易有效日期；原始时间留在来源证据。不跨账户起始日时，当前退款流入金额不变；跨起始日时按既有规则切换历史/有效余额影响。关闭抵减不影响账户到账金额。独立退款可使某月净花销为负，统计不得擅自截断为0。

## 纳入范围逐行结果

'''
    text += table(['来源/行', '记账日期', '类型', '金额元', '账户线索', '退款抵减', '对方', '说明', '结果'],
                  [[f"{r['platform']} {r['row']}", r['occurred_at'], r['type'], f"{r['amount_minor']/100:.2f}",
                    r['account_hint'] or '未确定', r['affects_spending'], r['counterparty'], r['description'], r['outcome']]
                   for r in included])
    text += '\n## 排除范围\n\n'
    text += table(['平台', '原因', '行数', 'Excel行号'],
                  [[platform, reason, sum(r['platform'] == platform and r['excluded'] == reason for r in rows),
                    ', '.join(str(r['row']) for r in rows if r['platform'] == platform and r['excluded'] == reason)]
                   for platform in ['微信', '支付宝'] for reason in ['亲情卡', '花呗']
                   if any(r['platform'] == platform and r['excluded'] == reason for r in rows)])
    Path(args.report).write_text(text)


if __name__ == '__main__':
    run()
