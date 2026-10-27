# 星账｜完整公开API契约

范围：当前V1的24个HTTP操作，按M1–M5归属；当前没有已部署API。字段严格结构见[openapi.yaml](../openapi.yaml)，业务规则见[业务规则](BUSINESS_RULES_DISCUSSION.md)，流程见[产品功能](PRODUCT_FUNCTION_MAP.md)和[模块边界](ENGINEERING_MODULE_BOUNDARIES.md)。不描述未来截图/负债/费用转账或内部函数的HTTP接口。

## 1. 通用行为

所有业务API需要Authorization: Bearer <token>；身份来自服务端验证，不接受user_id授权。登录、注册、刷新和退出由选定认证服务/SDK负责，不虚构本仓库已有登录服务。客户端取得有效凭据后即可调用；401应交认证流程处理，不能盲重试写请求。

GET没有业务数据库修改副作用。成功响应data；集合有page.next_cursor；导入行和核对项使用独立游标。所有HTTP错误只有code、message，HTTP状态独立表达；导入成功响应内的行reason不是HTTP错误。未登录401、可读但不可写对象403、不存在/不可见404。后端细节与敏感原文不写进错误。

```json
{"code":"VALIDATION_ERROR","message":"amount_minor必须为正整数分。"}
```

ID是不透明字符串；货币为整数分，交易金额严格为正，预算/初始分配非负，禁止布尔/字符串冒充金额。日期/月份按北京时间，日期时间必须带偏移，源Excel时间按平台本地+08:00规范化，不当UTC。记账日期不得未来。受控分类other兜底，空字符串与null、PATCH省略与false各自有区别。请求除明确字段外拒绝422。

**选定的共同写入行为：** 采用支持原生事务与适当并发控制的单库；一次交易及其资金/来源关联一起成功或失败。批次可部分行成功，失败行不冒充成功。幂等用于有重复执行风险的POST，Idempotency-Key作用域为本人+方法+路径，保留24小时；JSON补齐该接口默认值后比较，字段顺序无关。同键同请求重放原HTTP状态/结果（不是当前资源快照），同键不同请求409 IDEMPOTENCY_KEY_CONFLICT，进行中409 REQUEST_IN_PROGRESS；过期不保证避免重复。用户新操作使用新键。

资源编辑/删除用目标资源If-Match强ETag，例如"3"，缺失428、过期412 RESOURCE_VERSION_CONFLICT。返回单资源及变更响应含ETag；版本有效的空改动200、version不变。先处理幂等重放再比较当前版本。来源行、核对项、映射和预算比较自己的expected_version；0仅表示指定资源新建。批次profile_version只控制首次选档案，不串行化所有行。

事务、幂等与版本比较分别保证整笔一致、同意图重试与旧页面覆盖保护，不替代彼此。不引入Redis、MQ、分布式锁或运行时能力开关。超时/断连/非本契约网关错误表示结果未知；不能据此认定回滚。已提交但响应发送失败不伪报“已回滚”。查询/同键确认结果后再决定新操作。应用明确失败不得留下本次半笔账。

account_type统一命名；accounting_semantics由type固定派生并只在响应/内部命令出现，不让客户端重复选择。应用用例协调交易、资金及来源关联一次提交；资金规则及记录归M2，交易与effects归M3。M5查询读取正式结果，查询失败不改变已提交写入。Transaction只在M3账务能力保存；M4自动/恢复创建refund都不经过手动POST入口，不新增独立退款路由。

## 2. 全量操作索引

| operationId | 模块 | 方法与路径 | 使用环节 |
|---|---|---|---|
| `getRelationship` | M1 | GET /api/v1/relationship | 登录后进入我的/决定对象查看入口 |
| `createBindingInvitation` | M1 | POST /api/v1/relationship/invitations | 未绑定用户发起关系绑定 |
| `bindRelationship` | M1 | POST /api/v1/relationship/binding | 接收方输入对方凭据并确认 |
| `listAccounts` | M2 | GET /api/v1/accounts | 账户页、记账选账户、导入映射 |
| `getAccount` | M2 | GET /api/v1/accounts/{accountId} | 查看账户或打开编辑表单 |
| `createAccount` | M2 | POST /api/v1/accounts | 首次使用或新增银行卡/钱包 |
| `patchAccount` | M2 | PATCH /api/v1/accounts/{accountId} | 账户页改名或保管关系 |
| `putOpeningState` | M2 | PUT /api/v1/accounts/{accountId}/opening-state | 发现初始金额或日期填错 |
| `adjustFunds` | M2 | POST /api/v1/accounts/{accountId}/fund-adjustments | 把存款转流动或调整资金归属 |
| `listTransactions` | M3 | GET /api/v1/transactions | 账单页筛选/搜索或确认超时结果 |
| `getTransaction` | M3 | GET /api/v1/transactions/{transactionId} | 详情、编辑前读取或确认编辑结果 |
| `createTransaction` | M3 | POST /api/v1/transactions | 手动记账提交 |
| `patchTransaction` | M3 | PATCH /api/v1/transactions/{transactionId} | 账单页编辑保存 |
| `deleteTransaction` | M3 | DELETE /api/v1/transactions/{transactionId} | 账单详情删除 |
| `listCategories` | M3 | GET /api/v1/transaction-categories | 手动记账/编辑分类选择 |
| `uploadImport` | M4 | POST /api/v1/imports | 选择官方账单文件 |
| `getImport` | M4 | GET /api/v1/imports/{batchId} | 导入后查看/刷新阶段内容 |
| `resolveImport` | M4 | POST /api/v1/imports/{batchId}/resolutions | 档案选择、批次继续、角色确认或同事件确认 |
| `listMappings` | M4 | GET /api/v1/source-payment-method-mappings | 导入需要选择实际账户 |
| `putMapping` | M4 | PUT /api/v1/source-payment-method-mappings | 用户选择一次渠道实际账户 |
| `reviewReconciliation` | M4 | POST /api/v1/imports/{batchId}/reconciliation-reviews | 用户保留或删除核对账单 |
| `getOverview` | M5 | GET /api/v1/overview | 登录后首页/切换历史月份 |
| `getBudget` | M5 | GET /api/v1/budgets/{month} | 预算表单读取/未来预算查看 |
| `putBudget` | M5 | PUT /api/v1/budgets/{month} | 首页/预算表单保存 |

