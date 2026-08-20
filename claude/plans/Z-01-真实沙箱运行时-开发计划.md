# Z-01 真实沙箱运行时 开发计划（zgz）

> 执行前说明：本计划批准后，执行阶段将其复制到 `/data/zgz/datasandbox/claude/plans/` 目录留存
> （用户要求"计划在我同意后放到 claude/plans 里面"）。

## Context

数据沙箱系统管理 MVP 当前约 41% 完成度，其中"沙箱管理"页面与后端已由 xzh 在 `develop/xzh`
分支实现（后端提交 `3a4b9ee`、前端提交 `a69c829`，**xzh 分支仅领先 develop/zgz 1 个提交**），
但沙箱**启动是"假运行"**：`startKuscia` 在 `data-sandbox.kuscia.enabled=false` 时直接返回空串，
`sandboxAction` 无条件置 RUNNING——没有真实容器，`endpoint` 字段从未写入。

本任务（Z-01）要把它变成**真实沙箱运行时**：注册真实 AppImage 镜像、沙箱操作落到真实
Kuscia Job、状态与容器真实同步、为每个沙箱生成可访问且带鉴权的开发端点（进入 Jupyter/
SecretFlow 等开发环境），失败时返回明确错误。

用户已确认的三个决策：
1. **代码引入**：`git merge origin/develop/xzh` 到 develop/zgz（前后端仓库各一次）
2. **测试环境**：data-sandbox-package 仓库地址已确认
   `https://github.com/M0rtzz/data-sandbox-package.git`（`develop/zgz` 分支 = `38ab866`，
   已验证存在），拉取到 `/data/zgz/datasandbox/data-sandbox-package` 并建立分支跟踪
3. **前端入口 UI**：zgz 自己在 secretpad-frontend 的 develop/zgz 上实现（合并 xzh 代码后）

## Z-01 任务简介（写给刚上手的 zgz）

- **沙箱是什么**：平台上的一条沙箱记录 = 一个真实的隔离开发环境（Jupyter/Python、
  JAR 运行环境、SecretFlow），底层是 Kuscia 平台上的一个 Job（一组容器）。
- **现在的问题**：点"启动"只是改数据库状态为 RUNNING，没有容器真的跑起来。
- **要做的事**：① 把 Jupyter/Python、JAR、SecretFlow 做成 Kuscia 的 AppImage（镜像
  注册模板）并注册；② 启动/停止/销毁真实调用 Kuscia 创建/停止/删除 Job，失败明确报错；
  ③ 后台定时任务查询 Kuscia Job 真实状态回写数据库（带"意图保护"，不覆盖用户操作意图）；
  ④ 沙箱运行后从 Kuscia 拿到容器对外端点（如 `10.x.x.x:31234`），生成带一次性 token
  的访问 URL，前端"打开开发环境"跳板转发进入，鉴权统一收敛在 SecretPad 层。

## 阶段划分

| 阶段 | 内容 | 关键产出 |
|---|---|---|
| A | 合并与基线 | merge xzh 提交、构建跑通、MVP 页面可用 |
| B | 运行时真实化与状态同步（核心） | 状态机、intent 意图保护、失败路径、V7 迁移 |
| C | AppImage 制作与注册 | 3 个模板 + 注册脚本 + 镜像种子补充 |
| D | 开发端点与鉴权跳板 | endpoint 提取存储、dev-token、代理转发 |
| E | 前端入口 UI | "打开开发环境"按钮 + 端点列 + 状态增强 |
| F | 端到端验证 | data-sandbox-package 个人实例 + E2E 清单 |

## 阶段 0：拉取 data-sandbox-package（前置）

```bash
cd /data/zgz/datasandbox
git clone -b develop/zgz https://github.com/M0rtzz/data-sandbox-package.git   # → ./data-sandbox-package
```
- `git clone -b develop/zgz` 自动检出该分支并建立对 `origin/develop/zgz` 的跟踪关联
- 验证：`git branch --show-current` = `develop/zgz`、`git status` 与远程一致
- 目的：获得 `develop.sh`（个人测试实例启动脚本，含 AppImage 注册流程挂接点）与
  构建配置（JAR 镜像等制品约定），阶段 F 使用

## 阶段 A：合并与基线

