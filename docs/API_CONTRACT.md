# 星账｜API 契约

**版本：** v0.3  
**阶段：** API 契约设计稿  
**状态：** 候选契约，待审阅  
**业务基线：** [核心业务规则 v2.7（已冻结）](BUSINESS_RULES_DISCUSSION.md)  
**数据基线：** [逻辑数据模型 v0.4](LOGICAL_DATA_MODEL.md)  
**产品基线：** [产品功能地图 v0.3](PRODUCT_FUNCTION_MAP.md)

本文把已冻结的业务规则和逻辑数据模型转换为前后端共同遵守的接口约定。接口路径与 HTTP/JSON 形式是当前建议，不代表已确定技术栈、数据库、部署方式或认证供应商。

## 0. 契约原则

1. **前端请求业务操作，不直接修改账务底层记录。** 前端不能直接写账户余额或任意写入资金变动。
2. **后端统一执行账务规则。** 手动记账、官方账单导入、交易编辑与退款都必须经过同一套交易处理规则；但手动创建交易只允许收入、支出和转账，退款只能由官方账单导入创建。
3. **交易事实、账户影响、资金变动分开表达。** 但需要在一次业务操作内原子完成相关更新。
4. **身份来自已验证的登录上下文。** 写接口不接受客户端传入的 user_id 作为授权依据。
5. **绑定只扩大读取范围，不扩大写权限。** 对方的账户和交易可以只读查看，不能通过 API 修改。
6. **金额使用整数分。** 不用浮点数表示货币。
7. **重复请求不能重复入账。** 新建交易、文件导入等写操作支持幂等处理。
8. **失败必须明确。** 账务校验失败时不允许只成功写入一部分。
9. **不为当前版本增加新产品流程。** 不提供账户删除、解绑、负债账户、余额不足/透支管理或截图识别接口。
10. **跨客户端共享同一契约。** 桌面端与 Android 端调用同一套业务 API 和账务规则；平台差异由客户端适配层处理。

## 1. 通用约定

### 1.1 基础格式

- 建议 API 前缀：**/api/v1**
- 请求与响应：JSON；文件导入使用 multipart/form-data
- ID：不透明字符串，客户端不得依赖其内部格式
- 金额：整数分，例如人民币 ¥12.34 表示为 1234。交易本身的 amount_minor 始终为正整数；账户影响与资金变动用正负号表示流入/流出。
- 日期：YYYY-MM-DD
- 日期时间：ISO 8601 / RFC 3339，必须携带时区偏移
- 月份：YYYY-MM
- 枚举值使用稳定的英文代码；显示文案由前端本地化
- 所有写接口均要求已验证的登录上下文；登录方式和 token 签发服务由后续技术选型决定

### 1.2 成功响应

单个资源：

~~~json
{
  "data": {
    "id": "opaque-id",
    "example": "value"
  }
}
~~~

列表：

~~~json
{
  "data": [],
  "page": {
    "next_cursor": null
  }
}
~~~

成功响应中的业务结果必须表示已经完成的操作，不能在后台仍未保存时返回“记账成功”。如果文件导入需要异步处理，必须返回明确的处理中状态，而不是伪装成已完成。

### 1.3 错误响应

所有 API 使用统一错误结构：

~~~json
{
  "error": {
    "code": "REFUND_EXCEEDS_ORIGINAL",
    "message": "退款金额超过原消费尚可退款金额。",
    "field_errors": [],
    "request_id": "request-id"
  }
}
~~~

- code：稳定的机器可读错误码。
- message：可供前端展示的简明说明，不包含敏感信息。
- field_errors：可选字段校验详情。
- request_id：用于定位服务端日志；不要求前端理解内部实现。

### 1.4 幂等与并发

- 创建交易、上传导入文件及导入结果处理等写操作应支持 Idempotency-Key。
- 同一个幂等键和相同请求重复提交，只返回同一业务结果，不重复创建交易或重复执行资金变动。
- 同一交易的并发编辑不能静默覆盖。资源响应提供 version；更新请求带上读取到的版本。版本不匹配时返回 409 RESOURCE_VERSION_CONFLICT，前端提示刷新后重试。
- 幂等键和 version 是接口层的行为约定；其存储与实现方式不在本文件决定。

## 2. 身份、数据范围与权限

### 2.1 数据范围

只读查询可以使用 view 参数：

- view=mine：当前登录用户自己的数据，默认值。
- view=partner：已绑定对象的数据；仅允许读取账户和账单等明确开放的内容。

客户端不传任意 user_id 来切换数据范围。后端根据当前登录身份和有效绑定关系解析 view=partner。

### 2.2 权限矩阵

| 资源/操作 | 自己的数据 | 已绑定对象的数据 |
|---|---|---|
| 查看账户与账户内资金 | 允许 | 只读允许 |
| 新建/编辑账户 | 允许 | 禁止 |
| 调整资金归属与性质 | 允许 | 禁止 |
| 查看账单 | 允许 | 只读允许 |
| 新建/编辑/删除交易 | 允许 | 禁止 |
| 查看个人预算 | 允许 | 不开放当前用户对对象预算的修改权限；对象预算不进入当前用户预算计算 |
| 导入官方账单 | 允许导入到自己的账本 | 禁止写入对象账本 |
| 绑定状态查询 | 允许 | 根据绑定关系返回必要状态 |