## 3. 共用字段与完整实例

请求/响应schema名称直接链接机器契约components.schemas；必填、条件组合、additionalProperties=false、枚举与null以机器契约严格表达，业务条件在各接口下说明。查询必须绑定游标与相同筛选/视图，limit缺省50、范围1–100；筛选变化不能复用旧游标。

手动支出请求示例（无客户端accounting_semantics）：

```json
{"type":"expense","account_id":"account-a","amount_minor":2580,"occurred_at":"2026-10-20T12:30:00+08:00","category_code":"other","merchant":"午餐","note":""}
```

退款PATCH示例，If-Match头传"3"，不在请求体重复version：

```json
{"occurred_at":"2026-08-15T12:00:00+08:00","affects_spending":false}
```

Transaction响应区分income/expense/transfer/refund四种封闭结构，含派生semantics、version、read_only和source_summaries；对象视图source_summaries为空。Mutation响应含transaction、account_effects、account_changes、affected_months、notices。历史端effect为historical_only，无有效资金变动。退款源时间只读，抵减开关不动余额；不跨起始日改日期保留份额计划，跨起始日会切换当前余额影响。改金额/账户或删除不能安全撤销则409，全字段保留原状态。

Account返回完整opening_state供初始状态编辑，无需用户记住原始分配；当前余额/份额是计算结果。holder/custodian/fund_owner均相对当前登录查看者，内部保留真实用户ID；对象账户可显示其本人流动份额，但本人账户不允许配置对象流动份额。机器结构用OpeningStateView表达读取投影，开户/初始状态修正仍用OpeningState约束写入，禁止把读取到的对象流动份额直接用于本人账户写入。

ImportResponse含全批summary、coverage、profile候选及profile_version、分页rows/核对项。每行包含原始证据（含canonical_method_keys）、候选与缺失原因、source_version、transaction_id和allowed_actions；候选不是正式账单。Candidate返回单账户canonical_method_key或两端from_canonical_method_key/to_canonical_method_key，未定端为null；Evidence保留所有规范键，角色未定时不猜两端。客户端原样提交键到映射接口，不重新解析名称。batch.source_metadata展示本人文件头证据。七类行结果之和必须等于实读数，核对项另计。字段字典与真实样本限制见模块边界。

## 4. M1接口行为

### getRelationship｜查询绑定状态

- 方法 + 路径：`GET /api/v1/relationship`
- 使用环节：登录后进入我的/决定对象查看入口。
- 是否修改业务数据库：否。
- 请求：无请求体；路径/查询参数见机器契约；所有操作需要鉴权。
- 成功：HTTP200；响应结构以本operation的responses为准。


无请求体或额外查询参数。

成功返回：data：Relationship。嵌套字段、必填与互斥组合见[严格结构](../openapi.yaml)。

- 副作用：只返回本人当前关系与必要对象信息；不创建邀请或关系。
- 异常与边界：未绑定partner=null、权限none；不返回邀请凭据。
- 失败：本操作列出HTTP 401/403/404/422/500；统一Error；认证/字段/权限/前置版本失败不写业务数据。内部行执行结果与HTTP请求错误分开。

### createBindingInvitation｜生成绑定凭据

- 方法 + 路径：`POST /api/v1/relationship/invitations`
- 使用环节：未绑定用户发起关系绑定。
- 是否修改业务数据库：是；支持空改动的编辑操作不产生新版本。
- 请求：本操作requestBody（机器契约内联）；所有操作需要鉴权。 Idempotency-Key必需。
- 成功：HTTP201；响应结构以本operation的responses为准。


| 参数 | 位置 | 类型/合法值 | 必填 | 约束 |
|---|---|---|---|---|
| Idempotency-Key | header | string | 是 | 本人+方法+路径作用域；24小时内同键同规范化请求重放原结果；同键不同请求409；进行中409 REQUEST_IN_PROGRESS。过期不保证避免重复。 |

成功返回：data：BindingInvitation。嵌套字段、必填与互斥组合见[严格结构](../openapi.yaml)。

- 副作用：创建本人10分钟有效、一次性邀请；新意图使本人旧的未消费邀请失效；发起邀请表达绑定意愿。
- 异常与边界：已绑定409 RELATIONSHIP_CONFLICT；旧键只重放原token及原到期时间，不延期；凭据只经本人主动复制交给对方，不自动发送。
- 失败：本操作列出HTTP 400/401/403/404/409/422/500；统一Error；认证/字段/权限/前置版本失败不写业务数据。内部行执行结果与HTTP请求错误分开。
- 流程验收：正常路径检查以上副作用；非法字段/他人资源不变更；重复提交按本操作重试边界；版本冲突不覆盖；资金操作在故障时无半笔账。对应动作与真实字段验证见实施计划。

### bindRelationship｜确认并完成绑定

- 方法 + 路径：`POST /api/v1/relationship/binding`
- 使用环节：接收方输入对方凭据并确认。
- 是否修改业务数据库：是；支持空改动的编辑操作不产生新版本。
- 请求：BindRequest；所有操作需要鉴权。 Idempotency-Key必需。
- 成功：HTTP200；响应结构以本operation的responses为准。


