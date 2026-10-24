# 星账｜API契约

候选HTTP契约，尚无已部署API。依据[业务规则](BUSINESS_RULES_DISCUSSION.md)、[逻辑模型](LOGICAL_DATA_MODEL.md)，模块职责见[模块边界](ENGINEERING_MODULE_BOUNDARIES.md)。

## 1. 通用规则

前缀/api/v1。JSON请求响应，导入文件用multipart。ID为不透明字符串；金额整数分，交易amount_minor严格正整数，初始余额/预算非负，账户影响用带符号整数。日期YYYY-MM-DD，月份YYYY-MM；时间RFC3339必须带偏移，服务端规范化为+08:00解释日期/月界。记账时间不得未来。

写接口需要认证，不以user_id授权。view=mine默认，view=partner只允许明确开放的账户、账单只读查询；不能通过绑定写对方账本。逐项校验资源归属与关联，不只校验URL中的batch。

成功为data，列表带page.next_cursor；所有HTTP错误统一为顶层code、message两个字段，不再保留error外壳。行级reason_codes是成功读取导入结果中的业务内容，不是另一套HTTP错误结构。不存在或不应暴露的资源返回404；已明确可读但不可写的对象资源返回403。

GET只读取，不修改交易、来源处理状态、核对状态或预算。POST/PUT/PATCH/DELETE为写操作，必须逐接口说明副作用和失败状态。所有账务操作的“成功全生效、失败不留半笔账”是业务要求，不在API里指定实现技术。

已有幂等头、版本比较等技术能力改为**候选待确认**，本轮先在§4两个试点接口中写清启用/不启用的对外差异。选择及依赖只记录在实施计划§5的D1–D3；不是应用运行时开关，也不是替用户默认启用。其他接口中的幂等/版本描述同样是待复核候选，不能据此开始实现；当选择确定后，只保留选定行为再转OpenAPI。

Authorization统一使用Bearer凭据作为调用格式；这里只约定传输形式，不选择登录供应商、签发或存储组件。缺失/无效凭据401；本人可读的对象资源不可写403；不可见/不存在资源404。

HTTP错误结构：

```json
{"code":"VALIDATION_ERROR","message":"amount_minor必须为正整数分。"}
```

错误含HTTP状态码与稳定code，message只供显示，不作为客户端分支条件，不包含内部堆栈、原始账单或敏感凭据。字段名和原因可放message，暂不新增复杂错误明细结构。对于已明确失败的请求，返回错误前不得留下本次账务修改；网络超时/连接断开表示客户端尚不确定结果，不能据此认定服务器已回滚。网关/代理返回非本契约错误体的5xx也属于结果未知；提交已完成但响应失败时，不伪称业务已回滚。

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

PUT opening-state带全部初始字段；version前置比较为D3候选，原子重建本账户受影响交易的历史/有效状态，其他账户不改。不能安全重建则409 OPENING_STATE_RECALCULATION_CONFLICT。账户余额不通过覆盖字段修正。

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

### 4.2 接口契约：手动创建交易

#### 基础信息

- 方法 + 路径：`POST /api/v1/transactions`
- 用途：在本人账本创建一笔普通收入、支出或无费内部转账。
- 是否修改数据库：是。
- 状态：业务行为可审阅；重试保护D1与实现方案D2待用户选择，不是已部署接口。

#### 请求

请求头：`Authorization: Bearer <token>`必需；`Idempotency-Key`仅D1选定启用后必需。Content-Type为application/json。

