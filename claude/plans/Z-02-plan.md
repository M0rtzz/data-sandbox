# Z-02 资源调度与隔离 开发计划（zgz）

> 执行前说明：本计划批准后，**执行阶段的第一步**就是把这份（含用户补充的）最终版计划原样
> 写入 `/data/zgz/datasandbox/claude/plans/Z-02-plan.md` 留存，然后再开始 Stage 0。

## Context

Z-01 已交付"真实沙箱运行时"（Kuscia Job 同步 + 开发端点鉴权跳板 + 3 个 AppImage + V7 迁移），
但存在三类遗留问题，本任务一并解决：

1. **环境限制（Z-01 报告项）**：宿主为 rootless docker，k3s 无法创建沙箱容器
   （runc 写 `cpu.weight` 失败）。管理员已修复根因——`user-996.slice` 现已下放
   `cpu io memory pids` 控制器，并授予了 rootful docker 权限。**用户决策：直接把个人实例
   迁移到 rootful docker**，使沙箱容器真正启动，为 Z-02 的"限制生效验证"铺路。
2. **资源是"记账"不是"管控"**：`ds_resource_pool`/`ds_resource_quota` + `assertCapacity`
   仅做准入记账；GPU/storage 只存 `ds_sandbox` 列、不下发到运行时（kusciaapi `JobResource`
   只有 `cpu`/`memory` 两个字段）；`network_policy` 只是 Job 的 `custom_field`，无任何实际执行；
   `runtime_meta` 列（V7）从未写入；GPU 台账是硬编码 4 个 A100。
3. **测试方法变更（管理员指令）**：管理员给出 data-sandbox-package `develop/xzh` 版
   develop.sh，意图是 **`--branch` 参数 + 默认直接构建当前工作树（允许未提交改动，在分支上
   测试，测试通过后再提交推送）+ `--pushed-only` 恢复严格校验**。我们的 zgz 版目前强制
   "提交并推送后才允许 up"，需要按管理员意图调整，同时保留 zgz 特有修复。

Z-02 目标（任务书）：节点 CPU/GPU/内存/存储真实发现与使用率采集；资源预占、分配、绑定、
释放、异常回收；规格下发到真实运行时并验证限制生效；内部网络/无网络/白名单实际隔离；
资源阈值告警、沙箱异常告警与通知。交付物：资源控制器、监控指标、告警规则、隔离验证报告。

## 用户已确认决策

- **GPU**：台账 + 配额 + 使用率采集级别，**不做容器 GPU 直通**（kusciaapi 无 gpu 字段、
  宿主透传依赖 rootful+NVIDIA runtime 改造），验证报告如实注明平台限制。
- **环境**：直接切 rootful docker，重建个人实例并验证沙箱容器能真正启动。
- **测试方法**：按管理员 develop/xzh 脚本调整（`--branch` 参数、默认工作树模式、`--pushed-only`）。

## 阶段划分

| 阶段 | 内容 | 关键产出 |
|---|---|---|
| 0 | 环境迁移 rootful + 验证容器可启动 | rootful 实例、k3s 建 pod 成功、Z-01 限制解除 |
| 1 | 测试方法改造（develop.sh + 文档） | `--branch`/工作树默认/`--pushed-only`，保留 zgz 修复 |
| 2 | 节点资源发现与使用率采集 | `ResourceCollector` + `PrometheusTextParser` + `ds_node_metric` |
| 3 | 资源生命周期（预占/绑定/释放/异常回收） | V8 迁移、`alloc_state`、`ds_resource_allocation`、运行时元数据、限制校验 |
| 4 | 网络隔离（内网/断网/白名单） | AppImage `-nonet` 变体、`ds_network_allowlist`、proxy 强制 |
| 5 | 告警与通知 | `raiseAlert`（去重+webhook）、真实指标阈值、沙箱异常告警 |
| 6 | 前端 | 资源管理页真实指标、分配状态列、白名单编辑器 |
| 7 | 测试 | 解析器单测、采集器/生命周期/网络/告警集成测试 |
| 8 | 端到端验证（先测后提交） | 新方法在 develop/zgz 上跑清单 + 隔离验证报告 |

---

## Stage 0 — 环境迁移 rootful（先做，作为后续所有验证的前置门禁）

