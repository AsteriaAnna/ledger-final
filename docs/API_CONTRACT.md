# 星账｜API契约

候选HTTP契约，尚无已部署API。依据[业务规则](BUSINESS_RULES_DISCUSSION.md)、[逻辑模型](LOGICAL_DATA_MODEL.md)，模块职责见[模块边界](ENGINEERING_MODULE_BOUNDARIES.md)。

## 1. 通用规则

前缀/api/v1。JSON请求响应，导入文件用multipart。ID为不透明字符串；金额整数分，交易amount_minor严格正整数，初始余额/预算非负，账户影响用带符号整数。日期YYYY-MM-DD，月份YYYY-MM；时间RFC3339必须带偏移，服务端规范化为+08:00解释日期/月界。记账时间不得未来。

写接口需要认证，不以user_id授权。view=mine默认，view=partner只允许明确开放的账户、账单只读查询；不能通过绑定写对方账本。逐项校验资源归属与关联，不只校验URL中的batch。

成功为data，列表带page.next_cursor；错误为error.code/message/field_errors/request_id。不存在或不应暴露的资源返回404；已明确可读但不可写的对象资源返回403。

创建、导入、resolution、核对处理、资金调整带Idempotency-Key。同键相同请求返回原结果，同键不同请求409 IDEMPOTENCY_KEY_CONFLICT。用户新操作使用新键；文件指纹不替代幂等操作或来源身份。PATCH/PUT带version，资源变更返回新version；冲突409 RESOURCE_VERSION_CONFLICT。所有账务写操作原子提交，失败不返回成功。

## 2. 接口与业务模块

| 模块 | 方法与路径 | 行为 |
|---|---|---|
| M1 | GET /relationship | 当前绑定状态、对象必要信息及只读权限 |
| M1 | POST /relationship/binding | 消费有效binding_token完成绑定；无解绑 |
| M2 | GET /accounts?view=mine；GET /accounts/{id} | 账户、起始日、计算余额/份额、read_only、version |
| M2 | POST /accounts | 创建本人实际账户、初始状态 |
| M2 | PATCH /accounts/{id} | name/account_type/custodian，不能直接改余额 |
| M2 | PUT /accounts/{id}/opening-state | 原子修正初始日期/金额/份额及受影响状态 |
| M2 | POST /accounts/{id}/fund-adjustments | 同账户等额合法份额调整 |
| M3 | GET /transactions；GET /transactions/{id} | 列表/详情，支持view、日期、type、account、category、q、分页 |
| M3 | POST /transactions | 手动创建income/expense/transfer，不能refund |
| M3 | PATCH /transactions/{id}；DELETE /transactions/{id} | 编辑/仅删除当前交易，消费不级联退款 |
| M3 | GET /transaction-categories | 受控分类代码、显示名及other兜底 |
| M4 | POST /imports；GET /imports/{batchId} | 上传/读取文件结果、档案候选、分页行结果 |
| M4 | POST /imports/{batchId}/resolutions | 选档案、补语义、创建/关联/恢复来源行 |
| M4 | GET /source-payment-method-mappings?source_account_profile_id=... | 本人该档案渠道映射 |
| M4 | PUT /source-payment-method-mappings | 更新本人档案渠道到本人Account的映射 |
| M4 | POST /imports/{batchId}/reconciliation-reviews | 保留核对项，或经M3删除手动交易 |
| M5 | GET /overview?month=YYYY-MM | 本人资金视图、个人净花销与预算，月份限当前/历史 |
| M5 | GET/PUT /budgets/{month} | 本人月预算，允许合法未来月份 |

无直接写AccountFundMovement接口；无账户删除、截图、负债、退款原消费关联接口。认证签发不在本业务API中假设供应商；binding_token的安全生成/过期由实施阶段实现。

## 3. M2：账户与份额

POST /accounts字段：name、account_type（cash/bank_card/wechat_balance/alipay_balance/other）、custodian（self/partner，默认self）、opening_date、opening_balance_minor、opening_allocations。allocation为fund_owner=self|partner、fund_type=liquid|savings、amount_minor。

账户holder固定当前用户。partner仅绑定后可用，partner只能savings；份额非负且合计=初始金额。opening_date不得未来。响应含id、name、type、holder、custodian、opening_date、balance_minor、fund_shares、read_only、version。读取时holder/custodian/fund_owner中的self、partner均相对当前登录查看者；内部保存实际用户ID。写入仅本人账户，partner份额仍只能为存款；查看对象账户时可读到对象自己的流动资金，不将写限制误用于返回数据。

fund_shares可含派生的savings_baseline_minor、savings_gap_minor供说明，不可直接PATCH。