| 参数名 | 类型 | 是否必填 | 约束 & 说明 |
|---|---|---|---|
| type | string | 是 | income/expense/transfer；禁止refund |
| accounting_semantics | string | 是 | income/expense用ordinary，transfer用internal_transfer；不接受其他组合 |
| amount_minor | integer | 是 | 正整数分；拒绝0、负值、布尔、字符串；不得用浮点累计金额 |
| occurred_at | string | 是 | 带偏移RFC3339，不晚于服务器当前时刻；按+08:00解释日期/月界 |
| account_id | string | 条件必填 | income/expense必填，transfer禁止；本人可写实际账户 |
| from_account_id | string | 条件必填 | transfer必填；本人流动资金转出账户 |
| to_account_id | string | 条件必填 | transfer必填；本人可写转入账户；与from不同 |
| category_code | string | 否 | 缺省other；必须来自分类字典；transfer归other、不计消费 |
| merchant | string | 否 | 缺省空字符串，空字符串允许，null拒绝 |
| note | string | 否 | 缺省空字符串，空字符串允许，null拒绝 |
| source_account_profile_id | string | 否 | 仅声明本人平台账号来源，缺省不声明；不是官方来源证明，不创建SourceRecord |

条件必填以本表为准；未列字段（含user_id、balance、refund_kind、affects_spending、original_transaction_id、source_record_id、version）拒绝422，不静默忽略。首次创建不要求客户端提供交易版本。

请求示例：

```json
{"type":"expense","accounting_semantics":"ordinary","account_id":"account-a","amount_minor":2580,"occurred_at":"2026-10-20T12:30:00+08:00","category_code":"other","merchant":"午餐","note":""}
```

#### 响应

成功：首次创建返回201；若D1启用，同键相同请求重放原201及相同交易ID，不再创建。

以下场景为虚构账户，初始本人流动资金500000分，记账起始日2026-10-01，无其他交易：

```json
{
  "data": {
    "transaction":{"id":"transaction-a","type":"expense","accounting_semantics":"ordinary","amount_minor":2580,"occurred_at":"2026-10-20T12:30:00+08:00","account_id":"account-a","category_code":"other","merchant":"午餐","note":"","version":1},
    "account_effects":[{"account_id":"account-a","role":"primary","status":"applied","signed_amount_minor":-2580}],
    "fund_shares":[{"account_id":"account-a","balance_minor":497420,"shares":[{"fund_owner":"self","fund_type":"liquid","amount_minor":497420}]}],
    "notices":[]
  }
}
```

transaction是已保存事实；account_effects表示本笔账户影响；fund_shares是本次完成时的账户结果；notices仅展示存款使用提醒，不表示建立债务。source_summaries不由手动请求创建，之后有官方关联时在详情返回。

错误统一为code/message；典型错误：HTTP422。

```json
{"code":"VALIDATION_ERROR","message":"amount_minor必须大于0。"}
```

| HTTP | code | 条件 | 本次业务状态 |
|---|---|---|---|
| 401 | UNAUTHENTICATED | 未提供有效凭据 | 不修改任何账务 |
| 403/404 | FORBIDDEN / RESOURCE_NOT_FOUND | 对象资源不可写，或资源不可见/不存在 | 不创建交易或账户影响 |
| 422 | VALIDATION_ERROR | 金额/时间/字段/类型组合/分类不合法 | 不修改账务 |
| 422 | REFUND_REQUIRES_OFFICIAL_SOURCE | type=refund | 不创建退款或来源 |
| 409 | FUNDS_ALLOCATION_NOT_POSSIBLE | 当前份额无法完成支出/转账 | 不留下交易或单边转账 |
| 409 | IDEMPOTENCY_KEY_CONFLICT | 仅D1启用后：同键被用于不同请求 | 不执行新的请求；先前已成功操作不撤销 |
| 500 | INTERNAL_ERROR | 未预期内部失败，服务端明确返回操作失败 | 本次账务不生效；不返回内部异常原文 |

#### 前置条件与副作用

当前用户可写全部涉及账户；可选来源档案属于本人；内部转账只能用本人流动资金。历史交易允许保存。

成功新增一笔交易并产生适用账户影响；有效支出按既定顺序扣减，收入加本人流动资金，内部转账两端等额。历史端只保留影响事实、不增加有效资金变动。消费所在月份的花销/预算等查询随之反映新事实；不修改其他交易、对方账本、来源记录或关系绑定，不自动发消息。

#### 边界与失败行为