| 参数 | 位置 | 类型/合法值 | 必填 | 约束 |
|---|---|---|---|---|
| Idempotency-Key | header | string | 是 | 本人+方法+路径作用域；24小时内同键同规范化请求重放原结果；同键不同请求409；进行中409 REQUEST_IN_PROGRESS。过期不保证避免重复。 |
| binding_token | 请求体 | string | 是 | minLength=1 |

成功返回：data：Relationship。嵌套字段、必填与互斥组合见[严格结构](../openapi.yaml)。

- 副作用：验证双方均未绑定、凭据非本人且有效，一次消费凭据并建立关系；不改变钱归属或历史账务。
- 异常与边界：过期/无效/本人凭据422 BINDING_INVITATION_INVALID；与其他人已绑定409；同一双方已成功的重试返回当前绑定，不再创建第二关系。
- 失败：本操作列出HTTP 400/401/403/404/409/422/500；统一Error；认证/字段/权限/前置版本失败不写业务数据。内部行执行结果与HTTP请求错误分开。
- 流程验收：正常路径检查以上副作用；非法字段/他人资源不变更；重复提交按本操作重试边界；版本冲突不覆盖；资金操作在故障时无半笔账。对应动作与真实字段验证见实施计划。

## 5. M2接口行为

### listAccounts｜查询账户列表

- 方法 + 路径：`GET /api/v1/accounts`
- 使用环节：账户页、记账选账户、导入映射。
- 是否修改业务数据库：否。
- 请求：无请求体；路径/查询参数见机器契约；所有操作需要鉴权。
- 成功：HTTP200；响应结构以本operation的responses为准。


| 参数 | 位置 | 类型/合法值 | 必填 | 约束 |
|---|---|---|---|---|
| view | query | mine / partner | 否 | 见本操作边界 |
| limit | query | integer | 否 | 见本操作边界 |
| cursor | query | string | 否 | 见本操作边界 |

成功返回：data：array；page：object。嵌套字段、必填与互斥组合见[严格结构](../openapi.yaml)。

- 副作用：只读当前余额/份额与初始状态；对象账户read_only=true。
- 异常与边界：空列表data=[]；不可用partner视图403；游标与本人/对象范围绑定。
- 失败：本操作列出HTTP 401/403/404/422/500；统一Error；认证/字段/权限/前置版本失败不写业务数据。内部行执行结果与HTTP请求错误分开。

### getAccount｜查询单个账户

- 方法 + 路径：`GET /api/v1/accounts/{accountId}`
- 使用环节：查看账户或打开编辑表单。
- 是否修改业务数据库：否。
- 请求：无请求体；路径/查询参数见机器契约；所有操作需要鉴权。
- 成功：HTTP200；响应结构以本operation的responses为准。


| 参数 | 位置 | 类型/合法值 | 必填 | 约束 |
|---|---|---|---|---|
| accountId | path | string | 是 | 见本操作边界 |

成功返回：data：Account。嵌套字段、必填与互斥组合见[严格结构](../openapi.yaml)。

- 副作用：返回当前计算份额和完整opening_state，供现有编辑表单使用。
- 异常与边界：不存在/不可见404；对象可读不可写，不反向赋予资金所有人写权限。
- 失败：本操作列出HTTP 401/403/404/422/500；统一Error；认证/字段/权限/前置版本失败不写业务数据。内部行执行结果与HTTP请求错误分开。

### createAccount｜创建实际账户

- 方法 + 路径：`POST /api/v1/accounts`
- 使用环节：首次使用或新增银行卡/钱包。
- 是否修改业务数据库：是；支持空改动的编辑操作不产生新版本。
- 请求：AccountCreate；所有操作需要鉴权。 Idempotency-Key必需。
- 成功：HTTP201；响应结构以本operation的responses为准。


| 参数 | 位置 | 类型/合法值 | 必填 | 约束 |
|---|---|---|---|---|
| Idempotency-Key | header | string | 是 | 本人+方法+路径作用域；24小时内同键同规范化请求重放原结果；同键不同请求409；进行中409 REQUEST_IN_PROGRESS。过期不保证避免重复。 |
| name | 请求体 | string | 是 | minLength=1；maxLength=80 |
| account_type | 请求体 | cash / bank_card / wechat_balance / alipay_balance / other | 是 | 合法组合及业务限制见下文 |
| custodian | 请求体 | self / partner | 否 | default=self |
| opening_state | 请求体 | OpeningState | 是 | 合法组合及业务限制见下文 |

成功返回：data：Account。嵌套字段、必填与互斥组合见[严格结构](../openapi.yaml)。

- 副作用：创建本人账户与初始分配，金额合计一致，不计收入；缺省custodian=self。
- 异常与边界：起始日未来/份额重复/合计不等422；partner份额仅绑定后savings；账户名称不作为去重键。
- 失败：本操作列出HTTP 400/401/403/404/409/422/500；统一Error；认证/字段/权限/前置版本失败不写业务数据。内部行执行结果与HTTP请求错误分开。
- 流程验收：正常路径检查以上副作用；非法字段/他人资源不变更；重复提交按本操作重试边界；版本冲突不覆盖；资金操作在故障时无半笔账。对应动作与真实字段验证见实施计划。

### patchAccount｜编辑账户基本信息

- 方法 + 路径：`PATCH /api/v1/accounts/{accountId}`
- 使用环节：账户页改名或保管关系。
- 是否修改业务数据库：是；支持空改动的编辑操作不产生新版本。
- 请求：AccountPatch；所有操作需要鉴权。 If-Match必需。
- 成功：HTTP200；响应结构以本operation的responses为准。