PUT opening-state带全部初始字段与version；原子重建本账户受影响交易的历史/有效状态，其他账户不改。不能安全重建则409 OPENING_STATE_RECALCULATION_CONFLICT。账户余额不通过覆盖字段修正。

POST fund-adjustments含from/to两个合法份额与正amount_minor。同账户来源份额足够，净额0；调整改变相应存款基准和当前份额，不计收支。返回计算结果与新version，不允许对对象账户操作。

## 4. M3：交易字段、写入和编辑

### 4.1 合法组合

| type | accounting_semantics | 账户字段 | 退款字段 |
|---|---|---|---|
| income | ordinary | account_id | 禁止 |
| expense | ordinary | account_id | 禁止 |
| transfer | internal_transfer | from_account_id、to_account_id（不同） | 禁止 |
| refund | refund_inflow | account_id（实际到账） | refund_kind、affects_spending必需 |

refund_kind=merchant_refund|transfer_return；默认affects_spending分别true/false。严格布尔，不接受null或字符串。手动POST只接受前三行；M4内部命令可携带已验证SourceRecord创建refund，HTTP手动入口不能伪造此证明。非refund携退款字段422；original_transaction_id不是合法字段。

公共字段：amount_minor、occurred_at、category_code（缺省other）、merchant、note；可选source_account_profile_id表示本人明确声明平台账号来源。M3验证source profile、Account均本人可写；内部transfer两端都本人可写、资金为本人流动，等额反向。历史交易仍保存，不生成历史端资金影响。

POST例：

```json
{"type":"expense","accounting_semantics":"ordinary","account_id":"a","amount_minor":2580,"occurred_at":"2026-10-20T12:30:00+08:00","category_code":"other","merchant":"午餐","note":""}
```

响应data含transaction（全部公开业务字段、version）、account_effects（account_id、role=primary|from|to、status=applied|historical_only、signed_amount_minor）、fund_shares摘要、notices。notice可为OWN_SAVINGS_USED或PARTNER_SAVINGS_USED及金额，提醒不意味着债务。

详情额外含source_summaries数组：source_record_id、platform、只读source_occurred_at、可展示来源摘要；本人可看必要证据，对象不返回raw_fields、对方账号或batch下载信息。列表支持from/to（北京时间包含边界日期）、type、account_id、category_code、q、limit/cursor。

### 4.2 编辑白名单

PATCH带version；公共可编辑金额、occurred_at、category_code、merchant、note、适用账户字段。普通交易可在前三类间变更且同时提供合法组合。已有refund不能改type、accounting_semantics、refund_kind或来源时间，仅公共字段、account_id、affects_spending可编辑。源时间/原始字段只读；不接受手动普通类型变refund。

退款编辑例：

```json
{"occurred_at":"2026-08-15T12:00:00+08:00","affects_spending":false,"version":3}
```

响应返回新transaction/version、source_summaries、account_effects与affected_months。仅开关不改资金；仅改日期且effect历史/有效状态不变保留份额计划；跨起始日撤销/生成本交易影响。金额/账户变化按业务规则处理，非法或撤销导致份额负值整笔409，不重算后续全部交易。

DELETE使用If-Match携当前version，版本不匹配409；仅撤销当前交易，保留并解关联来源。新导入操作可恢复；删除消费不删refund。失败原子回滚，不留下空资金或悬空当前关联。

## 5. M4：导入、恢复、去重与展示

### 5.1 上传与来源档案

POST /imports上传file，可带source_account_profile_id与Idempotency-Key。自动判平台/文件格式，读取原始全部行。返回batch_id与version，即使档案未定仍保存本人批次和观察，返回profile_candidates与rows，不需要重复上传。无法读取的文件返回422 UNSUPPORTED_SOURCE_FILE；其余可读文件按行表达失败，不把一行错误当整批成功。

档案规则：明确外部标识匹配已有本人档案则复用；无标识且只有一个本人同平台档案可按既有选择复用并保留证据；多个候选不明时needs_review，首次则返回可创建选项。不能把昵称当永久ID。用户在现有resolutions中选择已有profile，或提供create_label创建本人档案，不新增独立档案管理页面。

### 5.2 逐行结果

GET /imports/{batchId}?limit=...&cursor=...返回batch公共头、全批summary、分页rows、独立reconciliation_items及其游标。每行含：observation_id、row_number、可空source_record_id、phase、disposition、reason_codes、evidence、candidate、可空transaction_id、allowed_actions。candidate不是已保存交易。

phase限定file_read/profile_resolution/normalization/account_resolution/transaction_resolution/posted；disposition为created、linked_existing、duplicate_existing、unsupported、ineffective、needs_review、failed。批次同步处理一次后返回completed或needs_review（存在needs_review/failed），无法完成批次返回failed；unsupported和ineffective为终态且明确展示，不能称为成功入账。