**强制规则：** 隐藏前端按钮不是权限控制。所有写接口必须在服务端校验资源所属用户；对方数据的越权写入返回 403 FORBIDDEN，不能因为请求携带了对方资源 ID 就执行操作。

## 3. 接口总览

| 模块 | 方法与路径 | 用途 |
|---|---|---|
| M5 预算与统计 | GET /api/v1/overview?month=YYYY-MM | 首页资金总览与个人消费指标 |
| M2 账户与资金归属 | GET /api/v1/accounts?view=mine | 账户列表及余额/份额摘要 |
| M2 账户与资金归属 | POST /api/v1/accounts | 创建实际账户并设置初始资金 |
| M2 账户与资金归属 | GET /api/v1/accounts/{accountId} | 查看账户详情 |
| M2 账户与资金归属 | PATCH /api/v1/accounts/{accountId} | 编辑账户名称等基本信息 |
| M2 账户与资金归属 | PUT /api/v1/accounts/{accountId}/opening-state | 修正初始余额、起始日期与初始份额 |
| M2 账户与资金归属 | POST /api/v1/accounts/{accountId}/fund-adjustments | 在同一账户内调整资金归属/性质 |
| M3 交易账务 | GET /api/v1/transactions?view=mine | 账单列表、搜索与筛选 |
| M3 交易账务 | POST /api/v1/transactions | 手动创建收入、支出或转账；退款只能由官方导入创建 |
| M3 交易账务 | GET /api/v1/transactions/{transactionId} | 查看账单详情 |
| M3 交易账务 | PATCH /api/v1/transactions/{transactionId} | 编辑既有交易 |
| M3 交易账务 | DELETE /api/v1/transactions/{transactionId} | 删除交易及规则要求一并删除的退款 |
| M5 预算与统计 | GET /api/v1/budgets/{month} | 查看当前用户该月预算 |
| M5 预算与统计 | PUT /api/v1/budgets/{month} | 创建或修改当前用户该月预算 |
| M3 交易账务 | GET /api/v1/transaction-categories | 读取当前支持的分类字典 |
| M1 身份与关系 | GET /api/v1/relationship | 查询绑定状态 |
| M1 身份与关系 | POST /api/v1/relationship/binding | 完成绑定；绑定凭据的获取方式仍待身份/关系流程设计 |
| M4 导入与来源证据 | POST /api/v1/imports | 上传微信/支付宝官方账单 |
| M4 导入与来源证据 | GET /api/v1/imports/{batchId} | 查看一次导入的结果与必要的待处理记录 |
| M4 导入与来源证据 | POST /api/v1/imports/{batchId}/resolutions | 处理确实无法自动唯一匹配的来源记录 |
| M4 导入与来源证据 | GET /api/v1/source-payment-method-mappings?platform=... | 查看行级支付渠道映射 |
| M4 导入与来源证据 | PUT /api/v1/source-payment-method-mappings | 新建或更新行级支付渠道映射 |

这些是业务操作接口。底层的 AccountFundMovement 不提供任意新增、编辑或删除接口；资金变动由账户初始状态、交易、退款、转账、导入或手动分配调整等受控操作生成。

## 4. M5：首页总览与个人预算

### 4.1 获取首页总览

GET /api/v1/overview?month=2026-10

返回示例：

~~~json
{
  "data": {
    "month": "2026-10",
    "as_of_date": "2026-10-20",
    "relationship_status": "bound",
    "funds": {
      "my_liquid_minor": 100000,
      "my_savings_minor": 300000,
      "partner_liquid_minor": 80000,
      "partner_savings_minor": 120000,
      "visible_total_minor": 600000
    },
    "personal_spending": {
      "month_spent_minor": 320000,
      "daily_average_minor": 16000,
      "previous_month_daily_average_minor": 15000,
      "daily_change_minor": 1000,
      "daily_change_rate": 0.0667,
      "projected_month_spending_minor": 496000
    },
    "budget": {
      "budget_minor": 300000,
      "spent_minor": 320000,
      "remaining_minor": 0,
      "over_budget_minor": 20000,
      "status": "over_budget"
    }
  }
}
~~~

规则：

- funds 按资金归属人与资金性质聚合，不按账户持有人简单相加，避免把代为保管的对象存款误算成自己的钱。
- 未绑定时，对象两项资金为 null 或按约定省略；不得伪造为 0 元的真实账户记录。绑定后同时返回四类资金。
- visible_total_minor 是当前用户有权查看的资金份额合计，不代表这些资金全部属于当前用户。
- personal_spending 与 budget 只计算当前用户自己的消费，不混入对象消费。
- 退款关联原消费后，修正原消费月份的花销。
- 日均花销、变化率和本月预计花销按业务规则 v2.7 的公式计算。
- 超支时 status=over_budget、over_budget_minor 为正数，前端显示红色“已超支 ¥X”；未超支时显示剩余额度。
- 当上月日均为零时的特殊展示已被业务规则列为非阻塞边界，不在本契约中增加新业务流程。

### 4.2 查看与设置预算