- 余额和份额不足不是部分扣款成功：整笔失败；内部转账不得只成功一端。D2未落实前不能实现此写接口并声称满足契约。
- 两端起始日分别判断；一端为历史不取消另一端的正常影响，不能拿当前余额总变化为0判断是否成功。
- D1未启用：相同POST重复提交可能创建两笔，客户端不得自动盲重试；D1启用：同键重放、不同键视为新的意图，不能用金额/商户相同去重。具体启用选择仍待确认。
- 返回成功后才发生客户端断网，不会撤销已经完成的交易；超时/断连没有明确失败结论。D1未启用时先查询核对，不能承诺“重试必安全”。
- 同时提交的支出都必须维持账户/份额非负，不能各自依据旧余额成功后留下错误结果；如何做到由实施方案决定，不在契约引入分布式锁。

#### 验收场景

| 给定 | 动作 | 预期 |
|---|---|---|
| 流动500000分、已进入记账期 | 支出2580分 | 201；余额/流动497420；消费增加2580 |
| 流动10000、本人存款10000、对象存款10000 | 支出25000 | 余额5000，对象存款剩5000，提示使用存款 |
| 交易早于账户起始日 | 创建支出 | 201；历史可查/计消费，当前余额不变 |
| 转入账户不属于本人 | 创建内部转账 | 403或404；两端均不改变 |
| 金额为0、null或字符串 | 创建 | 422；没有部分记录 |
| type=refund | 手动创建 | 422 REFUND_REQUIRES_OFFICIAL_SOURCE |
| D1启用且第一次已成功 | 相同键重试 | 相同交易ID，不再扣款 |
| D1关闭且第一次结果未知 | 再次POST | 可能重复，不能写成安全重试 |

### 4.3 接口契约：编辑已有退款

#### 基础信息

- 方法 + 路径：`PATCH /api/v1/transactions/{transactionId}`
- 用途：修改本人已存在官方退款的允许字段；本试点覆盖该通用PATCH在refund类型下的行为，不新建退款专用路由。
- 是否修改数据库：有实际变化时是；空改动不修改。
- 状态：业务行为可审阅；并发编辑保护D3与实现方案D2待用户选择。

#### 请求

请求头：`Authorization: Bearer <token>`必需。本接口暂不另要求Idempotency-Key；结果不确定时先GET确认，不自动重复提交旧版本。

| 参数名 | 类型 | 是否必填 | 约束 & 说明 |
|---|---|---|---|
| transactionId | string，路径 | 是 | 本人可写且type=refund的有效交易 |
| version | integer | D3启用时是 | 正整数，读取到的当前版本；D3关闭方案不提交此字段；响应仍可保留版本元数据；最终只保留选定方案 |
| occurred_at | string | 否 | 带偏移、不得未来；记账日期，非官方原始时间 |
| affects_spending | boolean | 否 | 是否抵减本记账月份花销；null/字符串false拒绝 |
| amount_minor | integer | 否 | 正整数分；变更需安全撤销自身旧影响再处理新影响 |
| account_id | string | 否 | 本人可写实际到账账户；不改原始渠道证据 |
| category_code | string | 否 | 受控分类，缺省是“不修改”，不是重置other |
| merchant | string | 否 | 空字符串允许清空；null拒绝 |
| note | string | 否 | 空字符串允许清空；null拒绝 |

所有编辑字段均可省略，省略表示保持原值。空对象/仅版本且未修改任何业务值属于空改动。禁止提交type、accounting_semantics、refund_kind、source_occurred_at、raw_fields、original_transaction_id及其他未列字段。

请求示例：读取版本3，将记账日期改到8月并关闭抵减。

```json
{"occurred_at":"2026-08-15T12:00:00+08:00","affects_spending":false,"version":3}
```

#### 响应

成功200；实际变更返回新的version；空改动返回现有version、不制造新的资金影响。D3启用时先校验版本，旧版本即使请求值相同也409，不以空改动绕过冲突。

虚构示例：原记账时间2026-09-27，官方源时间不变；账户起始日2026-08-01，两次日期均有效，金额44分。