| 参数 | 位置 | 类型/合法值 | 必填 | 约束 |
|---|---|---|---|---|
| accountId | path | string | 是 | 见本操作边界 |
| If-Match | header | string | 是 | 目标资源的当前强ETag，例如"3"；缺失428、过期412；幂等重放先于版本比较。 |
| name | 请求体 | string | 否 | minLength=1；maxLength=80 |
| account_type | 请求体 | cash / bank_card / wechat_balance / alipay_balance / other | 否 | 合法组合及业务限制见下文 |
| custodian | 请求体 | self / partner | 否 | 合法组合及业务限制见下文 |

成功返回：data：Account。嵌套字段、必填与互斥组合见[严格结构](../openapi.yaml)。

- 副作用：只更新name/account_type/custodian，合法无变化保持version。
- 异常与边界：禁止余额、holder、fund_shares、opening_state字段；不能把已映射钱包改成不兼容类型；未绑定不能custodian=partner；过期412。
- 失败：本操作列出HTTP 400/401/403/404/409/412/422/428/500；统一Error；认证/字段/权限/前置版本失败不写业务数据。内部行执行结果与HTTP请求错误分开。
- 流程验收：正常路径检查以上副作用；非法字段/他人资源不变更；重复提交按本操作重试边界；版本冲突不覆盖；资金操作在故障时无半笔账。对应动作与真实字段验证见实施计划。

### putOpeningState｜修正初始状态

- 方法 + 路径：`PUT /api/v1/accounts/{accountId}/opening-state`
- 使用环节：发现初始金额或日期填错。
- 是否修改业务数据库：是；支持空改动的编辑操作不产生新版本。
- 请求：OpeningState；所有操作需要鉴权。 If-Match必需。
- 成功：HTTP200；响应结构以本operation的responses为准。


| 参数 | 位置 | 类型/合法值 | 必填 | 约束 |
|---|---|---|---|---|
| accountId | path | string | 是 | 见本操作边界 |
| If-Match | header | string | 是 | 目标资源的当前强ETag，例如"3"；缺失428、过期412；幂等重放先于版本比较。 |
| opening_date | 请求体 | string | 是 | 合法组合及业务限制见下文 |
| opening_balance_minor | 请求体 | integer | 是 | minimum=0 |
| opening_allocations | 请求体 | array | 是 | 合法组合及业务限制见下文 |

成功返回：data：Account。嵌套字段、必填与互斥组合见[严格结构](../openapi.yaml)。

- 副作用：整体替换初始状态、重建本账户受影响资金与历史/有效状态，其他账户和交易事实不改。
- 异常与边界：不能安全重建409 OPENING_STATE_RECALCULATION_CONFLICT并全部不生效；空改动version不变，不提供直接覆盖当前余额。
- 失败：本操作列出HTTP 400/401/403/404/409/412/422/428/500；统一Error；认证/字段/权限/前置版本失败不写业务数据。内部行执行结果与HTTP请求错误分开。
- 流程验收：正常路径检查以上副作用；非法字段/他人资源不变更；重复提交按本操作重试边界；版本冲突不覆盖；资金操作在故障时无半笔账。对应动作与真实字段验证见实施计划。

### adjustFunds｜调整账户内资金份额

- 方法 + 路径：`POST /api/v1/accounts/{accountId}/fund-adjustments`
- 使用环节：把存款转流动或调整资金归属。
- 是否修改业务数据库：是；支持空改动的编辑操作不产生新版本。
- 请求：FundAdjustment；所有操作需要鉴权。 Idempotency-Key必需。 If-Match必需。
- 成功：HTTP200；响应结构以本operation的responses为准。


| 参数 | 位置 | 类型/合法值 | 必填 | 约束 |
|---|---|---|---|---|
| accountId | path | string | 是 | 见本操作边界 |
| Idempotency-Key | header | string | 是 | 本人+方法+路径作用域；24小时内同键同规范化请求重放原结果；同键不同请求409；进行中409 REQUEST_IN_PROGRESS。过期不保证避免重复。 |
| If-Match | header | string | 是 | 目标资源的当前强ETag，例如"3"；缺失428、过期412；幂等重放先于版本比较。 |
| from | 请求体 | ShareRef | 是 | 合法组合及业务限制见下文 |
| to | 请求体 | ShareRef | 是 | 合法组合及业务限制见下文 |
| amount_minor | 请求体 | integer | 是 | minimum=1 |

成功返回：data：Account。嵌套字段、必填与互斥组合见[严格结构](../openapi.yaml)。

- 副作用：同账户等额调整当前份额和存款基准，余额不变，不记消费/收入；账户version递增。
- 异常与边界：from=to/非法份额422；来源不足409；对象账户不可写，不能把对象流动分配到本人账户。
- 失败：本操作列出HTTP 400/401/403/404/409/412/422/428/500；统一Error；认证/字段/权限/前置版本失败不写业务数据。内部行执行结果与HTTP请求错误分开。
- 流程验收：正常路径检查以上副作用；非法字段/他人资源不变更；重复提交按本操作重试边界；版本冲突不覆盖；资金操作在故障时无半笔账。对应动作与真实字段验证见实施计划。

## 6. M3接口行为

### listTransactions｜查询账单列表

- 方法 + 路径：`GET /api/v1/transactions`
- 使用环节：账单页筛选/搜索或确认超时结果。
- 是否修改业务数据库：否。
- 请求：无请求体；路径/查询参数见机器契约；所有操作需要鉴权。
- 成功：HTTP200；响应结构以本operation的responses为准。