GET /api/v1/budgets/2026-10

PUT /api/v1/budgets/2026-10

请求：

~~~json
{
  "budget_minor": 300000
}
~~~

响应：

~~~json
{
  "data": {
    "month": "2026-10",
    "budget_minor": 300000,
    "version": 1
  }
}
~~~

- 预算按当前登录用户与月份唯一。
- PUT 为该月预算的创建或替换，不接受 user_id。
- 对象消费不扣减当前用户预算。
- 负金额、非整数金额或无效月份返回 422 VALIDATION_ERROR。

## 5. M2：账户与资金归属

### 5.1 创建账户

POST /api/v1/accounts

请求：

~~~json
{
  "name": "微信零钱",
  "account_type": "wechat_balance",
  "custodian": "self",
  "opening_date": "2026-10-01",
  "opening_balance_minor": 500000,
  "opening_allocations": [
    {
      "fund_owner": "self",
      "fund_type": "liquid",
      "amount_minor": 100000
    },
    {
      "fund_owner": "self",
      "fund_type": "savings",
      "amount_minor": 300000
    },
    {
      "fund_owner": "partner",
      "fund_type": "savings",
      "amount_minor": 100000
    }
  ]
}
~~~

account_type 是当前候选分类：cash、bank_card、wechat_balance、alipay_balance、other。实际账户名称仍由用户填写。

约束：

- 账户记录归属当前登录用户；不允许通过请求体指定另一个用户作为账户所有者。
- custodian 可为 self 或 partner，默认 self；其含义仅为实际保管关系，不授予编辑权限。partner 仅在双方已绑定时允许。
- opening_balance_minor 必须是非负整数；初始份额金额之和必须与其完全相等。
- fund_owner=partner 仅允许 fund_type=savings，且仅绑定后可用。
- 初始资金通过后端创建初始 AccountFundMovement 生成；不把初始余额当作收入。
- 不提供删除账户接口。

### 5.2 账户列表与详情

GET /api/v1/accounts?view=mine

GET /api/v1/accounts/{accountId}

响应中的余额与份额为计算结果：

~~~json
{
  "data": {
    "id": "account-id",
    "name": "微信零钱",
    "account_type": "wechat_balance",
    "holder": "self",
    "custodian": "self",
    "opening_date": "2026-10-01",
    "balance_minor": 500000,
    "fund_shares": [
      {"fund_owner": "self", "fund_type": "liquid", "amount_minor": 100000},
      {"fund_owner": "self", "fund_type": "savings", "amount_minor": 300000},
      {"fund_owner": "partner", "fund_type": "savings", "amount_minor": 100000}
    ],
    "read_only": false,
    "version": 1
  }
}
~~~

- 查询对象账户时，read_only=true。
- balance_minor 必须等于所有有效资金变动之和。
- fund_shares 的合计必须等于 balance_minor。
- 不允许直接 PATCH balance_minor 或直接覆盖 fund_shares。

### 5.3 编辑账户基本信息

PATCH /api/v1/accounts/{accountId}

允许字段：name、account_type、custodian。

不允许通过该接口修改余额、资金份额、账户持有人或记账起始日期。初始状态使用专门接口处理。

### 5.4 修正初始状态

PUT /api/v1/accounts/{accountId}/opening-state

请求：

~~~json
{
  "opening_date": "2026-10-01",
  "opening_balance_minor": 500000,
  "opening_allocations": [
    {"fund_owner": "self", "fund_type": "liquid", "amount_minor": 100000},
    {"fund_owner": "self", "fund_type": "savings", "amount_minor": 300000},
    {"fund_owner": "partner", "fund_type": "savings", "amount_minor": 100000}
  ],
  "version": 1
}
~~~

- 初始金额、起始日期和初始份额必须作为一个原子操作处理。
- 后端检查金额合计、归属组合、绑定状态和版本。
- 修改起始日期后，后端必须重新判断该账户关联交易的 applied / historical_only 状态，并保证当前账户余额和资金份额一致；不修改交易事实或其他账户的数据。
- 如果修改起始日期会导致既有资金变动无法在当前规则下安全重建，返回 409 OPENING_STATE_RECALCULATION_CONFLICT，不允许只更新日期而留下部分旧账。该冲突处理不扩展成新的核对产品流程。
- 初始余额修正不能通过直接覆盖当前余额完成，也不计为收入或支出。

### 5.5 手动调整资金归属/性质

POST /api/v1/accounts/{accountId}/fund-adjustments

请求：

~~~json
{
  "from": {"fund_owner": "self", "fund_type": "savings"},
  "to": {"fund_owner": "self", "fund_type": "liquid"},
  "amount_minor": 50000
}
~~~

响应：

~~~json
{
  "data": {
    "account_id": "account-id",
    "balance_minor": 500000,
    "fund_shares": [
      {"fund_owner": "self", "fund_type": "liquid", "amount_minor": 150000},
      {"fund_owner": "self", "fund_type": "savings", "amount_minor": 250000},
      {"fund_owner": "partner", "fund_type": "savings", "amount_minor": 100000}
    ]
  }
}
~~~