文件：`/data/zgz/datasandbox/data-sandbox-package/develop.sh`

1. **权限预检** `check_docker_privilege()`（`up` 分支、`ensure_runtime_directories` 之前）：
   - `docker -H unix:///var/run/docker.sock info` 成功 → 已可用
   - 或 `id -nG` 含 docker 组（新登录才生效）
   - 或 `sudo -n true` 成功（passwordless sudo）
   - 否则报明确错误并提示管理员操作，退出（**安全**：不自动 sudo、不改系统配置）。
2. **迁移序列**：
   - 停 rootless 实例：`DOCKER_HOST=unix:///run/user/996/docker.sock ./develop.sh down`
     （按 label `io.hustnlp.data-sandbox.dev-owner=zgz` 清理，保留 `.dev-runtime/zgz` 数据）
   - rootful 需要自己的镜像：kuscia 镜像 `docker pull`（离线则 `docker save|load` 跨 daemon）；
     `data-sandbox-secretpad:dev-zgz` 反正要随新代码重建（见下）。
   - 用 rootful 跑 `./develop.sh up`（沿用端口环境变量：后端 8099、Kuscia 24080-24084）。
   - **V8 迁移同步**：宿主 config 目录覆盖镜像 schema，V8 不会自动生效——在
     `initialize_secretpad_data()` 加幂等 `cp -n` 把镜像内 `config/schema/p2p/V8*.sql`
     复制到宿主 config 目录（`cp -n` 保证后续迁移也能自动出现、不覆盖 V1-V7）。
3. **验证门禁（不通过不进入后续阶段）**：
   ```bash
   docker exec data-sandbox-dev-zgz-kuscia kubectl get nodes   # 单节点 Ready
   # 真实 E2E：创建沙箱 → 启动 → ≤60s RUNNING，kubectl get pods -A 有真实 Running pod
   ```
4. **回滚**：rootless daemon 与 `.dev-runtime/zgz` 原样保留；同一时刻只用一个 daemon 操作。
   安全约束：仅操作 `io.hustnlp.data-sandbox.*` label 标记的容器；不触碰 xzh 环境与共享 Alice/Bob。

## Stage 1 — 测试方法改造（管理员意图）

文件：`/data/zgz/datasandbox/data-sandbox-package/develop.sh` + 文档

- 保留 `--branch BRANCH`（默认 `develop/${DEV_NAME}`）；新增 `--pushed-only` → `REQUIRE_PUSHED=true`。
- 把 `build_developer_image` 里的两次 `verify_pushed_checkout` 换成 `verify_branch`：
  - 默认：当前分支 == `$EXPECTED_BRANCH` 即可（**允许 dirty 工作树**，直接在分支上测试）；
  - `--pushed-only` 时：走原 `verify_pushed_checkout`（clean + upstream 同步）。
- `build_developer_image` 中构建后的 `git status` 校验仅在 `--pushed-only` 下启用
  （工作树模式构建会产生 `static/`、`index.html` 等未跟踪产物，属预期）。
- **保留 zgz 特有修复不动**：`KUSCIA_HOST_IP` 网桥网关注入、`data-sandbox-dev-${USER}` 命名、
  端口 8099/9099/24080-24084、`reject_foreign_paths`（xzh 路径黑名单）、`down` label 清理。
- `ensure_credentials` 追加新环境变量（Stage 2 用）：`DATA_SANDBOX_METRICS_URL=http://%s:9091`、
  `DATA_SANDBOX_METRICS_ENABLED=true`；`up` 时若 secretpad.env 缺这些行则幂等追加。
- **文档与 CLAUDE.md 同步**（Stage 1 完成时一并提交，随后续阶段变更再增量更新）：
  - `/data/zgz/datasandbox/claude/CLAUDE.md`：
    - "构建与部署边界"节：去掉"运行 develop.sh up 前必须提交并推送前后端代码…与远程
      upstream 完全一致后才允许构建"，改为**双模式**：默认直接构建当前工作树在分支上测试，
      测试通过后再提交推送；`--pushed-only` 保留严格校验用于发布验证。
    - Z-02 任务清单小节：注明**用户决策**——GPU 为台账+配额+使用率采集（不容器直通）、
      环境已迁移 rootful docker、新增指标采集环境变量（`DATA_SANDBOX_METRICS_*`）。
    - 端口约定：保持不变（后端 8099 / 前端 9099 / Kuscia 24080-24084），注明未变。
  - `/data/zgz/datasandbox/数据沙箱系统开发文档.md` §4.3：同样改为双模式表述。
  - `data-sandbox-package/README.md`：记录 `--branch`、工作树默认、`--pushed-only`。