1. `cd /data/zgz/datasandbox/secretpad && git merge origin/develop/xzh`（前端仓库同样操作）
2. 构建：后端 `mvn -T 4 compile`；前端 `pnpm install && pnpm build`（或 dev 起 9099）
3. 启动个人实例（后端 8099 / 前端 9099，**禁占 8088/9088**），确认：
   - SQLite 建出 `ds_sandbox`/`ds_sandbox_image`/`ds_sandbox_snapshot` 表
     （V6 生效：center/edge/p2p 三份均有 V6 文件；注意 center 为完整版 247 行、p2p/edge
     为压缩版，**内容不同属正常**，无需修改）
   - `GET /api/v1alpha1/data-sandbox/sandboxes` 可访问
4. 里程碑：MVP 页面（含假运行行为）可操作，作为阶段 B 改造的对照基线

## 阶段 B：运行时真实化与状态同步（核心）

### 新建：状态机纯类
`secretpad-web/src/main/java/org/secretflow/secretpad/web/service/sandbox/SandboxStatusMachine.java`
（纯函数、可单测，不依赖 Spring）：
- 枚举 `SandboxStatus { STOPPED, STARTING, RUNNING, STOPPING, ERROR, EXPIRED, DESTROYED }`、
  `SandboxIntent { NONE, START, STOP }`
- `canAction(from, action)`、`mapKusciaState(kusciaState, localStatus, intent)`（受保护映射）、
  `isKusciaTerminal(state)`

### 修改：`secretpad-web/.../web/service/DataSandboxMvpService.java`

**START 分支重写**（原 :153-186）：
1. 校验：EXPIRED/DESTROYED 拒绝；STARTING/STOPPING 拒绝（防重复提交）
2. 先落库意图：`status='STARTING', intent='START'`，再调 `startKuscia`
3. 成功 → **保持 STARTING 等同步推进为 RUNNING**（不再直接置 RUNNING）；失败 →
   `ERROR + last_error=明确文案`，**绝不置 RUNNING**

**`startKuscia`（:687）失败路径**：
- `kusciaEnabled=false` 时不再返回空串，返回明确错误"Kuscia 运行时未启用…请启用后重试"
- `createJob` code!=0 / 异常 → 返回错误消息（保留原样）

**STOP 分支重写**：先落 `STOPPING + intent=STOP`，再调 `stopKuscia`；失败 → ERROR（不假 STOPPED）；
成功 → 等同步置 STOPPED。**DESTROY 分支**：`deleteKuscia` 失败 → ERROR + 抛明确异常（不吞错）。

**`syncKusciaStatuses`（:631-650）改造——意图保护**（每条 UPDATE 带 WHERE 条件，禁止无条件覆盖）：
| 本地状态 + intent | Kuscia Job state | 结果 |
|---|---|---|
| STARTING + START | PENDING | 保持 STARTING |
| STARTING + START | RUNNING | RUNNING，清 intent，提取 endpoint |
| STARTING + START | FAILED/REJECTED | ERROR + last_error=errMsg |
| STOPPING + STOP | 终态(SUCCEEDED/CANCELLED/FAILED 等) | STOPPED，清 intent |
| RUNNING + 无 intent | PENDING | **保持 RUNNING**（修复"打回 STARTING"bug） |
| RUNNING + 无 intent | SUCCEEDED/SUSPENDED/CANCELLED | STOPPED |
| RUNNING + 无 intent | FAILED | ERROR |
| STOPPED/ERROR/EXPIRED/DESTROYED | 任意 | 不覆盖 |

**`expireSandboxesAndCheckAlerts`**：到期先 `stopKuscia` 成功才置 EXPIRED；失败 → ERROR。

**kusciaEnabled=false 全面表现**：START → ERROR（禁假 RUNNING）；STOP/RENEW/SNAPSHOT/DESTROY
本地可用；sync 首行 return；前端据此隐藏"打开开发环境"入口。

### 配置
`config/application.yaml` 的 `secretpad.data-sandbox` 段新增：
```yaml
dev-endpoint:
  token-ttl-minutes: ${DATA_SANDBOX_DEV_TOKEN_TTL:30}
  proxy-timeout-seconds: ${DATA_SANDBOX_PROXY_TIMEOUT:30}
```

## 阶段 C：AppImage 制作与注册