summary包含read_rows、created、linked_existing、duplicate_existing、unsupported、ineffective、needs_review、failed。read_rows=parsed_record_count=七类合计。manual_transactions_not_found/reconciliation_items_rechecked另计，不能填补行数。phase和来源观察状态更新不参与计数加法。补处理后以当前各行结果重新汇总，不累计加两次created。

示例（虚构ID）：

```json
{
  "data": {
    "batch_id":"b", "platform":"wechat", "status":"needs_review", "version":1,
    "source_account_profile":{"id":"p","label":"微信账号"},
    "summary":{"read_rows":1,"created":0,"linked_existing":0,"duplicate_existing":0,"unsupported":0,"ineffective":0,"needs_review":1,"failed":0,"manual_transactions_not_found":0,"reconciliation_items_rechecked":0},
    "coverage":{"structural_complete":true,"declared_from":"2026-09-01T00:00:00+08:00","declared_to":"2026-09-30T23:59:59+08:00","exported_at":"2026-09-30T20:00:00+08:00","effective_from":"2026-09-01T00:00:00+08:00","effective_to":"2026-09-30T20:00:00+08:00","declared_record_count":1,"parsed_record_count":1,"reconciliation_eligible":false,"blockers":["SOURCE_MAPPING_REQUIRED"]},
    "rows":[{"observation_id":"o","row_number":32,"source_record_id":"s","phase":"account_resolution","disposition":"needs_review","reason_codes":["SOURCE_MAPPING_REQUIRED"],"evidence":{"source_kind":"商户-退款","source_status":"已退款¥0.70","account_evidence":"支付方式=零钱"},"candidate":{"type":"refund","accounting_semantics":"refund_inflow","amount_minor":44,"source_occurred_at":"2026-09-27T12:08:36+08:00","occurred_at":"2026-09-27T12:08:36+08:00","account_hint":"微信零钱","account_id":null,"refund_kind":"merchant_refund","affects_spending":true},"transaction_id":null,"allowed_actions":[]}],
    "reconciliation_items":[]
  },
  "page":{"next_cursor":null,"reconciliation_next_cursor":null}
}
```

allowed_actions只列当前可执行动作；上例先通过PUT补映射，GET刷新后可出现create_transaction，未补齐前不允许创建。

### 5.3 账户映射与resolution

GET映射按source_account_profile_id过滤。PUT请求source_account_profile_id、canonical_method_key、account_id、可选已有映射version；首次创建无version，更新必需。唯一(profile,key)，钱包与档案对应，不允许不同账号钱包串用；银行卡跨档案可经确认映射同一Account。目标只允许当前用户账户。更新只影响后续/未完成来源，不追改已入账交易。

POST /imports/{batchId}/resolutions请求action与version（batch版本），行操作带observation_id；已存在source时同时验证其当前身份，防止旧页面处理错来源。batch响应包含version，接受的resolution更新版本；过期页面返回409。