## Stage 2 — 节点资源发现与使用率采集

- 新增 `secretpad-web/src/main/java/org/secretflow/secretpad/web/service/sandbox/ResourceCollector.java`
  + `PrometheusTextParser.java`（纯静态、可单测）。
- 配置（`secretpad-web/config/application.yaml` 的 `secretpad.data-sandbox` 段）：
  ```yaml
  metrics:
    enabled: ${DATA_SANDBOX_METRICS_ENABLED:false}
    url: ${DATA_SANDBOX_METRICS_URL:}
    interval-ms: ${DATA_SANDBOX_METRICS_INTERVAL:30000}
  ```
- `ResourceCollector`（@Scheduled，enabled 门控）：GET `{kuscia}:9091/metrics`（8s 超时）→
  `PrometheusTextParser` 解析 → 计算：
  - CPU 核数 = `count(node_cpu_seconds_total)`；使用率 = 1 − Δidle/Δtotal（内存保留 1 周期差量缓存）；
  - 内存 = `node_memory_{MemTotal,MemAvailable}_bytes`；
  - 存储 = `node_filesystem_{size,avail}_bytes`（过滤 k3s/数据挂载点）；
  - GPU = 若 `DCGM_FI_DEV_GPU_UTIL` 存在则解析，否则 `-1`（前端显示 N/A，如实记录限制）。
- 写入 `ds_node_metric`；失败不插入（保留最近一次有效行）、`metrics.status=STALE`，绝不 crash。
- `resourceOverview()` 替换硬编码 GPU 台账：`gpuInventory` 读 `ds_gpu_ledger` +
  最新 `ds_node_metric.gpu_utilization_percent`；新增 `nodeMetrics`（最新采集行）与
  `metrics.status`。

## Stage 3 — 资源生命周期（预占/绑定/释放/异常回收）

**V8 迁移**（`config/schema/{center,edge,p2p}/V8__data_sandbox_resource.sql`，SQLite 语法）：
- `alter table ds_sandbox add column alloc_state varchar(16) not null default '';`
  （''/RESERVED/BOUND/RELEASED）
- `alter table ds_resource_pool add column critical_threshold real not null default 90;`
- 新表：`ds_resource_allocation`（id, sandbox_id, resource_type, amount, state, owner_id,
  sandbox_status, bound_at, released_at, released_by[MANUAL|EXPIRE|RECLAIM|DESTROY], created_at；
  索引 sandbox_id / (owner_id,state)）；`ds_node_metric`（各资源总量/使用率 + gpu_utilization +
  source + raw_json + created_at）；`ds_gpu_ledger`（4 个 A100 种子，status
  AVAILABLE|ALLOCATED|OFFLINE + owner_id + allocated_at）；`ds_network_allowlist`。
- 存量沙箱回填：未销毁沙箱按 `ds_sandbox` 生成 RESERVED 分配行（`insert or ignore`）。
- 同步到 data-sandbox-package：`build.sh`/`Dockerfile` 加 V8 COPY、package 的 `config/schema/*`。

**钩子**（`DataSandboxMvpService.java` 私有方法 `reserve/bind/releaseAllocations`）：
- `createSandbox`（~131）：插入后 `reserveAllocations`（4 行 RESERVED）、`alloc_state='RESERVED'`、
  `runtime_meta` 写入 `{spec:{cpu,memory_gb,gpu,storage_gb},alloc_state:"RESERVED"}`。
- `sandboxAction` START（~158）：startKuscia 前补 `reserveAllocations`（处理 STOPPED 重启时
  已 RELEASED 的场景）。
- `startKuscia`（~854）：cpu/mem 规范化后仍走 `JobResource{cpu,memory}`（proto 仅此二字段）；
  createJob 成功后 `runtime_meta` 追加 `{job_id, app_image, resources:{cpu,memory}}`。