```json
{
  "data": {
    "transaction":{"id":"refund-a","type":"refund","accounting_semantics":"refund_inflow","account_id":"account-a","amount_minor":44,"occurred_at":"2026-08-15T12:00:00+08:00","refund_kind":"merchant_refund","affects_spending":false,"category_code":"other","merchant":"商户","note":"","version":4},
    "source_summaries":[{"source_record_id":"source-a","platform":"wechat","source_occurred_at":"2026-09-27T12:08:36+08:00"}],
    "account_effects":[{"account_id":"account-a","role":"primary","status":"applied","signed_amount_minor":44}],
    "affected_months":["2026-08","2026-09"]
  }
}
```

错误统一code/message；典型错误：HTTP409（D3启用时）。

```json
{"code":"RESOURCE_VERSION_CONFLICT","message":"这笔退款已被修改，请刷新后再编辑。"}
```

| HTTP | code | 条件 | 本次业务状态 |
|---|---|---|---|
| 401 | UNAUTHENTICATED | 无有效凭据 | 不修改 |
| 403/404 | FORBIDDEN / RESOURCE_NOT_FOUND | 无写权限、交易已删除或不可见 | 不创建替代交易，不恢复删除记录 |
| 422 | VALIDATION_ERROR | 非refund、不允许字段、null、非法日期/金额/账户组合 | 不修改交易/资金/来源 |
| 409 | RESOURCE_VERSION_CONFLICT | 仅D3启用后：版本已过期 | 不保存本次任何字段 |
| 409 | FUNDS_ALLOCATION_NOT_POSSIBLE | 改金额/账户/日期时无法安全撤销旧资金影响 | 本次编辑全部失败，保留原交易和资金 |
| 500 | INTERNAL_ERROR | 服务端明确返回内部失败 | 本次编辑不生效；不返回堆栈 |

#### 前置条件与副作用

退款已存在且有自己的官方来源；不要求原消费。本人有写权限，新到账账户也须本人可写。

- 仅改抵减开关：更新交易设置及对应月份花销/预算查询，不改到账金额和资金份额。
- 仅改日期、不跨任何账户起始日：保留原份额计划，更新其生效日期和受影响月份。
- 跨起始日：原子切换本退款历史/有效影响；可能改变当前余额，不承诺仅改统计。
- 改金额/账户：撤销本退款旧影响，再按当前基准/缺口规则处理新影响；不按支出金额增加规则扣钱。
- 不修改官方原始时间、渠道/状态/金额证据，不新建SourceRecord，不关联原消费，不重算后续全部交易，不修改对象账本。

#### 边界与失败行为

空改动仍检查认证、资源权限和字段合法性；D3开启时仍查版本。值为false与字段省略不同；空字符串与null不同。

若退款已被后续交易使用，跨起始日/减金额/改账户可能无法撤销，整次编辑失败，不出现“日期改了、钱没改”的状态。所有提交字段一起成功或一起失败。

编辑成功后重新导入同来源，不恢复旧记账日期/抵减开关。交易已删除则404，本接口不能暗中重建。恢复删除交易由新的官方导入操作完成。

D3关闭：本人手机/电脑同时改同一字段时，后成功请求可能覆盖先前改动；D3启用：只有当前版本可成功，另一请求409。对象只读不构成第二写入人。不自动合并相互冲突的修改。

网络超时/断连不代表编辑失败。先GET确认当前值/版本；即使D3启用也不能把所有重试都说成成功重放，重复旧版本可得到409。

#### 验收场景

| 给定 | 动作 | 预期 |
|---|---|---|
| refund金额44、抵减开启 | 仅关闭抵减 | 到账仍44、份额不变，相关月份不再抵减 |
| 退款日期在9月、账户起始8月1日 | 改到8月15日 | 当前余额/份额不变，统计月份调整，源时间仍9月 |
| 账户起始9月1日 | 日期从9月改到8月 | 安全则撤销当前余额中的该笔退款影响、保留历史记录；不能撤销则整笔409 |
| 当前version=4，D3启用 | 提交version=3 | 409，所有字段不变 |
| 当前值与请求完全一致 | 用当前版本提交 | 200，version不变，无新资金变动 |
| 省略affects_spending / 提交false | 分别编辑 | 前者保持，后者关闭；不能混为默认false |
| 提交字符串false或source_occurred_at | 编辑 | 422，无任何修改 |
| 退款已删除 | 编辑 | 404，不重建 |
| 修改成功后重导官方文件 | 新导入操作 | 保留用户编辑，不重复入账 |

