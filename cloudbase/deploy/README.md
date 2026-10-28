# 双人轻量运行包

此目录只保存部署准备文件，不会自动连接CloudBase或开通资源。当前用户要求数据验证全部本地，不消耗资源点。原业务规则、24个接口、CloudBase Auth与PG数据访问方式保持不变。

## 一个可选同源入口

API可通过`WEB_DIST_PATH`提供本次发布的网页：只开放首页和`assets`，现有`#/accounts`等导航不需要全路径回退；不存在的API或资源仍报错。首页不缓存，带指纹的JS/CSS可长期缓存，账本接口禁止缓存。独立Vite开发和原静态托管方案仍可使用；不配置该变量时API不提供网页。

整个Web仅约1MiB，作为同版本应用代码与API一起交付，适合当前双人低频使用。用户上传、账单、媒体和备份不进入镜像或本地持久化；账务真相仍是PG。没有新增服务、队列、余额算法或客户端直写数据库通道。

## 本地运行准备

1. 根目录执行`npm ci`、`npm run build`。
2. 执行`node tools/release/package.mjs tmp/ledger-release-<新名称> --with-web`。
3. 在输出目录执行`npm ci --omit=dev --workspace apps/api`，注入API原有私有配置；从输出包的`apps/api`运行`node dist/server.js`，设置`WEB_DIST_PATH=../web/dist`和合适的`PORT`。

同源Web应在空`VITE_API_BASE_URL`下构建；编译时只传公开的环境ID、地域与publishable key。后端Key、`CURSOR_SECRET`仅在启动时注入，不能作为Web编译变量、Docker构建参数或文件复制入镜像。真实登录来源仍需平台正确配置；本地替身不验证CloudBase Auth。

## 容器准备

Dockerfile位于此目录，构建上下文必须是仓库根目录。例如使用Docker时，指定`-f cloudbase/deploy/Dockerfile`，传公开构建参数`VITE_CLOUDBASE_ENV_ID`、`VITE_PUBLISHABLE_KEY`，构建根目录`.`。根`.dockerignore`按白名单排除私有配置、node_modules、备份和临时文件。镜像分构建/运行阶段，运行阶段只装API生产依赖，使用非root用户、9000端口和不读数据库的`/healthz`探针。

候选平台配置保存于`cloudrun.template.json`：同一`writter-dev`下单服务`xingzhang`、0.25核/0.5GiB、最小实例0/最大1、9000端口。保持超限按量关闭，不创建第二个环境、不改套餐。模板内两个私有变量占位符必须在部署调用前私下注入，不可直接拿占位符上线。

公开仓库标准Ubuntu运行机已实际构建并隔离运行Docker镜像，[成功记录](https://github.com/AsteriaAnna/ledger-final/actions/runs/40705023724)。运行非root、只读、无外部网络，限制0.25CPU/512MiB；核对页面、资源、固定健康、API401/JSON、私有文件404及SIGTERM退出0。基础镜像digest固定于该次实测值。该检查没有平台登录、账务或CloudBase网络，云端开通/实际平台路由仍待验。

工作树干净且Web私有配置的公开env ID/publishable key有效时，运行`node tools/release/prepare-context.mjs tmp/production-context-<唯一名称>`。只从已提交白名单复制源码，把公开Web配置写入Docker ARG默认值，生成提交SHA、tree及逐文件摘要。它不读取后端Key、不部署、不复制账单/备份/测试替身。正式Key和稳定随机`CURSOR_SECRET`只通过运行时配置注入。

2026-10-28正式开通被自动审批拦下：本机插件可登录并已绑定writter-dev，但`initEnv`的持久变更/资源点风险需要具体确认。环境仍unopened，来源域名、正式双人账号与密钥尚未投入运行，不把名义域名当上线入口。

## 本地验证

运行`npm test --workspace apps/api`，核对同源静态文件隔离、缓存、API鉴权/404和导入中断的原键重试。可用现有`tools/recovery`的本地PGlite运行`node tools/recovery/verify-local-app.mjs`：测试进程只允许本机HTTP和模拟网关，实际记账调用原迁移里的受限RPC。平台Auth是显式替身，绝不将这项检查计作真实平台登录。

安装好输出包运行依赖后，可从根目录运行`node tools/release/verify-package.mjs tmp/ledger-release-<名称>`，启动实际输出包核对网页、指纹资源、健康和未登录拒绝。该检查只用虚构启动配置及本机HTTP，不发起登录/账务请求，不调用CloudBase。

导入写入的内部等待预算改为45秒，普通读取仍12秒；为现有60秒入口留出鉴权/解析余量。不新增自动写重试，也不缩小10MiB或10000行契约。该调整不证明10000行能在限时内完成；同步上限及云端耗点保持待验。