### 三个模板（仿 `scripts/templates/sf-serving.yaml` 格式，`kind: AppImage`）
放 `scripts/templates/`（或 `scripts/deploy/data-sandbox/`）：
1. **data-sandbox-jupyter.yaml**：`metadata.name: data-sandbox-jupyter`，命令
   `start-notebook.sh --ServerApp.ip=0.0.0.0 --ServerApp.port=8888 --ServerApp.token=''`，
   端口 `{name: web, port: 8888, protocol: HTTP, scope: Cluster}`（**scope 必须 Cluster**，
   Kuscia 才分配集群外可达地址并回填 endpoints），readinessProbe `/api/status`
2. **data-sandbox-jar.yaml**：`data-sandbox-jar`，`exec java -jar ${APP_JAR:-/app/app.jar}`，
   端口 `{name: app, port: 8080, scope: Cluster}`
3. **data-sandbox-secretflow.yaml**：`data-sandbox-secretflow`，jupyter lab + ray start，
   端口 `{name: web, port: 8888, scope: Cluster}`

安全决策：容器内不设 Jupyter token（仅 Kuscia 集群内可达），鉴权全部收敛在 SecretPad
跳板层（阶段 D）。

### 注册脚本
新建 `scripts/deploy/data-sandbox/register-data-sandbox-appimages.sh`，仿
`scripts/deploy/common/utils.sh` 的 `applySfServingAppImage`（:430）模式：
sed 渲染镜像名/标签占位符 → `docker cp` 进 KUSCIA_MASTER_CTR → `docker exec kubectl apply -f`
（kubectl apply 幂等）。在 data-sandbox-package 安装流程挂接或文档化手动执行。

## 阶段 D：开发端点与鉴权跳板

### 端点生成与存储
- **数据来源（proto 已确认）**：`queryJob → data.status.tasks[].parties[].endpoints[]`，
  取 `port_name='web'`（JAR 为 'app'，由镜像属性决定）且 `scope='Cluster'` 的 `endpoint`
- **时机**：`syncKusciaStatuses` 映射为 RUNNING 时提取并写入 `ds_sandbox.endpoint`；
  离开 RUNNING 保留历史端点不清空，但跳板强制校验 status==RUNNING

### 鉴权（一次性 token + 同域跳板）
1. **新接口** `POST /api/v1alpha1/data-sandbox/sandboxes/dev-token`（`DataSandboxController.java`）：
   用户 token 鉴权 + owner 校验 + status==RUNNING 校验 → 生成 32 hex token（DB 存 sha256）
   + 过期时间（默认 30min，每次进入重置）→ 返回 `{url: "/api/v1alpha1/data-sandbox/proxy/{id}?token=<明文>"}`
2. **新建** `SandboxProxyController.java`：`GET /api/v1alpha1/data-sandbox/proxy/{sandboxId}/**`；
   token 校验（恒时比较 + 未过期 + RUNNING）→ 审计 `DEV_ENDPOINT_ACCESS` → 目标地址**仅允许
   来自 DB `endpoint` 列**（防 SSRF）→ 纯 Servlet 双向流式转发（重写 Host；WebSocket 升级后
   双向字节拷贝，无需新依赖，Jupyter Lab 依赖 WS）
3. **LoginInterceptor 放行**（仿现有 X-Client-Id 分支 :199-208）：`/data-sandbox/proxy/` 前缀
   → 校验 query token → 构造虚拟用户；`/dev-token` 仍走正常用户 token 鉴权
4. 安全汇总：token 30min 过期、仅 owner/管理员签发、跳板目标白名单（仅 DB 值）、同域跳板
   绕开浏览器 CORS/CSP、不转发 Cookie 与 User-Token、记录审计

## 阶段 E：前端入口 UI（zgz 在 develop/zgz 自做）

修改 `secretpad-frontend/apps/platform/src/modules/sandbox-manager/index.tsx` 与
`apps/platform/src/services/data-sandbox.ts`：
1. 新增契约 `devToken: (id) => post('/sandboxes/dev-token', { id })`
2. 操作列新增"开发环境"按钮：`status==='RUNNING' && endpoint` 时显示 → `devToken` →
   `window.open(url, '_blank')`；失败 message.error 展示后端明确错误
3. 新增"端点"列（可复制）；`statusColors` 补 `STOPPING: 'processing'`、`DESTROYED: 'default'`
4. 启动交互增强：点击后提示"启动中（约 30s 内完成）"（sync 30s 轮询延迟是预期行为）