| 参数 | 位置 | 类型/合法值 | 必填 | 约束 |
|---|---|---|---|---|
| view | query | mine / partner | 否 | 见本操作边界 |
| limit | query | integer | 否 | 见本操作边界 |
| cursor | query | string | 否 | 见本操作边界 |
| from | query | string | 否 | 见本操作边界 |
| to | query | string | 否 | 见本操作边界 |
| type | query | income / expense / transfer / refund | 否 | 见本操作边界 |
| account_id | query | string | 否 | 见本操作边界 |
| category_code | query | food / shopping / transport / education / health / entertainment / utilities / other | 否 | 见本操作边界 |
| q | query | string | 否 | 见本操作边界 |

成功返回：data：array；page：object。嵌套字段、必填与互斥组合见[严格结构](../openapi.yaml)。

- 副作用：只读保存事实，含historical_only账单；不标已核对、不写账。
- 异常与边界：from/to北京时间包含边界且from<=to；空列表[]；分页按occurred_at倒序与id确定次序；对象不返回来源证据数组。
- 失败：本操作列出HTTP 401/403/404/422/500；统一Error；认证/字段/权限/前置版本失败不写业务数据。内部行执行结果与HTTP请求错误分开。

### getTransaction｜查询单笔账单

- 方法 + 路径：`GET /api/v1/transactions/{transactionId}`
- 使用环节：详情、编辑前读取或确认编辑结果。
- 是否修改业务数据库：否。
- 请求：无请求体；路径/查询参数见机器契约；所有操作需要鉴权。
- 成功：HTTP200；响应结构以本operation的responses为准。


| 参数 | 位置 | 类型/合法值 | 必填 | 约束 |
|---|---|---|---|---|
| transactionId | path | string | 是 | 见本操作边界 |

成功返回：data：Transaction。嵌套字段、必填与互斥组合见[严格结构](../openapi.yaml)。

- 副作用：返回当前事实/版本及本人允许的来源摘要；不恢复已删除交易。
- 异常与边界：删除后404；对象read_only=true、source_summaries=[]。
- 失败：本操作列出HTTP 401/403/404/422/500；统一Error；认证/字段/权限/前置版本失败不写业务数据。内部行执行结果与HTTP请求错误分开。

### createTransaction｜手动创建交易

- 方法 + 路径：`POST /api/v1/transactions`
- 使用环节：手动记账提交。
- 是否修改业务数据库：是；支持空改动的编辑操作不产生新版本。
- 请求：ManualCreate；所有操作需要鉴权。 Idempotency-Key必需。
- 成功：HTTP201；响应结构以本operation的responses为准。


| 参数 | 位置 | 类型/合法值 | 必填 | 约束 |
|---|---|---|---|---|
| Idempotency-Key | header | string | 是 | 本人+方法+路径作用域；24小时内同键同规范化请求重放原结果；同键不同请求409；进行中409 REQUEST_IN_PROGRESS。过期不保证避免重复。 |
| 按类型选择一个完整结构 | 请求体 | ManualCreate | 是 | 条件必填字段见OpenAPI；不得混合不同类型字段 |

成功返回：data：Mutation。嵌套字段、必填与互斥组合见[严格结构](../openapi.yaml)。

- 副作用：统一M3创建income/expense/无费transfer；semantics按type派生，不让客户端选；有效端改变资金，历史端只保存事实；后续查询按新交易计算相关月份统计。
- 异常与边界：禁止refund和客户端accounting_semantics/user_id/余额/源证据；未来时间/同账户转账422；金额/份额不足整笔409；转账两端无单边成功；不同键代表新意图。
- 失败：本操作列出HTTP 400/401/403/404/409/422/500；统一Error；认证/字段/权限/前置版本失败不写业务数据。内部行执行结果与HTTP请求错误分开。
- 流程验收：正常路径检查以上副作用；非法字段/他人资源不变更；重复提交按本操作重试边界；版本冲突不覆盖；资金操作在故障时无半笔账。对应动作与真实字段验证见实施计划。

### patchTransaction｜编辑已有账单含退款

- 方法 + 路径：`PATCH /api/v1/transactions/{transactionId}`
- 使用环节：账单页编辑保存。
- 是否修改业务数据库：是；支持空改动的编辑操作不产生新版本。
- 请求：TransactionPatch；所有操作需要鉴权。 If-Match必需。
- 成功：HTTP200；响应结构以本operation的responses为准。


| 参数 | 位置 | 类型/合法值 | 必填 | 约束 |
|---|---|---|---|---|
| transactionId | path | string | 是 | 见本操作边界 |
| If-Match | header | string | 是 | 目标资源的当前强ETag，例如"3"；缺失428、过期412；幂等重放先于版本比较。 |
| type | 请求体 | income / expense / transfer | 否 | 合法组合及业务限制见下文 |
| amount_minor | 请求体 | integer | 否 | minimum=1 |
| occurred_at | 请求体 | string | 否 | pattern=^\d{4}-\d{2}-\d{2}T.*(?:Z / [+-]\d{2}:\d{2})$ |
| account_id | 请求体 | string | 否 | minLength=1 |
| from_account_id | 请求体 | string | 否 | minLength=1 |
| to_account_id | 请求体 | string | 否 | minLength=1 |
| category_code | 请求体 | food / shopping / transport / education / health / entertainment / utilities / other | 否 | 合法组合及业务限制见下文 |
| merchant | 请求体 | string | 否 | 合法组合及业务限制见下文 |
| note | 请求体 | string | 否 | 合法组合及业务限制见下文 |
| source_account_profile_id | 请求体 | string 或 null | 否 | 合法组合及业务限制见下文 |
| affects_spending | 请求体 | boolean | 否 | 合法组合及业务限制见下文 |

成功返回：data：Mutation。嵌套字段、必填与互斥组合见[严格结构](../openapi.yaml)。