- `syncKusciaStatuses`（~748）：target==RUNNING（~778）→ `bindAllocations`（BOUND + bound_at +
  GPU ledger 绑定 + runtime_meta 追加 endpoint）；target==STOPPED → `releaseAllocations("MANUAL")`。
- STOP 无 job 分支（~192）、DESTROY 成功（~204）、expire 置 EXPIRED 后（~823）→ 相应 release。
- 新增 `@Scheduled` `reclaimAbnormalAllocations()`（每分钟）：DESTROYED/deleted 强制释放；
  ERROR/STARTING 卡在 RESERVED/BOUND 且超 10min → RECLAIM 释放 + 异常告警 + 审计；
  `alloc_state='BOUND'` 但本地状态不在运行态超宽限期 → RECLAIM。
- `usage()`（~944）改为生命周期感知：`sum(amount) from ds_resource_allocation where state in
  ('RESERVED','BOUND') [and owner_id=?]` group by resource_type；`assertCapacity` 逻辑不变即生效。
- `runtime_meta` 用现有 `truncate(...,2048)` 兜底。

**限制生效验证**：新增 `scripts/deploy/data-sandbox/verify-limits.sh <kuscia容器> <sandboxId>`
——`kubectl get pods -A -o json | jq '.items[].spec.containers[].resources'` +
pod 内 `/sys/fs/cgroup/.../{cpu.max,memory.max}`，与 `ds_sandbox.cpu_cores/memory_gb` 交叉核对；
可选 `POST /operations/limit-verify {sandboxId}` 返回期望值 + 操作指引（secretpad 无 kubectl，
给出说明而非伪造）。

## Stage 4 — 网络隔离（内网/断网/白名单）

- **AppImage 变体**：新增 `scripts/templates/data-sandbox-{jupyter,secretflow,jar}-nonet.yaml`
  ——**无 `scope: Cluster` 端口**（仅 Domain/省略）、去掉 HTTP 探针；`register-data-sandbox-appimages.sh`
  补注册 3 个 `-nonet` 变体。
- `startKuscia` 选变体：`network_policy == NO_NETWORK` → `appImage + "-nonet"`。
- **proxy 层强制**（`SandboxProxyController` + `DataSandboxMvpService`）：`generateDevToken`/
  `proxyTarget`/`validateDevToken` 对 NO_NETWORK 一律拒绝（"NO_NETWORK 沙箱不提供开发端点"）；
  nonet job 无 Cluster endpoint → `endpoint` 自然为空（纵深防御）。
- **白名单**：新 CRUD —— `GET /resources/network/allowlist?sandboxId=`、
  `POST /resources/network/allowlist`（{sandboxId, host, port, proto?, remark?}）、
  `POST /resources/network/allowlist/delete`（{id}）。
- **如实记录**（写入隔离验证报告）：单节点 dev 环境不支持 egress CNI NetworkPolicy/iptables；
  本环境真实可验证的隔离 = ① NO_NETWORK 无 Cluster 端口 + proxy 阻断；② ALLOW_LIST 白名单
  登记 + 管理；egress 过滤留待集群环境。

## Stage 5 — 告警与通知

`DataSandboxMvpService` 新增 `raiseAlert(severity, source, title, detail, dedupeKey)`：
- 仅当无同 `source`+`dedupeKey` 的 OPEN 告警时插入 `ds_alert_event`（沿用现有去重模式 ~836）；
- 随后 `dispatchWebhooks("alert.created", {...})`（沿用现有 HMAC webhook 通路）。

规则：
1. 真实指标阈值（采集后 30s 内的 `checkNodeMetricsAlerts()`）：最新 `ds_node_metric`
   cpu/mem/storage 使用率 vs `ds_resource_pool.warning_threshold`（WARNING）与新增
   `critical_threshold`（CRITICAL），source=`NODE_METRIC`。
2. 配额使用率 ≥90%（配置 `secretpad.data-sandbox.alerts.quota-warning-percent:90`）→
   WARNING，source=`RESOURCE`。
