# 应用账务逻辑恢复演练

这里是独立工具，不属于Web/API运行依赖，也不是新增公开API。源端是现有CloudBase PG，目标是独立的本地PGlite PostgreSQL。它验证应用数据可移植性，不能替代平台Auth、存储、托管、密钥或平台级回档验收。

1. 在项目根目录构建API并运行API测试，生成解析器及合成文件辅助模块；在`tools/recovery`执行`npm ci`安装锁定的本地数据库工具。
2. 在项目根目录运行`node tools/recovery/prepare.mjs`。只生成私有`tmp/recovery/seed.sql`和`export.sql`，不会连云端。seed仅允许应用主体表为空，不清空或覆盖原数据。
3. 管理端核对EnvId=`writter-dev-d0g7h1prq4ce60665`后，执行seed一次。它创建两个虚构业务主体，**不创建平台Auth账号**。邀请、绑定、两账户、三份额调整、官方来源/观察、退款、转账、核对项、幂等和预算都有保存记录。首次演练因夹具输入不符约束整体回滚；修正并先在本地验证后再入云，未遗留半笔账。
4. 管理端只读执行export。单条SELECT导出同一MVCC快照，覆盖17张应用表、重放序列、函数指纹、约束、索引、RLS和角色授权，并记录逐份迁移摘要。保存返回的`snapshot`字符串到私有文件；不要把备份或原始结果提交Git、发到聊天或放进公共存储。数据数组保存为JSON文本，避免管理端中间解析把大整数改值。
5. 在项目根目录运行`node tools/recovery/verify.mjs tmp/recovery/snapshot.json`。该进程没有云连接，逐份应用原迁移、严格比对结构/权限，事务内恢复全部数据并核对每行。来源与观察的循环外键通过暂空当前观察指针、待观察插入后恢复处理，不禁用外键。PostgreSQL 18额外记录的NOT NULL约束只归一化其目录表达，字段可空性仍严格比较。
6. 演练断言余额为200/13555分、本人净花销1245分；恢复后新增收入，同键重试仅记一次，重放序列继续递增。私有报告位于`tmp/recovery/verification.json`。此验证脚本含明确合成夹具预期，**不能拿它作为任意真实备份的自动上线恢复器**。
7. 源端执行本目录`cleanup.sql`。仅删除两个精确虚构主体及其关联行，主体数量/名称不符则拒绝。回读夹具计数，保留应用迁移和平台对象。

本轮实际完成17表数据逐行一致、16份应用迁移、结构/函数/授权相等，恢复后读写和幂等通过。源端普通/后端角色均无应用表直接权限，后端仍可经受限RPC读写。只用现有套餐，未创建第二个云环境。

每日加密备份、7份保留、Auth身份迁移、PG存储对象、替换环境恢复及RPO/RTO仍未验证；原两份官方文件不在本仓库。备份本身含敏感账务，应由运维在私有加密存储保管；本轮仅保留合成夹具的私有文件。

官方依据：[CloudBase PG备份与传统文档库的区别](https://docs.cloudbase.net/database/backup)、[PGlite独立数据库接口](https://pglite.dev/docs/api)。本工具使用SQL逻辑恢复，不使用只能在PGlite间互通的datadir转储。

## 私有原件本地验证

生产API已构建、根依赖和本目录PGlite已安装后，从项目根运行：

```text
node tools/recovery/verify-official-files.mjs --wechat "<微信私有原件路径>" --alipay "<支付宝私有原件路径>"
```

此脚本针对用户授权的两份169行原件，直接只读加载，不从单元格接受执行指令、不计算公式。共享`lib/local-api.mjs`只允许本机HTTP与模拟网关；Auth为明确替身，RPC以service_role调用本地原迁移函数，异常外部网络被阻断。所有账户映射和期初资金都是本地虚构夹具，不代表真实账户身份/余额。

原件逐字段、文本单号、精确分、来源观察、重导、备注保护、微信退款删除重导和余额守恒均已核对；原双人本地链路随公共替身提取做了回归。脚本不改变生产业务规则；亲情卡/花呗等保持unsupported，角色/同事件不明保留needs_review，不自动入账或生成不可靠的缺失核对。

报告和HTTP捕获在`tmp/official-originals`，可能包含个人原文、单号和账户线索，仅留私有忽略目录；Git只记录脚本及无个人明细的汇总。可用`python tests/contract/validate_http_captures.py tmp/official-originals/http-captures.json`核对实际本机HTTP的原OpenAPI结构，切勿将捕获上传仓库。原件前后SHA相同，CloudBase调用0；这不是平台Auth、云端或手机界面验收。