## 阶段 F：端到端验证（需 data-sandbox-package）

1. **前置依赖**：data-sandbox-package 已在阶段 0 拉取（`./data-sandbox-package`）→ 按其
   `develop.sh` 文档建个人实例（后端 8099 / 前端 9099）→ 跑 AppImage 注册脚本 →
   `kubectl get appimage` 确认 3 条存在（具体以包内 README/develop.sh 实际用法为准）
2. 按下方"前端页面 E2E 测试清单"逐条执行

## 数据库迁移：V7__data_sandbox_runtime.sql

三份同内容文件（SQLite 语法，center/edge/p2p）：
`config/schema/{center,edge,p2p}/V7__data_sandbox_runtime.sql`：

```sql
alter table ds_sandbox add column intent varchar(16) not null default '';
alter table ds_sandbox add column kuscia_job_state varchar(32) not null default '';
alter table ds_sandbox add column runtime_meta varchar(2048) not null default '';
alter table ds_sandbox add column endpoint_token varchar(128) not null default '';
alter table ds_sandbox add column endpoint_token_expires_at varchar(32) not null default '';
alter table ds_sandbox add column endpoint_updated_at varchar(32) not null default '';
alter table ds_sandbox_image add column dev_port_name varchar(16) not null default 'web';
update ds_sandbox_image set kuscia_app_image='data-sandbox-jupyter', dev_port_name='web' where id='img-jupyter-scipy';
update ds_sandbox_image set kuscia_app_image='data-sandbox-secretflow', dev_port_name='web' where id='img-secretflow';
insert or ignore into ds_sandbox_image(id, name, image_ref, kuscia_app_image, dev_port_name, enabled, created_by, created_at, updated_at)
values ('img-jar', 'Java Runtime (JAR)', 'eclipse-temurin:17-jre', 'data-sandbox-jar', 'app', 1, 'system', datetime('now'), datetime('now'));
```

状态变迁审计复用 `ds_unified_log`；运行时摘要写 `runtime_meta` JSON。不新增表。

## 测试方案

### 后端单元/集成测试（每个提交必带）
- **扩展 mock**：`secretpad-api/client-java-kusciaapi/.../mock/service/JobService.java`
  增加可配置状态注入（jobState/taskStates/endpoints/createJobCode 静态 setter）
- **新建** `secretpad-web/src/test/java/.../web/service/DataSandboxKusciaIT.java`
  （@SpringBootTest + test profile + MockKusciaGrpcServer，`kuscia.enabled=true`）：
  ① START 成功链路（createJob=0 → STARTING → mock RUNNING → sync → RUNNING + endpoint
  写入 + intent 清空）；② START 失败（createJob code!=0 → ERROR + last_error，断言非 RUNNING）；
  ③ kusciaEnabled=false → ERROR 含"未启用"；④ RUNNING + mock PENDING → sync 后仍 RUNNING
  （回归 bug）；⑤ STARTING + mock FAILED → ERROR；⑥ STOPPING + 终态 → STOPPED；stopJob 失败
  → ERROR 非 STOPPED；⑦ 到期 → stop 成功 EXPIRED / 失败 ERROR；⑧ DESTROY → deleted=1
- **新建** `SandboxStatusMachineTest`（纯类单测，覆盖全流转表）
- **新建** `DataSandboxControllerTest`（MockMvc）：dev-token（未登录 401/非 owner 403/非
  RUNNING 明确错误）、proxy（无 token 401/过期 401/正确转发 200）

### 前端页面 E2E 测试清单（用户核心诉求——通过页面测全部功能）

前置：个人实例已起（前端 9099）、AppImage 已注册、Jupyter 镜像已拉取。