- 仅允许同一账户内的等额分配调整。
- amount_minor 必须为正整数，来源份额必须足够。
- 调整前后资金组合都必须合法；对象份额仅允许存款。
- 该操作生成同一操作分组中的一条负向与一条正向 AccountFundMovement。
- 账户总额不变；不计收入、消费或普通转账。
- 不允许通过该接口调整另一个用户的账户。

## 6. M3：交易账务与账单

### 6.1 交易类型与账务语义

交易类型：

- income：收入
- expense：支出
- transfer：内部转账
- refund：真实退款（仅由官方账单导入流程创建，不属于手动记账可选类型）

内部账务语义 accounting_semantics 用于表达类型无法单独决定的现金影响与统计规则：

- ordinary：普通收入或支出
- credit_purchase：信用消费，计入消费统计，不扣减受管理现金账户
- credit_repayment：信用还款，减少实际付款账户余额，但不计入消费统计
- internal_transfer：内部转账，不计收入或消费

语义必须与交易类型、账户影响相符；例如 credit_purchase 只允许与 expense 配合，internal_transfer 只允许与 transfer 配合。客户端可以提交候选语义，但后端必须校验其与交易字段、账户和来源证据相符，不能仅凭客户端传值绕过资金规则。

### 6.2 创建交易

POST /api/v1/transactions

普通支出请求示例：

~~~json
{
  "type": "expense",
  "accounting_semantics": "ordinary",
  "occurred_at": "2026-10-20T12:30:00+08:00",
  "amount_minor": 2580,
  "account_id": "account-id",
  "category_code": "food",
  "merchant": "午餐",
  "note": ""
}
~~~

内部转账请求示例：

~~~json
{
  "type": "transfer",
  "accounting_semantics": "internal_transfer",
  "occurred_at": "2026-10-20T12:30:00+08:00",
  "amount_minor": 10000,
  "from_account_id": "account-a",
  "to_account_id": "account-b",
  "note": "账户间转账"
}
~~~

`POST /api/v1/transactions` 只接受手动记账类型 income、expense、transfer；提交 type=refund 必须拒绝（错误码 `REFUND_REQUIRES_OFFICIAL_SOURCE`）。refund 仍是正式交易类型，但只能由官方导入流程在来源记录已识别且原消费关系确认后创建。导入退款时，SourceRecord 关联新建的退款 Transaction，而该 Transaction 的 original_transaction_id 指向原消费；不得把退款 SourceRecord 直接关联到原消费本身。

收入请求使用 type=income 和 account_id。信用消费可使用 type=expense、accounting_semantics=credit_purchase 且不提供受管理现金账户；信用还款使用 type=expense、accounting_semantics=credit_repayment 和实际付款账户。客户端不能将信用消费伪造成普通现金支出。

后端行为：

1. 校验字段和当前用户对账户的写权限。
2. 校验交易类型、账务语义和账户组合。
3. 创建 Transaction 与必要的 TransactionAccountEffect。
4. 根据交易日期和每个账户的起始日期，判断账户影响是 applied 还是 historical_only。
5. 对 applied 影响，按统一规则生成 AccountFundMovement。
6. 在同一原子操作中验证账户余额、资金份额、转账两端和退款关联约束。
7. 返回正式保存结果与必要的存款使用提醒。

退款边界已由业务规则 v2.7 冻结：退款到账账户与原消费账户相同，首期不支持信用消费退款。官方退款必须由平台专用解析器关联唯一原消费；若解析器无法建立该关系，整行作为导入错误处理，不创建退款交易、不按普通收入入账。

响应示例：

~~~json
{
  "data": {
    "transaction": {
      "id": "transaction-id",
      "type": "expense",
      "amount_minor": 2580,
      "version": 1
    },
    "account_effects": [
      {"account_id": "account-id", "status": "applied", "amount_minor": -2580}
    ],
    "fund_usage": [
      {"fund_owner": "self", "fund_type": "liquid", "amount_minor": 2580}
    ],
    "notices": []
  }
}
~~~

若使用自己的存款或对象存款，notices 返回对应的稳定代码与金额，例如 OWN_SAVINGS_USED、PARTNER_SAVINGS_USED。提醒不阻塞记账，也不代表系统认定任何一方欠另一方钱。

### 6.3 交易列表与详情

GET /api/v1/transactions?view=mine&from=2026-10-01&to=2026-10-31&type=expense&account_id=account-id&category_code=food&q=午餐&limit=50&cursor=...

支持的筛选项：

- view：mine 或绑定后的 partner
- from、to：交易日期范围，包含边界日期
- type：交易类型
- account_id：关联账户
- category_code：分类代码
- q：商户、名称或备注的关键词
- limit、cursor：分页

GET /api/v1/transactions/{transactionId} 返回交易事实、关联账户影响摘要、退款原交易信息、来源关联摘要，以及 read_only 与 version。

查询对象交易只读；不可将 view=partner 与写操作组合使用。

### 6.4 编辑交易

PATCH /api/v1/transactions/{transactionId}

请求仅包含要修改的字段；若修改交易类型，必须同时提供新类型所需的账户字段。例如改为转账时，必须提供 from_account_id 与 to_account_id。

允许编辑的业务字段：