| action | 输入 | 行为 |
|---|---|---|
| select_source_profile | profile_id或create_label，二选一 | 仅profile未定的batch可用；验证本人同平台档案，建立/关联来源并重新评估。确定后同batch不换档案，避免变命名空间重复入账 |
| set_transfer_role | observation_id、type=income/expense/transfer及必要账户字段 | 只用于角色不明的转账行；与已知方向/账户证据一致，不能改普通消费或unsupported费用行 |
| create_transaction | observation_id | 服务端依据已识别来源和当前映射创建income/expense/transfer/**refund**；不能提交自造金额/原消费ID绕过来源 |
| link_existing_transaction | observation_id、transaction_id | 本人确认同一事件；type、方向、金额、账户组合兼容；refund只关联同一refund，不连原消费 |
| accept_source_change | observation_id | 用户确认以这次官方观察更新当前来源事实，仅更新来源并记录差异已确认，保留现有交易；需修正交易时另经M3编辑，不静默覆盖 |

映射补齐后在现有batch中create_transaction即可恢复，不重新上传。POSSIBLE_EXISTING_TRANSACTION时，此动作表示用户确认是另一笔新事件，可越过弱字段候选，但不能绕过稳定来源唯一性、账户权限和M3校验。同幂等键优先重放原结果；新键须先验证batch版本，过期返回409。版本有效且来源已成功时返回既有transaction_id，不重建。unsupported、ineffective、failed行不开放create/link账务动作，错误按原因修复文件/字段后新导入；role确认只用于普通转账。仅选择有效观察不允许忽略另一笔更晚官方事实；相同导出时刻冲突可通过accept_source_change选明一次观察。

### 5.4 执行顺序与原子性

读所有行并保存观察→确定profile→规范化并校验→处理最新来源状态→映射/角色解析→查已有稳定关联与同事件候选→对可创建行按记账时间升序调用M3→原子关联source→汇总。相同秒按official_transaction_id文本升序作为确定性次序；这是计算约定，不声称平台真实先后。首次导入不按Excel倒序逐行扣存款。新批次插入历史交易仍按当前有效资金规则处理，不重算已存在后续份额。

单笔业务事务涵盖M3账务与SourceRecord关联；批次允许部分行成功，其余明确失败/待处理，失败不回滚已完成的其他行。来源观察可先持久保存，不能因此报告created。并发版本和来源唯一约束保证同来源不重复创建。

同幂等键重试原结果；新导入操作即使文件相同也检查来源当前关联。存在有效交易duplicate_existing；交易被删/从未成功则重新处理。旧导出只留观察不覆盖新状态；同导出时刻冲突needs_review；已入账后官方重要事实改变needs_review。履约状态变化不重新入账，失败→成功且无交易则可创建。

### 5.5 核对范围及处理

coverage分别返回结构完整、声明范围、导出时刻、effective范围与核对资格；effective_to<=exported_at。声明/实读不符、源ID/时间不明或非全量则不核对。V1只要本batch有unsupported、needs_review或failed则reconciliation_eligible=false，仍展示/保存可处理行。

只核对明确属于该profile及实际账户、有效日期范围且无官方来源关联的手动交易。银行卡只有account_id不够，必须手动明确source_account_profile_id；已确认余额账户可由唯一映射确定。已有来源的退款不会因编辑occurred_at生成缺失提示。

POST reconciliation-reviews带reconciliation_item_id、action=keep_manual|delete_manual_transaction、version。keep仅改核对状态；delete调用M3删除交易及自身资金影响，并原子关闭核对项。后续匹配来源自动结案。重复范围复用同一项、只新建项首次提示，不自动删交易。

## 6. M5：统计与预算

GET overview返回month、as_of_date、relationship_status、funds（my_liquid_minor、my_savings_minor、partner_liquid_minor、partner_savings_minor、visible_total_minor）、personal_spending、budget。未绑定对象份额为null，绑定后四类同屏；visible_total是可见合计，不代表全归本人。

personal_spending含expense_minor、refund_offset_minor、month_spent_minor（前两者之差，允许负）、daily_average_minor、previous_month_daily_average_minor、daily_change_minor、daily_change_rate（可null）、projected_month_spending_minor。budget含budget_minor、spent_minor、remaining_minor、over_budget_minor、status=within_budget|over_budget；预算未设置时budget=null。

计算范围、天数与舍入严格使用业务规则§6；as_of_date为当前月今天、历史月末日；账户funds是当前可见资金，不伪装成历史月余额。预算PUT含budget_minor、已有资源version；初次创建无version，返回新version。本人交易统计不混对象消费。

## 7. 错误与权限校验

| HTTP | code | 含义 |
|---|---|---|
| 400 | BAD_REQUEST | 请求无法解析 |
| 401 | UNAUTHENTICATED | 未登录 |
| 403 | FORBIDDEN | 已知可读但不可写资源 |
| 404 | RESOURCE_NOT_FOUND | 资源不存在或不可向本人暴露 |
| 409 | RESOURCE_VERSION_CONFLICT | 资源版本冲突 |
| 409 | IDEMPOTENCY_KEY_CONFLICT | 同键不同请求 |
| 409 | FUNDS_ALLOCATION_NOT_POSSIBLE | 新增/撤销/编辑导致份额不足，整笔失败 |
| 409 | OPENING_STATE_RECALCULATION_CONFLICT | 无法安全重建起始状态 |
| 422 | VALIDATION_ERROR | 金额、时间、枚举、字段或组合非法 |
| 422 | REFUND_REQUIRES_OFFICIAL_SOURCE | 手动入口试图创建refund |
| 422 | UNSUPPORTED_SOURCE_FILE | 无法识别或读取文件 |

行reason不是HTTP失败：SOURCE_PROFILE_REQUIRED、SOURCE_MAPPING_REQUIRED、ACCOUNT_EVIDENCE_CONFLICT、TRANSFER_ROLE_REQUIRED、POSSIBLE_EXISTING_TRANSACTION、UNSUPPORTED_PAYMENT_METHOD、TRANSFER_FEE_UNSUPPORTED、UNKNOWN_SOURCE_STATE、INVALID_SOURCE_FIELDS、SOURCE_FACT_CONFLICT。行错误/待处理均附行号、证据和allowed_actions。不存在退款原消费错误码。

batch、observation、source、profile、mapping、account、existing_transaction逐项校验本人归属和关联；绑定不绕过。所有M3写路径统一校验账户权限、资金非负、份额/effect守恒及版本。技术实现、安全凭据、SQL、事务框架见实施阶段，不在候选契约假设已运行。