- 副作用：省略字段保持；普通类型可在income/expense/transfer间变，refund保持类型/子类型；仅抵减不动资金，仅日期不跨起始日保留份额计划；返回受影响月份。
- 异常与边界：空对象/相同值不增版本但仍比较If-Match；null仅允许清空手动声明source_account_profile_id，其他字段不接受null；refund不能改type/子类型/源时间；普通交易不能改refund；撤销不安全409并保留全部原值；跨起始日会改变有效余额；不重算后续全部份额。
- 失败：本操作列出HTTP 400/401/403/404/409/412/422/428/500；统一Error；认证/字段/权限/前置版本失败不写业务数据。内部行执行结果与HTTP请求错误分开。
- 流程验收：正常路径检查以上副作用；非法字段/他人资源不变更；重复提交按本操作重试边界；版本冲突不覆盖；资金操作在故障时无半笔账。对应动作与真实字段验证见实施计划。

### deleteTransaction｜删除当前账单

- 方法 + 路径：`DELETE /api/v1/transactions/{transactionId}`
- 使用环节：账单详情删除。
- 是否修改业务数据库：是；支持空改动的编辑操作不产生新版本。
- 请求：无请求体；路径/查询参数见机器契约；所有操作需要鉴权。 If-Match必需。
- 成功：HTTP200；响应结构以本operation的responses为准。


| 参数 | 位置 | 类型/合法值 | 必填 | 约束 |
|---|---|---|---|---|
| transactionId | path | string | 是 | 见本操作边界 |
| If-Match | header | string | 是 | 目标资源的当前强ETag，例如"3"；缺失428、过期412；幂等重放先于版本比较。 |

成功返回：data：DeleteResult。嵌套字段、必填与互斥组合见[严格结构](../openapi.yaml)。

- 副作用：仅撤销本交易，解除其来源当前关联但保留观察；消费不级联独立退款。
- 异常与边界：不能安全撤销409，全部不删；不存在/已删除404；再次DELETE不会重复扣改资金；恢复由新导入操作完成，不建回收站。
- 失败：本操作列出HTTP 400/401/403/404/409/412/422/428/500；统一Error；认证/字段/权限/前置版本失败不写业务数据。内部行执行结果与HTTP请求错误分开。
- 流程验收：正常路径检查以上副作用；非法字段/他人资源不变更；重复提交按本操作重试边界；版本冲突不覆盖；资金操作在故障时无半笔账。对应动作与真实字段验证见实施计划。

### listCategories｜查询受控分类字典

- 方法 + 路径：`GET /api/v1/transaction-categories`
- 使用环节：手动记账/编辑分类选择。
- 是否修改业务数据库：否。
- 请求：无请求体；路径/查询参数见机器契约；所有操作需要鉴权。
- 成功：HTTP200；响应结构以本operation的responses为准。


无请求体或额外查询参数。

成功返回：data：array。嵌套字段、必填与互斥组合见[严格结构](../openapi.yaml)。

- 副作用：只读字典；other兜底，分类不决定资金方向。
- 异常与边界：不提供用户分类管理接口，不调用AI。
- 失败：本操作列出HTTP 401/403/404/422/500；统一Error；认证/字段/权限/前置版本失败不写业务数据。内部行执行结果与HTTP请求错误分开。

## 7. M4接口行为

### uploadImport｜导入官方XLSX

- 方法 + 路径：`POST /api/v1/imports`
- 使用环节：选择官方账单文件。
- 是否修改业务数据库：是；支持空改动的编辑操作不产生新版本。
- 请求：本操作requestBody（机器契约内联）；所有操作需要鉴权。 Idempotency-Key必需。
- 成功：HTTP201；响应结构以本operation的responses为准。


| 参数 | 位置 | 类型/合法值 | 必填 | 约束 |
|---|---|---|---|---|
| Idempotency-Key | header | string | 是 | 本人+方法+路径作用域；24小时内同键同规范化请求重放原结果；同键不同请求409；进行中409 REQUEST_IN_PROGRESS。过期不保证避免重复。 |
| file | 请求体 | string | 是 | 合法组合及业务限制见下文 |
| source_account_profile_id | 请求体 | string | 否 | minLength=1 |

成功返回：data：ImportBatch；page：object。嵌套字段、必填与互斥组合见[严格结构](../openapi.yaml)。

- 副作用：创建本人batch与观察，自动解析/规范化；档案明确时处理可入账行，逐行调用统一M3；不支持和待处理行不写账；同步返回当前分页结果与全批汇总。
- 异常与边界：仅XLSX，文件<=10MiB且明细<=10000行；无法判型/读取422，超额413且不写账；可读但声明数不符仍展示行、禁止缺失核对；无档案也返回batch及候选。部分行失败不回滚已完成其他行；同键重试重放原批次，新键重导重检当前来源关联；不虚构202后台任务。
- 失败：本操作列出HTTP 400/401/403/404/409/413/422/500；统一Error；认证/字段/权限/前置版本失败不写业务数据。内部行执行结果与HTTP请求错误分开。
- 流程验收：正常路径检查以上副作用；非法字段/他人资源不变更；重复提交按本操作重试边界；版本冲突不覆盖；资金操作在故障时无半笔账。对应动作与真实字段验证见实施计划。

### getImport｜查询导入结果与恢复选项

- 方法 + 路径：`GET /api/v1/imports/{batchId}`
- 使用环节：导入后查看/刷新阶段内容。
- 是否修改业务数据库：否。
- 请求：无请求体；路径/查询参数见机器契约；所有操作需要鉴权。
- 成功：HTTP200；响应结构以本operation的responses为准。


| 参数 | 位置 | 类型/合法值 | 必填 | 约束 |
|---|---|---|---|---|
| limit | query | integer | 否 | 见本操作边界 |
| rows_cursor | query | string | 否 | 见本操作边界 |
| reconciliation_cursor | query | string | 否 | 见本操作边界 |
| batchId | path | string | 是 | 见本操作边界 |