3. 沙箱异常：进入 ERROR（sync 决策失败、start/stop 失败、expire 失败分支）→ WARNING，
   source=`SANDBOX`，dedupeKey=`sandbox:{id}:error`；资源绑定超时（STARTING+intent=START
   长期不 RUNNING）→ `资源绑定超时`；异常回收 → `资源异常回收`。

## Stage 6 — 前端

- `apps/platform/src/services/data-sandbox.ts`：新增 `networkAllowlist(sandboxId)` /
  `addNetworkAllowlist(data)` / `deleteNetworkAllowlist(id)` / `limitVerify(sandboxId)`。
- `apps/platform/src/modules/resource-manager/index.tsx`：
  - 资源池卡片加真实 `node_usage_percent`；新增"节点真实使用率"卡片行（CPU/内存/存储）与
    `metrics.status` 状态 Tag（正常/数据过期/N/A）；
  - GPU 台账表：status 读真实 ledger，加"利用率"列（-1 → N/A）；
  - 告警表加 source 过滤 + OPEN 计数角标。
- `apps/platform/src/modules/sandbox-manager/index.tsx`：
  - 新增"分配状态"列（alloc_state：RESERVED=蓝 / BOUND=绿 / RELEASED=默认 / '' = '-'）；
  - ALLOW_LIST 行加"白名单"按钮（Modal：表格 + host/port/proto/remark 表单，走新 API）；
  - NO_NETWORK 行隐藏"打开开发环境"按钮（后端同时拒绝）。

## Stage 7 — 测试（沿用既有模式）

- `service/sandbox/PrometheusTextParserTest`（纯单测：node_exporter 风格文本、NaN、重复序列）。
- `service/sandbox/ResourceCollectorTest`（@SpringBootTest + 本地 HttpServer 服务 /metrics，
  断言插入；端点宕 → 不插入 + STALE）。
- `service/DataSandboxResourceIT`（沿用 DataSandboxKusciaIT：MockKusciaGrpcServer :50051 +
  /tmp SQLite）：create→RESERVED+4 行；RUNNING→BOUND+GPU ledger 绑定+runtime_meta；
  STOP→RELEASED+ledger 恢复；expire→RELEASED(EXPIRE)；异常回收；usage/assertCapacity
  生命周期感知（停一个释放配额）；runtime_meta 截断。
- `service/DataSandboxNetworkIT`：白名单 CRUD；NO_NETWORK 拒 dev-token/proxy；ALLOW_LIST 正常。
- `service/DataSandboxAlertsTest`：raiseAlert 去重；alert.created webhook HMAC 送达；CRITICAL
  vs WARNING；真实指标阈值插入。
- 扩展 `controller/DataSandboxControllerTest`（新端点 + overview 新字段）；
  扩展 mock `JobService.State` 捕获 `lastCreateJobRequest`，断言 NO_NETWORK 用 `-nonet` 变体、
  cpu/memory 规范化。

## Stage 8 — 端到端验证（先测后提交）

新方法：`./develop.sh up --branch develop/zgz`（工作树模式，dirty 允许）→ 跑清单 →
`./develop.sh down` → 提交推送 secretpad + secretpad-frontend + data-sandbox-package → 更新文档。

清单（对应交付物）：
1. rootful 下 `kubectl get nodes` 单节点 Ready；创建+启动沙箱 ≤60s RUNNING、有真实 pod。
2. 限制生效：`verify-limits.sh` + `kubectl get pods -o json` + pod 内 `cpu.max`/`memory.max`
   与 `ds_sandbox` 规格一致，`docker stats` 吻合。
3. 指标：`/resources/overview` 的 nodeMetrics 来自 :9091（与 kuscia 容器内 free/nproc 交叉核对）；
   短暂停 kuscia → `metrics.status=STALE`、无崩溃。
4. 网络：NO_NETWORK 沙箱 RUNNING 但无端点、dev-token 被拒；ALLOW_LIST 白名单 CRUD 生效；
   INTERNAL_ONLY 行为不变。
5. GPU：GPU=1 沙箱 RUNNING → ledger ALLOCATED；STOP → AVAILABLE；overview 台账真实；
   利用率 N/A（限制如实记录）。
6. 告警：临时把某池 `warning_threshold=1` → 生成告警 + webhook 送达；resolve 生效；
   ERROR 迁移生成 SANDBOX 告警。