| # | 前端操作步骤 | 预期结果 | 失败场景检查 |
|---|---|---|---|
| 1 | 登录 → 沙箱管理 → 创建沙箱（Jupyter 镜像，2核/4G/20G/7天/INTERNAL_ONLY） | 列表出现新沙箱，状态 STOPPED | 镜像不可用 → 创建弹窗报错；配额不足 → 明确配额错误 |
| 2 | 点击"启动" | 状态先 STARTING（约 30s）→ RUNNING；last_error 为空 | createJob 失败 → ERROR + 明确文案；kuscia 未启用 → ERROR（**禁假 RUNNING**） |
| 3 | 点击"打开开发环境" | 新标签页打开 Jupyter Lab，可新建 notebook 运行 Python 代码 | token 过期 → 401 明确提示；非 owner → 403；端点未就绪 → 明确错误 |
| 4 | 返回列表点击"停止" | STARTING→STOPPING→STOPPED；再点"打开开发环境"被拒 | stopJob 失败 → ERROR 不假 STOPPED |
| 5 | 点击"续期 7 天" | expires_at 延长，状态不变 | — |
| 6 | 点击"快照" | 快照记录 COMPLETED，产物路径存在、校验和匹配 | 目录不可写 → FAILED + 明确错误 |
| 7 | 点击"销毁"（Popconfirm 确认） | 行消失（deleted=1），配额回收 | deleteJob 失败 → 明确错误 |
| 8 | 强制一致性检查 | `sqlite3 db/secretpad.sqlite "select id,status,intent,kuscia_job_state,endpoint from ds_sandbox"` —— 无"假 RUNNING"（RUNNING 行必有对应 Kuscia Job 与端点） | — |
| 9 | 用 JAR、SecretFlow 镜像各重复 1-3 步 | 均能拉起并进入开发端点 | SecretFlow 镜像大，拉取超时 → 检查镜像源 |

## 关键文件

- 后端核心：[DataSandboxMvpService.java](secretpad/secretpad-web/src/main/java/org/secretflow/secretpad/web/service/DataSandboxMvpService.java)（sandboxAction/startKuscia/stopKuscia/deleteKuscia/syncKusciaStatuses/expire）
- 新建：`secretpad-web/.../web/service/sandbox/SandboxStatusMachine.java`、`.../web/controller/SandboxProxyController.java`
- 修改：[DataSandboxController.java](secretpad/secretpad-web/src/main/java/org/secretflow/secretpad/web/controller/DataSandboxController.java)（+dev-token）、[LoginInterceptor.java](secretpad/secretpad-web/src/main/java/org/secretflow/secretpad/web/interceptor/LoginInterceptor.java)（proxy 放行）
- 迁移：`config/schema/{center,edge,p2p}/V7__data_sandbox_runtime.sql`
- 模板+脚本：`scripts/templates/data-sandbox-{jupyter,jar,secretflow}.yaml`、`scripts/deploy/data-sandbox/register-data-sandbox-appimages.sh`
- 前端：[sandbox-manager/index.tsx](secretpad-frontend/apps/platform/src/modules/sandbox-manager/index.tsx)、[data-sandbox.ts](secretpad-frontend/apps/platform/src/services/data-sandbox.ts)
- 新建：`/data/zgz/datasandbox/data-sandbox-package/`（克隆自 data-sandbox-package 仓库
  `develop/zgz`，含 develop.sh 与构建配置，阶段 0 完成）
- 复用：`KusciaGrpcClientAdapter`（createJob/queryJob/stopJob/deleteJob）、`MockKusciaGrpcServer`、`utils.sh applySfServingAppImage` 模式、`EdgeRequestFilter` 转发模式、`LoginInterceptor` X-Client-Id 分支

## 风险与依赖

| 风险 | 等级 | 缓解 |
|---|---|---|
| develop.sh 实际用法与预期不一致 | 中 | 阶段 0 拉取后先读包内 README 确认（端口/目录/AppImage 挂接点），再进入阶段 F |
| 大镜像下载慢/内网受限 | 高 | 阶段 F 前置拉取；确认 k3s registry-mirrors 或离线导入 |
| Jupyter WebSocket 跳板复杂度 | 中 | 纯 Servlet 双向流式管道；备选降级轮询 |
| V7 alter 在 SQLite 的兼容性 | 中 | 阶段 A 实测一次迁移；p2p/edge 用压缩版 V6 已有表（无需补 V6） |
| Kuscia 0.6.0b0 对 scope=Cluster endpoint 回填格式 | 中 | 先 mock 通 Java 侧，阶段 F 实测真实格式，留归一化层 |

## 执行后收尾

1. 将本计划复制到 `/data/zgz/datasandbox/claude/plans/`
2. 前后端分别提交（每提交带对应测试），推送 develop/zgz；提交信息注明模块/迁移/兼容性影响