- 金额、交易时间、分类、商户、备注；
- 交易类型（可编辑为收入、支出或转账；不得通过手动编辑将普通交易转换为 refund）；
- 对应账户；
- 退款原交易关联（仅已有官方来源创建的退款交易可修改该关联）。

后端必须在一个原子操作内：

1. 校验版本和写权限。
2. 校验修改后类型与关联关系是否合法。
3. 处理该交易原有的有效账户影响和资金变动。
4. 只按差额或新类型规则重新处理当前交易；不自动重算其他交易。
5. 校验退款累计金额、资金份额守恒、账户余额和转账规则。
6. 保存后返回新的交易、账户影响与资金分配结果。

差额处理遵循冻结规则：

- 金额增加：按自己的流动资金 → 自己的存款 → 对象存款的顺序扣减。
- 金额减少：按对象存款 → 自己的存款 → 自己的流动资金的顺序补足资金缺口。
- 真实退款与金额修改的差额返还必须区分；前者按原交易扣款顺序逆序恢复。
- 如果被编辑的本身是一笔退款，金额变更必须先排除该退款原有的有效影响，再按修改后的退款金额、原消费关联和剩余可退款份额重新核算；不得套用普通支出的差额返还规则。
- 如果新金额导致累计退款超过原消费金额，返回 409 REFUND_EXCEEDS_ORIGINAL，不允许保存半成品状态。
- 如果修改类型会让已有退款关联到非消费交易，返回 409 INVALID_TRANSACTION_TYPE_CHANGE；不留下非法关联。
- 如果改为转账，系统不得擅自把存款转换成流动资金。

### 6.5 删除交易

DELETE /api/v1/transactions/{transactionId}

- 仅允许删除当前用户有权编辑的交易。
- 删除消费时，按冻结规则一并删除其关联退款。
- 删除相关交易的正常账务影响，使其不再参与余额和统计计算。
- 保留来源证据，但清空相关 SourceRecord 的当前交易关联和匹配状态；之后允许重新导入。
- 响应返回被删除交易 ID 列表及受影响的账户摘要。
- 若请求删除对象的交易，返回 403 FORBIDDEN。
- 不提供删除账户、解绑或回收站接口。

## 7. M4：官方账单导入与来源证据

### 7.1 上传官方账单

POST /api/v1/imports

请求使用 multipart/form-data：

- file：微信或支付宝官方导出文件
- source_account_profile_id：可选；若文件头可唯一匹配已有来源账户档案则自动使用，否则仅在存在多个候选档案时要求用户选择
- Header：Idempotency-Key

平台由固定的官方文件结构和表头自动识别，不要求用户每次手动选择微信或支付宝。V1 只支持微信和支付宝官方账单文件；截图识别不属于此接口。

响应示例：

~~~json
{
  "data": {
    "batch_id": "import-batch-id",
    "platform": "wechat",
    "status": "needs_review",
    "summary": {
      "transactions_created": 120,
      "transactions_linked": 8,
      "duplicate_sources_ignored": 3,
      "source_records_needing_review": 0,
      "manual_transactions_not_found": 4,
      "reconciliation_items_rechecked": 2,
      "failed_rows": 0
    },
    "coverage": {
      "from": "2026-02-01T00:00:00+08:00",
      "to": "2026-04-30T23:59:59+08:00",
      "export_type": "all_transactions",
      "declared_record_count": 169,
      "parsed_record_count": 169,
      "complete": true
    },
    "source_account_profile": {
      "id": "source-account-profile-id",
      "platform": "wechat",
      "display_label": "微信账号"
    },
    "review_items": [
      {"source_record_id": "source-record-id", "reason_code": "AMBIGUOUS_MATCH"}
    ],
    "reconciliation_items": [
      {"reconciliation_item_id": "reconciliation-item-id", "transaction_id": "manual-transaction-id", "reason_code": "NO_SOURCE_MATCH_WITHIN_COVERAGE", "status": "pending_confirmation"}
    ]
  }
}
~~~

状态建议：

- completed：批次处理完成，没有待用户处理的来源记录或手动交易核对项。
- needs_review：批次已处理，但存在待处理来源记录或待用户确认的手动交易核对项。
- failed：文件无法安全解析或批次无法完成；不得报告为成功入账。

`transactions_created`、`transactions_linked` 和 `duplicate_sources_ignored` 是互斥计数。`source_records_needing_review` 只统计非退款官方来源行的待处理项；`manual_transactions_not_found` 统计本批次新建的核对项；`reconciliation_items_rechecked` 统计本批次重新检查到的既有核对项，不会生成重复提示。`coverage.complete` 只有在导出类型为全量、起止时间可解析、声明记录数与实际解析行数一致且无解析失败时才能为 true；否则不得生成“未找到来源”的核对项。

### 7.2 导入处理约束

后端按以下顺序处理：