成功返回：data：ImportBatch；page：object。嵌套字段、必填与互斥组合见[严格结构](../openapi.yaml)。

- 副作用：只读阶段、证据、规范化候选、结果/原因、允许动作；不因刷新而继续入账。
- 异常与边界：只读本人批次；两个游标独立，summary始终全批；unsupported/ineffective是已说明终态，不等于created。
- 失败：本操作列出HTTP 401/403/404/422/500；统一Error；认证/字段/权限/前置版本失败不写业务数据。内部行执行结果与HTTP请求错误分开。

### resolveImport｜确认解释并继续导入

- 方法 + 路径：`POST /api/v1/imports/{batchId}/resolutions`
- 使用环节：档案选择、批次继续、角色确认或同事件确认。
- 是否修改业务数据库：是；支持空改动的编辑操作不产生新版本。
- 请求：Resolution；所有操作需要鉴权。 Idempotency-Key必需。
- 成功：HTTP200；响应结构以本operation的responses为准。


| 参数 | 位置 | 类型/合法值 | 必填 | 约束 |
|---|---|---|---|---|
| batchId | path | string | 是 | 见本操作边界 |
| Idempotency-Key | header | string | 是 | 本人+方法+路径作用域；24小时内同键同规范化请求重放原结果；同键不同请求409；进行中409 REQUEST_IN_PROGRESS。过期不保证避免重复。 |
| 按类型选择一个完整结构 | 请求体 | Resolution | 是 | 条件必填字段见OpenAPI；不得混合不同类型字段 |

成功返回：data：ImportBatch；page：object。嵌套字段、必填与互斥组合见[严格结构](../openapi.yaml)。

- 副作用：select_source_profile固定档案并处理就绪行；resume批次继续，不要求逐行点创建；set_transfer_role保存合法角色并继续本行；create_transaction明确确认新事件后继续本行；link只关联同一事件；accept_source_change只确认来源变化、不改已存交易。
- 异常与边界：档案动作比较profile_version；行决策比较expected_source_version，不锁整个batch；resume用最新就绪来源且每行防重复。旧观察不可覆盖新事实；unsupported/ineffective/failed不可create/link；无有效交易且条件齐备可创建独立refund，禁止手动伪造来源。参数/权限错误整个请求无修改；执行阶段账务失败按行报告，证据/解释可已保存。
- 失败：本操作列出HTTP 400/401/403/404/409/422/500；统一Error；认证/字段/权限/前置版本失败不写业务数据。内部行执行结果与HTTP请求错误分开。
- 流程验收：正常路径检查以上副作用；非法字段/他人资源不变更；重复提交按本操作重试边界；版本冲突不覆盖；资金操作在故障时无半笔账。对应动作与真实字段验证见实施计划。

### listMappings｜查询档案渠道映射

- 方法 + 路径：`GET /api/v1/source-payment-method-mappings`
- 使用环节：导入需要选择实际账户。
- 是否修改业务数据库：否。
- 请求：无请求体；路径/查询参数见机器契约；所有操作需要鉴权。
- 成功：HTTP200；响应结构以本operation的responses为准。


| 参数 | 位置 | 类型/合法值 | 必填 | 约束 |
|---|---|---|---|---|
| source_account_profile_id | query | string | 是 | 见本操作边界 |

成功返回：data：array。嵌套字段、必填与互斥组合见[严格结构](../openapi.yaml)。

- 副作用：只读本人profile已有映射。
- 异常与边界：无映射[]；无profile/他人profile422或404；钱包不得跨账号串用，银行卡可确认复用。
- 失败：本操作列出HTTP 401/403/404/422/500；统一Error；认证/字段/权限/前置版本失败不写业务数据。内部行执行结果与HTTP请求错误分开。

### putMapping｜保存渠道到实际账户映射

- 方法 + 路径：`PUT /api/v1/source-payment-method-mappings`
- 使用环节：用户选择一次渠道实际账户。
- 是否修改业务数据库：是；支持空改动的编辑操作不产生新版本。
- 请求：MappingPut；所有操作需要鉴权。
- 成功：HTTP200；响应结构以本operation的responses为准。


| 参数 | 位置 | 类型/合法值 | 必填 | 约束 |
|---|---|---|---|---|
| source_account_profile_id | 请求体 | string | 是 | minLength=1 |
| canonical_method_key | 请求体 | string | 是 | minLength=1 |
| account_id | 请求体 | string | 是 | minLength=1 |
| expected_version | 请求体 | integer | 是 | minimum=0 |

成功返回：data：Mapping。嵌套字段、必填与互斥组合见[严格结构](../openapi.yaml)。

- 副作用：expected_version=0表示新建，否则比较本映射版本；只更新映射，不直接改变既有交易或开始入账；客户端随后自动调用resume，不再逐行确认。
- 异常与边界：同profile/key唯一；新建已存在或更新版本冲突409；钱包跨档案冲突422；目标必须本人可写；重复相同值不增版本。
- 失败：本操作列出HTTP 400/401/403/404/409/422/500；统一Error；认证/字段/权限/前置版本失败不写业务数据。内部行执行结果与HTTP请求错误分开。
- 流程验收：正常路径检查以上副作用；非法字段/他人资源不变更；重复提交按本操作重试边界；版本冲突不覆盖；资金操作在故障时无半笔账。对应动作与真实字段验证见实施计划。

### reviewReconciliation｜处理无来源手动账单核对项

- 方法 + 路径：`POST /api/v1/imports/{batchId}/reconciliation-reviews`
- 使用环节：用户保留或删除核对账单。
- 是否修改业务数据库：是；支持空改动的编辑操作不产生新版本。
- 请求：ReviewRequest；所有操作需要鉴权。 Idempotency-Key必需。
- 成功：HTTP200；响应结构以本operation的responses为准。


