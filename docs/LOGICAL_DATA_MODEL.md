# 星账｜逻辑数据模型

表达[业务规则](BUSINESS_RULES_DISCUSSION.md)，不指定物理表、数据库或ORM。模块仍为M1–M5。

## 1. 实体和职责

| 实体 | 所属 | 必要概念与约束 |
|---|---|---|
| User | M1 | 内部ID、认证主体、显示名称；身份服务端验证 |
| RelationshipBinding | M1 | 双方用户、有效状态/时间；仅扩大明确读权限 |
| Account | M2 | holder_user_id、custodian_user_id、name、account_type、opening_date、version；实际账户；不另存可写余额 |
| Transaction | M3 | owner、type、accounting_semantics、amount_minor、occurred_at、category_code、merchant、note、可选source_account_profile_id、refund_kind、affects_spending、version |
| TransactionAccountEffect | M3 | transaction、account、role、signed_amount_minor、status；applied或historical_only |
| AccountFundMovement | M2/M3 | account、fund_owner、fund_type、signed_amount_minor、reason、operation_group、可选effect、effective_at |
| SourceAccountProfile | M4 | owner、platform、label、可选账号指纹、metadata；昵称不作唯一身份 |
| SourcePaymentMethodMapping | M4 | owner、profile、canonical_method_key、account_id、version；unique(profile,key) |
| ImportBatch | M4 | owner、文件指纹、导出时间、声明范围/类型/行数、实读数、profile可空、status、version、汇总 |
| SourceRecord | M4 | profile、official_transaction_id、当前规范化来源事实、当前transaction可空、当前观察指针；unique(profile,official_transaction_id) |
| SourceObservation | M4 | batch、source可空、行号、完整raw_fields、原始时间/状态/金额/渠道、导出时间、内容指纹 |
| ImportReconciliationItem | M4 | profile、manual_transaction、first/last_batch、status；unique(profile,transaction) |
| MonthlyBudget | M5 | owner、month、amount_minor、version；unique(owner,month) |

行处理结果放在batch/observation的处理字段或派生视图，不新建工作流实体。用户确认的转账角色与关联决定保存在来源处理字段，不混入raw_fields，不随重导重置；官方重要事实变化时重新校验。观察在档案未定时只关联batch，档案确定后再关联SourceRecord。一来源最多关联一笔有效交易，一交易可有多条来源。

## 2. 资金真相

当前余额=截止查询时刻该账户全部有效资金变动之和；当前份额按account+fund_owner+fund_type分组。份额均非负，合计等于余额；允许本人流动、本人存款、对象存款，未绑定无对象份额。

reason仅需opening、manual_allocation、transaction。存款基准由opening+manual_allocation净额派生，缺口=max(基准−当前存款,0)，不另存目标存款。初始余额也是opening记录合计，不另维护一份金额。

手动调整同账户净额为0；applied effect对应资金变动合计=effect金额；historical_only不生成资金变动。内部transfer两effects等额反向，每端独立判断起始日。当前交易的金额编辑调整其有效影响，不制造普通收入；无需事件溯源体系。

## 3. 日期和退款

occurred_at为可编辑记账时间，带时区、不得未来，用于统计月份与起始日判断。官方source_occurred_at只在SourceObservation保存，详情以source_summaries数组返回，不能用一个可变标量代表多个来源。

refund使用accounting_semantics=refund_inflow；refund_kind=merchant_refund|transfer_return；affects_spending严格布尔。非refund不存这两个专属字段。不建立RefundLink、原消费ID、累计退款额度或消费删除级联。

Transaction.source_account_profile_id用于手动明确声明来源或官方创建时默认来源，不作去重键；多来源仍通过SourceRecord表达。source事实与用户编辑分别保存，重导不覆盖日期/金额/分类/抵减设置。

## 4. 编辑删除和原子性

合法空改动不新增版本或资金变动；权限、字段及已选择的版本条件仍先校验。支出金额差额遵循业务扣减/回补；收入、退款改金额/账户先撤销自身旧计划再生成新计划。仅改抵减不动资金；仅改日期且历史/有效状态不变时保留份额计划、改生效日期。跨起始日撤销/生成当前effect，转账两端分别处理，不重算其他交易。

任何修改、删除使当前份额负值则整笔拒绝。删除仅撤销本交易、effects和movements；清空相关SourceRecord当前关联，保留来源观察，消费与退款互不级联。

M3保存交易、effects、movements与M4来源关联必须在同一Unit of Work提交。失败不得留下半笔账务、单边转账或悬空当前关联。version条件比较是否采用见实施计划D3；来源身份唯一和资金守恒始终是业务约束，不因未选择请求重试保护而取消。

## 5. 来源生命周期

| 当前状态 | 下一步 |
|---|---|
| 新来源，字段/映射齐全 | M3创建并关联 |
| 来源已有有效关联，官方重要事实不变 | 留观察，保留用户编辑，不再创建 |
| 来源关联为空：未成功或已删除 | 用最新事实/映射重新评估，允许创建 |
| 较旧导出 | 留观察，不覆盖当前事实 |
| 同导出时间但事实冲突 | needs_review，不按到达先后静默选一方 |
| 无交易，失败/关闭变有效 | 重新评估，不按来源存在跳过 |
| 已入账后官方重要金额/方向/类型/有效性变动 | 待处理差异，不静默改账 |

同文件只复用解析，不封锁新操作。若选择请求幂等，键重试只重放原请求结果。存活交易的重复来源与已删除交易的恢复必须分开判断。

## 6. 完整性、结果和核对

batch保存declared_from/to、exported_at、export_type、declared_record_count、parsed_record_count；structural_complete只表达结构、全量范围、身份与时间完整。effective_to不晚于exported_at。reconciliation_eligible与blockers另表达缺失核对资格。

V1任一行unsupported、needs_review或failed则该batch不自动生成缺失核对项，其他可处理行正常入账。银行卡手动交易没有明确来源档案不核对；已确认余额账户档案可确定归属；已有关联官方来源的交易不再核对。

核对项状态pending_confirmation、kept_manual、matched_to_source。保留仅改状态；删除调用M3并原子关闭/删除核对项；重叠复用，后续匹配结案。

行disposition为created、linked_existing、duplicate_existing、unsupported、ineffective、needs_review、failed，七类合计=parsed_record_count。phase是阶段，不能代替结果。观察更新是附加标记，不重复计行；档案未定的needs_review行可以没有source_record_id。核对项计数不混入来源行计数。

## 7. 权限和统计

实体有直接owner或可追溯归属。一次操作验证batch、source、profile、mapping、account、transaction的本人权限与相互关系。对象只读账单不返回raw_fields、对方账号或文件。

M5按已保存expense减启用抵减的refund，余额来自有效movements。历史交易可参与消费但不影响余额。Category仅受控字典/other，不增加用户分类管理模块；没有费用转账、负债、跨个人账本写入模型。