1. 从固定文件结构自动识别微信或支付宝；读取导出账户元数据、导出时间、起止范围、导出类型与声明记录数。
2. 校验表头、日期范围、全量导出标记、声明行数和实际解析行数；不完整文件仍可报告解析结果，但不得执行缺失手动交易核对。
3. 解析每行官方交易单号，按 `(source_account_profile_id, official_transaction_id)` 查找或创建 SourceRecord；商户订单号不作为唯一主键。
4. 为每条已识别来源保存 SourceObservation。若重叠导出中同一交易的状态不同，保留两次观察，并按导出时间较新的观察更新当前来源状态；旧文件不得覆盖新状态。
5. 按平台规则解析交易语义和唯一退款原消费；退款到账账户必须与原消费账户相同。若无法建立唯一退款关系，该行失败，不创建退款交易。
6. 匹配已有来源与手动交易；已存在来源不重复入账，匹配到已有手动交易时关联来源，不重复创建交易。
7. 对新交易调用统一交易处理逻辑；不直接写余额。对起始日前交易保留事实但不改变该账户余额。
8. 只有完整覆盖范围和来源账户档案/行级渠道映射都明确时，才核对范围内未匹配到官方来源的手动交易。
9. 按 `(source_account_profile_id, transaction_id)` 查找 ImportReconciliationItem：新项进入本批次提示；已存在项仅更新最近检查批次和检查时间，不重复创建/提示。
10. 保存来源关联、核对项、处理结果和汇总计数。

重复导入约束：

- 同一幂等请求不能重复执行。
- 相同文件指纹可识别为已处理批次，避免重复入账。
- 首选稳定身份为来源账户档案 + 官方交易单号；商户订单号可为空或重复，不作唯一键。
- 当前真实重叠样本中，微信 60/60、支付宝 83/83 条重叠记录的官方交易单号一致；同一来源状态可随导出时间更新，但不重复创建交易。
- 不同文件日期范围重叠时，仍按稳定交易单号去重；不能只按文件指纹去重。
- 仅当平台文件缺失交易单号且无法证明唯一身份时，才进入来源数据错误/待修复流程，不使用金额、日期和商户相同作为静默合并依据。
- 删除交易后再次导入，允许重新创建交易；历史 SourceRecord 不能永久阻止重导入。
- 不静默覆盖用户手动修正的重要字段；不确定时保留证据并要求必要的人工处理。

### 7.3 查询导入结果

GET /api/v1/imports/{batchId}

返回批次状态、计数、覆盖范围、待处理来源记录、解析错误摘要、相关交易 ID，以及独立的 reconciliation_items（未匹配手动交易及确认状态）。只能读取当前用户发起的批次。

官方来源记录待处理与手动交易未找到对应来源是两类不同结果，不能共用同一个“未匹配”含义。不建设独立复杂的异常管理中心；需要人工处理时，从本次导入结果进入对应记录即可。

### 7.4 处理无法唯一匹配的来源记录

POST /api/v1/imports/{batchId}/resolutions

关联已有交易：

~~~json
{
  "source_record_id": "source-record-id",
  "action": "link_existing_transaction",
  "transaction_id": "existing-transaction-id"
}
~~~

确认创建新交易：

~~~json
{
  "source_record_id": "source-record-id",
  "action": "create_transaction"
}
~~~

- `link_existing_transaction` 只用于“该官方来源行本身就是这笔已有交易”的情况，必须验证交易属于当前用户，且没有与另一个不兼容的来源身份冲突。
- `create_transaction` 只用于可独立建立的普通收入、支出或转账来源，通过统一交易规则创建正式交易；不得绕过资金分配和账户起始日期规则。
- 退款不走通用的人工 resolution；由平台专用解析器按官方规则唯一关联原消费并自动调用统一交易用例创建退款交易。若无法唯一关联，记录 `REFUND_ORIGINAL_NOT_RESOLVED` 导入错误并保留原始证据，不创建交易，也不把它作为用户日常选择原消费的待处理项。
- 处理成功后更新 SourceRecord 关联与 ImportBatch 计数。
- 同一来源记录不能因重复提交 resolution 而重复创建交易。

### 7.4.1 处理未匹配手动交易核对项

POST /api/v1/imports/{batchId}/reconciliation-reviews

删除手动交易：

~~~json
{
  "reconciliation_item_id": "reconciliation-item-id",
  "action": "delete_manual_transaction"
}
~~~

保留并标记已核对：

~~~json
{
  "reconciliation_item_id": "reconciliation-item-id",
  "action": "keep_manual"
}
~~~

- `delete_manual_transaction` 调用标准交易删除用例，并与核对项关闭/删除在同一原子操作中完成；不得只删除一侧。
- `keep_manual` 将状态设为 `kept_manual`，不修改交易事实、账户余额或资金份额。
- 后续官方来源若成功匹配到该手动交易，关联来源并将核对项设为 `matched_to_source`。
- 必须验证核对项、来源档案和交易都属于当前用户；重复请求应幂等。
- 重叠导入不能为同一来源档案与交易创建第二个核对项或重复提示。

### 7.5 来源账户档案与支付渠道映射

来源账户档案代表导出文件的微信/支付宝账号；行级支付渠道映射代表交易使用的零钱、银行卡、花呗或亲情卡等方式，两者不能混为一个字段。

- 导入时优先自动匹配已有来源档案。支付宝账户头标识可用于档案指纹匹配；微信文件头目前只有昵称，昵称仅作展示/辅助识别，不作为不可变身份 ID。
- 若只有一个当前用户的同平台档案，可复用该档案；存在多个候选且无法唯一识别时，才要求用户选择。首次导入创建档案，不要求每次导入重新确认。
- `ImportBatch` 必须保存来源档案 ID、导出账户元数据快照、导出时间、起止时间、导出类型、声明行数、实际解析行数和完整性判定。