| 参数 | 位置 | 类型/合法值 | 必填 | 约束 |
|---|---|---|---|---|
| batchId | path | string | 是 | 见本操作边界 |
| Idempotency-Key | header | string | 是 | 本人+方法+路径作用域；24小时内同键同规范化请求重放原结果；同键不同请求409；进行中409 REQUEST_IN_PROGRESS。过期不保证避免重复。 |
| reconciliation_item_id | 请求体 | string | 是 | minLength=1 |
| expected_version | 请求体 | integer | 是 | minimum=1 |
| action | 请求体 | keep_manual / delete_manual_transaction | 是 | 合法组合及业务限制见下文 |

成功返回：data：ReviewResult。嵌套字段、必填与互斥组合见[严格结构](../openapi.yaml)。

- 副作用：比较核对项自己的version；keep仅设kept_manual；delete通过M3撤销本人手动交易并关闭核对项，返回资金/月份变化。
- 异常与边界：核对项/交易/profile/batch关联与归属全验证；已匹配来源的项目不能再删除；删除不安全409且核对状态不改；同意图重复不二次删账，不拿全batch版本挡其他项。
- 失败：本操作列出HTTP 400/401/403/404/409/422/500；统一Error；认证/字段/权限/前置版本失败不写业务数据。内部行执行结果与HTTP请求错误分开。
- 流程验收：正常路径检查以上副作用；非法字段/他人资源不变更；重复提交按本操作重试边界；版本冲突不覆盖；资金操作在故障时无半笔账。对应动作与真实字段验证见实施计划。

## 8. M5接口行为

### getOverview｜查询首页总览

- 方法 + 路径：`GET /api/v1/overview`
- 使用环节：登录后首页/切换历史月份。
- 是否修改业务数据库：否。
- 请求：无请求体；路径/查询参数见机器契约；所有操作需要鉴权。
- 成功：HTTP200；响应结构以本operation的responses为准。


| 参数 | 位置 | 类型/合法值 | 必填 | 约束 |
|---|---|---|---|---|
| month | query | string | 是 | 见本操作边界 |

成功返回：data：Overview。嵌套字段、必填与互斥组合见[严格结构](../openapi.yaml)。

- 副作用：资金为当前可见四类份额，消费/预算是指定月本人数据；未绑定对象两份额null。
- 异常与边界：未来统计月422；无预算budget=null；净花销可负；上月日均0时变化率null；金额显示到分、中间不提前舍入；不修改预算/交易。
- 失败：本操作列出HTTP 401/403/404/422/500；统一Error；认证/字段/权限/前置版本失败不写业务数据。内部行执行结果与HTTP请求错误分开。

### getBudget｜查询个人月预算

- 方法 + 路径：`GET /api/v1/budgets/{month}`
- 使用环节：预算表单读取/未来预算查看。
- 是否修改业务数据库：否。
- 请求：无请求体；路径/查询参数见机器契约；所有操作需要鉴权。
- 成功：HTTP200；响应结构以本operation的responses为准。


| 参数 | 位置 | 类型/合法值 | 必填 | 约束 |
|---|---|---|---|---|
| month | path | string | 是 | 见本操作边界 |

成功返回：data：Budget 或 null。嵌套字段、必填与互斥组合见[严格结构](../openapi.yaml)。

- 副作用：只读本人预算，未设置data=null。
- 异常与边界：合法未来月份允许；不返回对象预算写入口。
- 失败：本操作列出HTTP 401/403/404/422/500；统一Error；认证/字段/权限/前置版本失败不写业务数据。内部行执行结果与HTTP请求错误分开。

### putBudget｜设置个人月预算

- 方法 + 路径：`PUT /api/v1/budgets/{month}`
- 使用环节：首页/预算表单保存。
- 是否修改业务数据库：是；支持空改动的编辑操作不产生新版本。
- 请求：BudgetPut；所有操作需要鉴权。
- 成功：HTTP200；响应结构以本operation的responses为准。


| 参数 | 位置 | 类型/合法值 | 必填 | 约束 |
|---|---|---|---|---|
| month | path | string | 是 | 见本操作边界 |
| budget_minor | 请求体 | integer | 是 | minimum=0 |
| expected_version | 请求体 | integer | 是 | minimum=0 |

成功返回：data：Budget。嵌套字段、必填与互斥组合见[严格结构](../openapi.yaml)。

- 副作用：0版本创建，否则比较本人该月预算version并整体替换；不产生资金变动，overview随后使用新预算。
- 异常与边界：金额非负整数；存在/版本冲突409，非法月份422；相同值不增版本；不能指定他人user_id。
- 失败：本操作列出HTTP 400/401/403/404/409/422/500；统一Error；认证/字段/权限/前置版本失败不写业务数据。内部行执行结果与HTTP请求错误分开。
- 流程验收：正常路径检查以上副作用；非法字段/他人资源不变更；重复提交按本操作重试边界；版本冲突不覆盖；资金操作在故障时无半笔账。对应动作与真实字段验证见实施计划。

## 9. API能做什么与明确边界

API覆盖账户/手动记账/账单生命周期/官方导入及恢复/关系绑定/统计预算全部V1公开动作。未为source、effect、movement逐表生成CRUD；未新增收费转账、截图、负债或异常中心。查询聚合可复用相同计算，不能各自保存余额；不同输入入口必须共用M3。

设置页的本地显示偏好由客户端本地保存，不虚构跨设备设置服务。认证服务的签发/刷新/注销属外部边界，必须在工程选型和真实端到端验收时落实；这份业务OpenAPI不能证明登录服务已存在。当前参考程序只验证规则与字段信息流，没有真实HTTP/数据库/移动应用；完整规范不等于实现验收。