7. 异常回收：强制 ERROR+RESERVED → 超宽限 RECLAIM + 审计 + 告警。
8. 生命周期记账：STOP 后 overview 已用配额下降（RELEASED 不计数）；重启再 RESERVED。
9. `./develop.sh status/logs/down` label 清理正常、`.dev-runtime/zgz` 保留。

**隔离验证报告**（放 `/data/zgz/datasandbox/docs/` 或仓库 doc）：已验证——cpu/mem 真实限制
（pod spec + cgroup）、NO_NETWORK 隔离（无 Cluster 端口 + proxy 阻断）、ALLOW_LIST 登记管理、
9091 指标解析；限制——GPU 利用率 N/A（台账+配额，无直通）、storage 仅记账（kusciaapi 无
存储字段）、egress CNI 单节点不可用、kusciaapi 无 resource/schedule 服务。

## OpenAPI 契约新增

- `GET /resources/overview`：data 增加 `nodeMetrics{...}`、`metrics{status,lastUpdatedAt}`、
  `gpuInventory[].{id,model,status,utilization,owner_id}`。
- `GET/POST /resources/network/allowlist`、`POST /resources/network/allowlist/delete`。
- `POST /operations/limit-verify`：`{expected:{cpu,memory_gb}, instructions}`。

## 风险与依赖

| 风险 | 等级 | 缓解 |
|---|---|---|
| rootful 迁移被阻（无 docker 组/sudo） | 高 | `check_docker_privilege` 预检 + 明确管理员步骤；回退 rootless（DOCKER_HOST） |
| rootful 下 k3s 仍无法建 pod | 高 | Stage 0 验证门禁，通过才继续；cpu 控制器已下放，问题应在 rootful 下消除 |
| 指标格式漂移/NaN/空序列 | 中 | 容忍解析器 + 保留最近有效行 + STALE 状态，无崩溃路径 |
| secretpad 无法访问 kuscia:9091 | 中 | 优雅降级；URL 可配置 |
| V8 在存量实例不生效（config 目录遮蔽镜像） | 中 | `initialize_secretpad_data` 幂等 `cp -n` + 存量回填 SQL |
| 白名单 egress 单节点无法真正强制 | 中 | 如实记录；NO_NETWORK 用 AppImage+proxy 真实强制 |
| kusciaapi 限制（无 resource/schedule、GPU/storage 不可下发） | 中 | 准入/记账层强制 + 文档化；仅 cpu/mem 走 JobResource |
| 分配生命周期并发（sync vs action） | 中 | @Transactional + 幂等状态转移 + 回收 reaper |
| build.sh 只拷 V6/V7 | 中 | build.sh/Dockerfile 补 V8 |

## 收尾

1. **执行第一步**：将本最终版计划原样复制到 `/data/zgz/datasandbox/claude/plans/Z-02-plan.md`。
2. 各阶段完成后分别提交（secretpad / secretpad-frontend / data-sandbox-package），每提交带测试，
   推送 develop/zgz；提交信息注明模块/迁移/配置变更。
3. **端到端测试完成并全部通过后，撰写 `/data/zgz/datasandbox/claude/plans/Z-02-task-report.md`，
   形式完全参照 `Z-01-task-report.md` 的六节结构**：
   - 一、功能完成情况（按 Z-02 5 项需求逐一列完成情况与交付物）
   - 二、测试情况（后端单测/集成、前端构建、新方法端到端清单逐项结果）
   - 三、修复情况（任务内发现并修复的问题，含环境迁移中遇到的问题，逐条列根因+修复+提交）
   - 四、已知环境限制（GPU 利用率 N/A、storage 仅记账、egress CNI 单节点不可用、
     kusciaapi 无 resource/schedule 服务等，如实列出）
   - 五、浏览器使用指南（用户如何访问并使用资源管理页、分配状态、白名单、告警）
   - 六、提交记录（develop/zgz 各仓库提交清单）
   - 附：隔离验证报告（Stage 8 大纲）作为附录。
4. Z-01 的两个 PR（secretpad #2、secretpad-frontend #2）保持 open 状态，不影响本任务；
   合并决策由用户在 master 上另行决定。