### 7.6 行级支付渠道映射

GET /api/v1/source-payment-method-mappings?platform=wechat

PUT /api/v1/source-payment-method-mappings

请求示例：

~~~json
{
  "platform": "wechat",
  "source_payment_method_key": "零钱",
  "mapping_kind": "managed_account",
  "account_id": "account-id"
}
~~~

信用支付来源示例：

~~~json
{
  "platform": "alipay",
  "source_payment_method_key": "花呗",
  "mapping_kind": "credit_source"
}
~~~

- `managed_account` 必须提供当前用户有权编辑的 `account_id`。
- `credit_source` 不创建负债账户，也不需要虚构账户 ID。
- 映射仅帮助解析每行官方文件中的支付渠道，不直接产生交易或资金变动。
- 支付渠道名称本身不能替代交易语义判断。

## 8. M1：关系绑定

### 8.1 查询绑定状态

GET /api/v1/relationship

响应示例：

~~~json
{
  "data": {
    "status": "bound",
    "partner": {
      "display_name": "对方"
    },
    "permissions": {
      "partner_accounts": "read_only",
      "partner_transactions": "read_only"
    }
  }
}
~~~

未绑定时返回 status=unbound，不返回对象资金份额。绑定后首页与账户/账单读取接口可使用前述只读权限。

### 8.2 完成绑定

POST /api/v1/relationship/binding

候选请求：

~~~json
{
  "binding_token": "opaque-binding-proof"
}
~~~

- 服务端必须验证绑定凭据并确认双方身份；客户端不能只提交任意 user ID 就建立关系。
- 绑定成功后允许查看对方账户和交易；不改变账户持有人、资金归属、历史交易或个人预算。
- 不提供解绑接口。
- **待技术/交互方案确认：** 绑定凭据如何生成、传递、过期及验证，当前业务规则没有冻结具体方式；本接口仅定义消费已验证绑定凭据的边界，不能据此直接实现邀请系统。

## 9. 通用错误码

| HTTP 状态 | 错误码 | 场景 |
|---|---|---|
| 400 | BAD_REQUEST | 请求结构无法解析 |
| 401 | UNAUTHENTICATED | 未登录或凭据无效 |
| 403 | FORBIDDEN | 无权写入对象数据，或无权操作资源 |
| 404 | RESOURCE_NOT_FOUND | 资源不存在或不应向当前用户暴露 |
| 409 | RESOURCE_VERSION_CONFLICT | 资源已被其他操作更新 |
| 409 | REFUND_EXCEEDS_ORIGINAL | 累计退款会超过原消费金额 |
| 409 | INVALID_TRANSACTION_TYPE_CHANGE | 类型变更会留下非法退款或转账关系 |
| 409 | FUNDS_ALLOCATION_NOT_POSSIBLE | 按当前资金分配规则无法完成操作；整笔操作失败，不新增透支流程 |
| 409 | OPENING_STATE_RECALCULATION_CONFLICT | 修改账户起始状态无法安全重建关联资金变动 |
| 409 | IDEMPOTENCY_KEY_CONFLICT | 相同幂等键被用于不同请求 |
| 422 | VALIDATION_ERROR | 字段、金额、枚举或日期不合法 |
| 422 | INVALID_FUND_ALLOCATION | 初始份额不守恒或资金组合不合法 |
| 422 | INVALID_TRANSFER | 转账账户、方向或流动资金条件不满足 |
| 422 | INVALID_REFUND_LINK | 原交易不存在、不属于当前用户或不是有效原消费 |
| 422 | REFUND_REQUIRES_OFFICIAL_SOURCE | 手动创建接口试图创建退款；退款必须来自官方账单导入 |
| 422 | UNSUPPORTED_SOURCE_FILE | 文件格式或平台不支持 |
| 422 | IMPORT_COVERAGE_INCOMPLETE | 文件范围、声明行数或解析完整性不足；不得生成缺失手动交易核对项 |
| 422 | SOURCE_PROFILE_SELECTION_REQUIRED | 多个来源账户档案均可能对应当前文件，需要用户选择一次 |
| 422 | REFUND_ORIGINAL_NOT_RESOLVED | 退款行未能按平台规则唯一关联原消费；不创建退款交易，保留原始证据并报告该行失败 |
| 422 | SOURCE_MAPPING_REQUIRED | 当前来源无法按既有映射安全处理 |
| 500 | INTERNAL_ERROR | 未预期的服务端错误；返回 request_id，不暴露内部堆栈 |

错误码不等于新增产品流程。前端只需根据代码展示明确反馈；具体提示样式留在 UI 阶段设计。

## 10. 原子性与一致性验收要求

每个会改变账务的请求都必须满足：

