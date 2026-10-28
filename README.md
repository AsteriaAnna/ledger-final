# 星账 · ledger-final

看清实际账户中的钱、资金归属与性质，便捷记账，以微信/支付宝官方账单补全与核对。双人使用保持个人账本边界，对象只读；手机与桌面共享业务规则。

## 当前状态

星账候选版`0.1.0-rc.1`已发布：[打开星账](https://xingzhang-337165-13-1428502724.sh.run.tcloudbase.com/)。使用私下开通的两个正式账号分别登录。网页、资源及健康入口已核对，后台仍使用现有个人版writter-dev、超限按量关闭；未代替用户登录或在云端写测试账务。完整线上功能验收、未测上限、iOS真机与平台完整恢复仍待完成，不能把入口可达当作全部验收。

账户、对象只读、三类手动交易维护、官方XLSX导入及来源生命周期、独立退款、期初修正、统计预算和分页筛选的24个公开操作均已接入。两份官方原件338行本地复测通过，未支持和待处理行原样保留；手机触摸视口和Linux容器检查通过。首份上线基线已加密并独立本地恢复，异地保管及自动日备份尚未设置。当前证据及剩余条件见[实施计划§2.6](docs/IMPLEMENTATION_PLAN.md#26-阶段控制与当前进度)，精确发布配置见[发布记录](cloudbase/deploy/releases/0.1.0-rc.1.json)。

## 代码位置

`apps/api/src/http`放认证与HTTP入口，`apps/api/src/modules`按关系、账户、交易分开，`apps/api/src/domain`放输入规则与业务错误，`apps/api/src/infrastructure`接CloudBase。M2资金处理在受限PG函数中由账户/交易入口共用，不保留另一套未接入运行的TS扣减算法。`apps/web/src/features`按页面功能拆分，`apps/web/src/api`集中调用业务API；数据库变更放`cloudbase/migrations`，真实数据库用例放`tests/integration`，公开响应结构校验放`tests/contract`。

运行配置、发布包、费用阻塞与独立恢复步骤见[运行维护](docs/OPERATIONS.md)。恢复工具单独放`tools/recovery`，不进入应用运行依赖；私有备份和合成运行结果留在忽略目录。

双人轻量部署使用[同源Web/API运行包](cloudbase/deploy/README.md)，单服务0.25核/0.5GiB、最小0/最大1实例。后续数据验证均在本地或公开仓库免费标准Linux运行机；已授权的正式部署、正常使用及运维备份与验证预算分开，不扩大套餐或开启超限按量。

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


全部24个公开操作的职责、异常、副作用、边界与调用环节已写入六份核心文档；严格结构统一维护于[openapi.yaml](openapi.yaml)。产品功能包含全部operationId的Mermaid，模块边界包含真实字段到统一账务的数据流。现有实现覆盖M1–M5，路由集合检查与真实HTTP结构验证分开记录；应用账务已独立恢复、真实原件本地复测通过，正式托管、平台完整恢复及未测上限仍待验收。

当前业务与24个API冻结于`524f2da`。开发起点已选定：React + TypeScript + Vite；Node.js + Express模块化单体；现有CloudBase共享PostgreSQL，通过HTTP API + RPC访问；CloudBase Auth；云托管与Web静态托管。单元/API契约/数据库集成验证各自检查对应边界。理由、原子提交、费用与备份待验证项见[实施计划§7](docs/IMPLEMENTATION_PLAN.md#7-当前选定技术组合与最小验证)。当前候选已部署，后续迁移与API变更须保护已有账务；不默认升级数据库。

整体工程路线、阶段交付、各类依赖与24个API归属统一见[阶段交付与依赖](docs/PHASE_DELIVERIES_AND_DEPENDENCIES.md)。实际进度统一见[实施计划§2.6](docs/IMPLEMENTATION_PLAN.md#26-阶段控制与当前进度)。

当前从[实施计划§2.6](docs/IMPLEMENTATION_PLAN.md#26-阶段控制与当前进度)领取下一步工作。[阶段设计](docs/PHASE_DELIVERIES_AND_DEPENDENCIES.md)中的未实施内部函数、物理表、RPC及安装步骤仍是施工候选，不替代业务规则与OpenAPI。当前继续全流程、部署和独立恢复验证；每次只细化当前可交付的增量。