### 4.4 未试点操作的共有规则

普通交易PATCH可在income/expense/transfer间变更，仍须合法账户/语义组合；已有refund不能改类型/子类型。DELETE使用版本条件的要求随D3统一选择，不能先行假设开启；仅撤销本交易，保留来源并解关联，消费不级联退款。普通交易、删除和其他写接口后续按试点格式补齐，未补齐不声称已完成全部行为契约。

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

GET映射按source_account_profile_id过滤。PUT请求source_account_profile_id、canonical_method_key、account_id、version按D3候选：启用时更新必需、首次创建无version；未选定前不实现该条件。唯一(profile,key)，钱包与档案对应，不允许不同账号钱包串用；银行卡跨档案可经确认映射同一Account。目标只允许当前用户账户。更新只影响后续/未完成来源，不追改已入账交易。

POST /imports/{batchId}/resolutions请求action；version（batch版本）作为D3候选条件，行操作带observation_id；已存在source时同时验证其当前身份，防止旧页面处理错来源。batch响应包含version，实际变更更新版本；D3启用时过期页面返回409。

| action | 输入 | 行为 |
|---|---|---|
| select_source_profile | profile_id或create_label，二选一 | 仅profile未定的batch可用；验证本人同平台档案，建立/关联来源并重新评估。确定后同batch不换档案，避免变命名空间重复入账 |
| set_transfer_role | observation_id、type=income/expense/transfer及必要账户字段 | 只用于角色不明的转账行；与已知方向/账户证据一致，不能改普通消费或unsupported费用行 |
| create_transaction | observation_id | 服务端依据已识别来源和当前映射创建income/expense/transfer/**refund**；不能提交自造金额/原消费ID绕过来源 |
| link_existing_transaction | observation_id、transaction_id | 本人确认同一事件；type、方向、金额、账户组合兼容；refund只关联同一refund，不连原消费 |
| accept_source_change | observation_id | 用户确认以这次官方观察更新当前来源事实，仅更新来源并记录差异已确认，保留现有交易；需修正交易时另经M3编辑，不静默覆盖 |

映射补齐后在现有batch中create_transaction即可恢复，不重新上传。POSSIBLE_EXISTING_TRANSACTION时，此动作表示用户确认是另一笔新事件，可越过弱字段候选，但不能绕过稳定来源唯一性、账户权限和M3校验。D1若启用，同幂等键优先重放原结果；D3若启用，新请求先比较batch版本，过期返回409。满足已选条件且来源已成功时返回既有transaction_id，不重建。unsupported、ineffective、failed行不开放create/link账务动作，错误按原因修复文件/字段后新导入；role确认只用于普通转账。仅选择有效观察不允许忽略另一笔更晚官方事实；相同导出时刻冲突可通过accept_source_change选明一次观察。

### 5.4 执行顺序与原子性

读所有行并保存观察→确定profile→规范化并校验→处理最新来源状态→映射/角色解析→查已有稳定关联与同事件候选→对可创建行按记账时间升序调用M3→原子关联source→汇总。相同秒按official_transaction_id文本升序作为确定性次序；这是计算约定，不声称平台真实先后。首次导入不按Excel倒序逐行扣存款。新批次插入历史交易仍按当前有效资金规则处理，不重算已存在后续份额。

一次来源入账的交易及来源关联一起成功或一起失败；批次允许部分行成功，其余明确失败/待处理，不能把批次失败误写成所有行都回滚。原始证据可已保存，但这不表示created。同一稳定来源不得生成第二笔有效交易。具体保存与并发技术由实施计划选择。

同幂等键重试原结果；新导入操作即使文件相同也检查来源当前关联。存在有效交易duplicate_existing；交易被删/从未成功则重新处理。旧导出只留观察不覆盖新状态；同导出时刻冲突needs_review；已入账后官方重要事实改变needs_review。履约状态变化不重新入账，失败→成功且无交易则可创建。

### 5.5 核对范围及处理

coverage分别返回结构完整、声明范围、导出时刻、effective范围与核对资格；effective_to<=exported_at。声明/实读不符、源ID/时间不明或非全量则不核对。V1只要本batch有unsupported、needs_review或failed则reconciliation_eligible=false，仍展示/保存可处理行。

只核对明确属于该profile及实际账户、有效日期范围且无官方来源关联的手动交易。银行卡只有account_id不够，必须手动明确source_account_profile_id；已确认余额账户可由唯一映射确定。已有来源的退款不会因编辑occurred_at生成缺失提示。

POST reconciliation-reviews带reconciliation_item_id、action=keep_manual|delete_manual_transaction；version比较属于D3候选。keep仅改核对状态；delete调用M3删除交易及自身资金影响，并原子关闭核对项。后续匹配来源自动结案。重复范围复用同一项、只新建项首次提示，不自动删交易。

## 6. M5：统计与预算

GET overview返回month、as_of_date、relationship_status、funds（my_liquid_minor、my_savings_minor、partner_liquid_minor、partner_savings_minor、visible_total_minor）、personal_spending、budget。未绑定对象份额为null，绑定后四类同屏；visible_total是可见合计，不代表全归本人。

personal_spending含expense_minor、refund_offset_minor、month_spent_minor（前两者之差，允许负）、daily_average_minor、previous_month_daily_average_minor、daily_change_minor、daily_change_rate（可null）、projected_month_spending_minor。budget含budget_minor、spent_minor、remaining_minor、over_budget_minor、status=within_budget|over_budget；预算未设置时budget=null。

计算范围、天数与舍入严格使用业务规则§6；as_of_date为当前月今天、历史月末日；账户funds是当前可见资金，不伪装成历史月余额。预算PUT含budget_minor；已有资源的version比较为D3候选，首次创建无version；实际变更返回新version。本人交易统计不混对象消费。

## 7. 错误与权限校验

| HTTP | code | 含义 |
|---|---|---|
| 400 | BAD_REQUEST | 请求无法解析 |
| 401 | UNAUTHENTICATED | 未登录 |
| 403 | FORBIDDEN | 已知可读但不可写资源 |
| 404 | RESOURCE_NOT_FOUND | 资源不存在或不可向本人暴露 |
| 409 | RESOURCE_VERSION_CONFLICT | D3启用后的资源版本冲突 |
| 409 | IDEMPOTENCY_KEY_CONFLICT | D1启用后同键不同请求 |
| 409 | FUNDS_ALLOCATION_NOT_POSSIBLE | 新增/撤销/编辑导致份额不足，整笔失败 |
| 409 | OPENING_STATE_RECALCULATION_CONFLICT | 无法安全重建起始状态 |
| 422 | VALIDATION_ERROR | 金额、时间、枚举、字段或组合非法 |
| 422 | REFUND_REQUIRES_OFFICIAL_SOURCE | 手动入口试图创建refund |
| 422 | UNSUPPORTED_SOURCE_FILE | 无法识别或读取文件 |

行reason不是HTTP失败：SOURCE_PROFILE_REQUIRED、SOURCE_MAPPING_REQUIRED、ACCOUNT_EVIDENCE_CONFLICT、TRANSFER_ROLE_REQUIRED、POSSIBLE_EXISTING_TRANSACTION、UNSUPPORTED_PAYMENT_METHOD、TRANSFER_FEE_UNSUPPORTED、UNKNOWN_SOURCE_STATE、INVALID_SOURCE_FIELDS、SOURCE_FACT_CONFLICT。行错误/待处理均附行号、证据和allowed_actions。不存在退款原消费错误码。

batch、observation、source、profile、mapping、account、existing_transaction逐项校验本人归属和关联；绑定不绕过。所有M3写路径统一校验账户权限、资金非负、份额/effect守恒及已选定的版本条件。技术实现、安全凭据、SQL、事务框架见实施阶段，不在候选契约假设已运行。