1. **原子提交：** Transaction、TransactionAccountEffect、AccountFundMovement、退款关联与来源关联等相关变更，要么全部成功，要么全部不生效。
2. **份额守恒：** 一个账户所有资金份额之和等于该账户当前余额。
3. **账户影响守恒：** applied 的账户影响金额与关联资金变动金额合计一致；historical_only 不产生资金变动。
4. **转账守恒：** 两端账户影响金额相等、方向相反；转账只允许流动资金参与，不计收入或消费。
5. **退款守恒：** 退款必须关联原消费，按逆序恢复尚未退回的份额；累计退款不超过原消费金额。
6. **金额修改差额：** 只处理当前交易金额差额，不自动重算其他交易。
7. **删除与重导：** 删除消费时一并删除关联退款；来源证据保留并解除当前关联，后续可重导。
8. **权限边界：** 绑定关系只提供只读查看权；所有写接口服务端校验资源所属用户。
9. **统计一致性：** 退款修正原消费月份；内部转账与信用还款不重复计入消费；预算始终按个人计算。
10. **重复请求：** 幂等重试不能重复创建交易或重复执行资金变动。
11. **导入后核对：** ImportReconciliationItem 不产生账务影响；确认状态更新与原交易分开，不能误删或改写交易。

## 11. 前后端职责映射

| 前端操作 | API 入口 | 后端统一职责 |
|---|---|---|
| 首页打开/切换月份 | GET /overview | 汇总资金份额、个人消费指标与预算 |
| 新增/编辑账户 | POST/PATCH /accounts | 校验账户权限与基本信息 |
| 设置初始余额与日期 | PUT /accounts/{id}/opening-state | 保证初始份额守恒，重新判断账户影响状态 |
| 调整资金归属/性质 | POST /accounts/{id}/fund-adjustments | 在同一账户内等额调整份额 |
| 手动新增账单 | POST /transactions | 统一校验、生成账户影响与资金变动 |
| 查看/筛选账单 | GET /transactions | 按权限和筛选条件查询交易事实 |
| 编辑账单 | PATCH /transactions/{id} | 原子处理当前交易的影响与差额 |
| 删除账单 | DELETE /transactions/{id} | 删除交易与应级联删除的退款，解除来源关联 |
| 导入微信/支付宝账单 | POST /imports | 解析来源、去重、匹配、调用统一交易逻辑；退款只能从此流程创建 |
| 处理官方来源行歧义 | POST /imports/{id}/resolutions | 处理来源行与已有交易的匹配或新交易创建；退款原消费关系需单独动作 |
| 确认未匹配手动交易 | POST /imports/{id}/reconciliation-reviews | 仅确认已查看，不改变交易账务 |
| 查看对象账单 | GET /transactions?view=partner | 检查绑定关系并强制只读 |
| 修改个人预算 | PUT /budgets/{month} | 只修改当前用户预算 |

前端不负责自行推算扣款顺序、拆分资金份额、判断退款应归属哪个月份，或直接修改余额。后端是这些业务规则的唯一执行方。

## 12. 当前不属于本契约的内容

- 登录、注册、验证码、邀请链接生成与认证供应商选择。
- 物理数据库表、SQL、索引、事务实现与部署技术。
- 截图上传、OCR、视觉模型与异步识别任务。
- 信用卡/花呗负债余额管理。
- 账户删除、解绑、透支、复杂异常中心。
- UI 页面结构、视觉样式和交互动画。

上述内容没有被本文件偷偷确定；只有在后续阶段确有需要时才设计。

## 13. 待审阅与下一步

### 本版待审阅重点

1. 接口分组是否与 M1–M5 业务模块和五个产品区域对应。
2. 前端是否能仅依赖这些接口完成账户、账单、首页、预算、绑定与官方导入的核心操作。
3. 交易创建/编辑/删除与资金变动的原子边界是否足够清楚。
4. 导入匹配与人工处理接口是否符合“尽量自动、必要时处理、不建设复杂异常中心”的要求。
5. POST /relationship/binding 的绑定凭据获取方式仍未确定，需在实现绑定功能前补充规则。
6. 退款到账账户与原消费账户不同时，资金份额恢复应落在哪个账户；以及原消费为 credit_purchase、没有现金扣减份额时如何分配退款，均需补充业务规则后再实现相关组合。
7. 修改账户记账起始日期时，若历史交易状态变化，如何安全重建该账户的有效资金变动，需要在物理模型和测试阶段落实原子重算边界。

### 当前状态与后续顺序

本版同步业务规则 v2.7：手动记账不创建退款；官方退款按平台规则关联唯一原消费且到账账户相同，首期不支持信用消费退款；官方文件覆盖范围从元数据和行数校验；导入核对项跨批次唯一，用户可删除手动交易或保留并标记已核对。

工程模块边界、实施任务与路线图已分别记录在 ENGINEERING_MODULE_BOUNDARIES.md、IMPLEMENTATION_PLAN.md 和 ROADMAP.md。

后续顺序：

1. 审阅退款来源未找到原消费时的独立解析动作，以及导入后核对项的状态/确认接口。
2. 选择首期产品形态、技术栈、数据位置与认证方式。
3. 设计物理 Schema、约束、索引与迁移。
4. 从最小可运行垂直切片开始实现，并按 IMPLEMENTATION_PLAN.md 验收。

**说明：** 本文件是候选 API 契约，不代表接口已经部署或代码已经实现。物理数据结构、具体认证方式与技术栈仍待后续阶段决定。
