# 星账 · ledger-final

看清实际账户中的钱、资金归属与性质，便捷记账，以微信/支付宝官方账单补全与核对。双人使用保持个人账本边界，对象只读；手机与桌面共享业务规则。

## 当前状态

核心设计已收敛。开户、双人绑定与对象只读、手动支出及其编辑删除、账户资料维护已有Web/API代码和`writter-dev` PG迁移。三份额开户、归属/性质调整、支出扣减及减额回补已补齐；真实PG用例、登录令牌HTTP、本人/对象页面和刷新读回均已验证，测试数据已清理。当前仍缺初始状态修正、收入/转账、官方导入、统计预算及正式部署，**完整24操作与产品上线尚未验收**。实际证据与剩余条件见[实施计划§2.6](docs/IMPLEMENTATION_PLAN.md#26-阶段控制与当前进度)。

## 代码位置

`apps/api/src/http`放认证与HTTP入口，`apps/api/src/modules`按关系、账户、交易分开，`apps/api/src/domain`放输入规则与业务错误，`apps/api/src/infrastructure`接CloudBase。M2资金处理在受限PG函数中由账户/交易入口共用，不保留另一套未接入运行的TS扣减算法。`apps/web/src/features`按页面功能拆分，`apps/web/src/api`集中调用业务API；数据库变更放`cloudbase/migrations`，真实数据库用例放`tests/integration`，公开响应结构校验放`tests/contract`。

## 六份核心设计入口

| 文档 | 唯一职责 |
|---|---|
| [业务规则](docs/BUSINESS_RULES_DISCUSSION.md) | 产品范围、M1–M5职责、账户/资金/交易/退款/统计行为 |
| [产品功能](docs/PRODUCT_FUNCTION_MAP.md) | 页面与动作、结果展示、用户如何处理不明项 |
| [逻辑模型](docs/LOGICAL_DATA_MODEL.md) | 实体、字段归属、资金真相、来源生命周期与不变量 |
| [API契约](docs/API_CONTRACT.md) | 请求/响应、合法组合、恢复路径、权限与错误 |
| [模块边界](docs/ENGINEERING_MODULE_BOUNDARIES.md) | M1–M5依赖、字段字典、解析规则、写入边界 |
| [实施计划与验证](docs/IMPLEMENTATION_PLAN.md) | 当前进度、路线入口、技术选择、实际验证与待验收项 |

业务规则→模型/API表达同一行为，模块边界约束实现。遇到具体冲突先纠正主责文档再同步引用，不维护平行备选规则。历史过程报告和版本记录不作为当前指令，需追溯时使用Git历史。

## 简单链路

应用用例验证M1权限，协调M4来源解释、M3交易生命周期与M2唯一资金规则，将交易、资金及来源关联一次提交。M5独立查询已提交结果，不参与记账保存。来源不等于交易，读取不等于入账；退款独立、无原消费关联，日期和抵减可编辑。

M1–M5始终是业务模块，不是里程碑编号。每次实现任务限定主责、依赖、允许修改范围、验收；不重复扫描/重构全部项目，不创建第二套余额或保存逻辑。Git主干main，提交使用Conventional Commits。


全部24个公开操作的职责、异常、副作用、边界与调用环节已写入六份核心文档；严格结构统一维护于[openapi.yaml](openapi.yaml)。产品功能包含全部operationId的Mermaid，模块边界包含真实字段到统一账务的数据流。现实现开户、手动支出、双人只读、当前支出的编辑删除和三份额调整；收入/转账、起始状态修正等操作及生产部署仍待后续增量。

当前业务与24个API冻结于`524f2da`。开发起点已选定：React + TypeScript + Vite；Node.js + Express模块化单体；现有CloudBase共享PostgreSQL，通过HTTP API + RPC访问；CloudBase Auth；云托管与Web静态托管。单元/API契约/数据库集成验证各自检查对应边界。理由、原子提交、费用与备份待验证项见[实施计划§7](docs/IMPLEMENTATION_PLAN.md#7-当前选定技术组合与最小验证)。当前尚未部署，不需要兼容旧系统或默认升级数据库。

整体工程路线、阶段交付、各类依赖与24个API归属统一见[阶段交付与依赖](docs/PHASE_DELIVERIES_AND_DEPENDENCIES.md)。实际进度统一见[实施计划§2.6](docs/IMPLEMENTATION_PLAN.md#26-阶段控制与当前进度)。

当前从[实施计划§2.6](docs/IMPLEMENTATION_PLAN.md#26-阶段控制与当前进度)领取下一步工作。[阶段设计](docs/PHASE_DELIVERIES_AND_DEPENDENCIES.md)中的未实施内部函数、物理表、RPC及安装步骤仍是施工候选，不替代业务规则与OpenAPI。后续按账户起始状态与份额维护、收入/转账、官方导入、统计预算推进；每次只细化当前可交付的增量。旧P0逐卡整理方案未执行，已从当前工作入口撤下。
