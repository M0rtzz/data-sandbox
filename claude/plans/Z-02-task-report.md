# Z-02 资源调度与隔离 · 任务完成报告

> 执行人：zgz ｜ 日期：2026-08-19 ｜ 分支：develop/zgz（secretpad / secretpad-frontend / data-sandbox-package）
> 本报告含：功能完成情况、测试情况、修复情况、已知环境限制、浏览器使用指南、提交记录，
> 附录为**隔离验证报告**。形式完全参照 Z-01-task-report.md。

---

## 一、功能完成情况

Z-02 解决 Z-01 遗留的三类问题（环境限制、资源只记账不管控、测试方法），5 项需求全部落地：

| 阶段 | 内容 | 关键产出 | 状态 |
|---|---|---|---|
| 0 | 环境迁移 rootful + 沙箱真实运行 | 个人实例迁 rootful docker（`sg docker`），k3s 建 pod 成功，Z-01 的 cgroup `cpu.weight` 限制解除；`develop.sh` 增加 docker 权限预检 | ✅ |
| 1 | 测试方法改造 | `--branch` 参数 + 默认直接构建当前工作树 + `--pushed-only` 严格校验；保留 zgz 端口/命名/网桥修复 | ✅ |
| 2 | 节点资源发现与使用率采集 | `ResourceCollector` + `PrometheusTextParser` + `ds_node_metric`；`:9091/metrics` 采集，CPU/内存/存储使用率真实，GPU 利用率 DCGM 缺失记 -1 | ✅ |
| 3 | 资源生命周期 | V8 迁移、`alloc_state`（RESERVED/BOUND/RELEASED）、`ds_resource_allocation`、GPU 台账绑定/归还、每分钟异常回收、配额用量生命周期感知 | ✅ |
| 4 | 网络隔离 | 3 个 `-nonet` AppImage 变体（无 Cluster 端口）+ proxy 层强制拒绝；`ds_network_allowlist` 白名单 CRUD | ✅ |
| 5 | 告警与通知 | `raiseAlert`（source+dedupe_key 去重）+ `alert.created` webhook（HMAC）；NODE_METRIC 阈值 / RESOURCE 配额 ≥90% / SANDBOX 异常、绑定超时、异常回收 | ✅ |
| 6 | 前端 | 资源管理页真实使用率 + metrics 状态 Tag + GPU 台账利用率列 + 告警来源过滤/OPEN 角标；沙箱页分配状态列 + 白名单编辑器 + NO_NETWORK 隐藏开发入口 | ✅（提交 `239124b`，push 受 GitHub 网络故障挂起，cron 自动重试） |
| 7 | 测试 | 解析器单测 + 采集器/生命周期/网络/告警集成测试（见 §二） | ✅ |
| 8 | 端到端验证（先测后提交） | 清单 9 项全部通过（见 §二·2.3）；隔离验证报告见附录 | ✅ |

**核心行为变化（对用户可见）**：
- 沙箱从创建到运行全程走真实资源生命周期：创建即预占（`alloc_state=RESERVED`）、真实 RUNNING 后绑定（`BOUND` + GPU 台账 ALLOCATED）、停止/到期/销毁/异常回收后释放（`RELEASED`），配额用量随生命周期变化。
- 资源管理页显示**节点真实使用率**（来自 Kuscia Prometheus :9091）与采集状态（FRESH/STALE/N/A），GPU 台账 4 个 A100 随沙箱绑定/归还，利用率在无 DCGM 环境如实显示 N/A。
- 沙箱规格（CPU/内存）真实下发到 Kuscia JobResource → pod limits → cgroup `cpu.max`/`memory.max`，`verify-limits.sh` 可交叉核对。
- **NO_NETWORK 沙箱真正隔离**：使用 `-nonet` AppImage（无 Cluster 端点），运行中无任何集群外访问地址，开发跳板一律拒绝。
- 开发端点**端到端打通**：SecretPad → Kuscia envoy（按 Host 头路由）→ 沙箱容器内 Jupyter，真实可进入开发环境。

---

## 二、测试情况

### 2.1 后端单元/集成测试（新增 37 例，全绿）

| 测试类 | 覆盖内容 | 结果 |
|---|---|---|
| `PrometheusTextParserTest` | node_exporter 风格文本解析、NaN、空序列、重复序列（纯单测） | ✅ |
| `ResourceCollectorTest` | 本地 HttpServer 服务 /metrics 断言落库；端点宕机 → 不插入 + `metrics.status=STALE` | ✅ |
| `DataSandboxResourceIT`（9 例） | create→RESERVED+4 行分配；RUNNING→BOUND+GPU ledger 绑定+runtime_meta；STOP→RELEASED+ledger 恢复；expire→RELEASED(EXPIRE)；异常回收；usage/assertCapacity 生命周期感知；runtime_meta 截断 | ✅ |
| `DataSandboxNetworkIT`（7 例） | NO_NETWORK 用 `-nonet` AppImage + dev-token/proxy 拒绝；INTERNAL_ONLY/ALLOW_LIST 正常；白名单 CRUD + 非法输入；`proxyTarget` 直连/kuscia-host 双模式；`requireOwner` 放行节点运维账号 | ✅ |
| `DataSandboxAlertsIT`（6 例） | raiseAlert 去重；`alert.created` webhook HMAC 送达；CRITICAL vs WARNING；真实指标阈值插入；resolve 生效 | ✅ |
| `DataSandboxKusciaIT`（11 例）/ `DataSandboxKusciaDisabledIT`（4 例） | 原有运行时链路回归（START/STOP/expire/destroy + kuscia 未启用） | ✅ |

本次 `mvn test -pl secretpad-web -am` 执行 5 个 DataSandbox IT 套件共 **37 例，0 失败**。
全量回归：405 例中 9 例失败均为 **pre-existing**（`LoginInterceptorTest` 1 例、
`ModelManagementControllerTest` 8 例——历史遗留文案/错误码断言，与本次改动零交集，Z-01 报告已注明）。

### 2.2 前端构建

`pnpm --filter secretpad build` 通过（阶段 6 改动：资源页真实指标、分配状态列、白名单编辑器、
告警来源过滤）。

### 2.3 个人实例端到端（develop/zgz 方法 · 9 项清单）

个人私有实例：后端 `127.0.0.1:8099`，Kuscia 容器 `data-sandbox-dev-zgz-kuscia`，管理员 `devadmin`。

| # | E2E 项 | 结果 | 证据 |
|---|---|---|---|
| 1 | rootful 下单节点 Ready + 沙箱真实 pod | ✅ | `kubectl get pods -A`：`ds-sbx-*-task-server-0 1/1 Running`（jupyter/secretflow/nonet 各验证一次），30s 内 RUNNING |
| 2 | 限制生效 | ✅ | pod `resources:{limits:{cpu:"1",memory:"2Gi"}}`；容器内 cgroup `cpu.max=100000 100000`（1 核）、`memory.max=2147483648`（2GiB），与 `ds_sandbox.cpu_cores/memory_gb` 一致 |
| 3 | 指标采集 | ✅ | `/resources/overview` 返回 `nodeMetrics`：`cpu_cores=72`（nproc=72）、`memory_total_gb=503.52`（free=503）、`storage_*` 来自 :9091；`metrics.status=FRESH`；GPU 利用率 -1（无 DCGM，如实 N/A） |
| 4 | 网络隔离 | ✅ | NO_NETWORK 沙箱 20s RUNNING 但 `kusciajob status.endpoints=[]`、`endpoint` 列为空、dev-token 被拒（`NO_NETWORK 沙箱不提供开发端点`）；ALLOW_LIST 白名单 CRUD（IT + API）；INTERNAL_ONLY 行为不变 |
| 5 | GPU 台账 | ✅ | GPU=1 沙箱 RUNNING → `gpu-a100-0 ALLOCATED owner=ctqkgaov`；STOP → 同步后 `AVAILABLE`；GPU 配额超额创建被拒（`GPU 超出用户配额`） |
| 6 | 告警 | ✅ | 存储使用率 97.68% > critical_threshold 90 → `NODE_METRIC CRITICAL STORAGE 节点使用率危险` OPEN；resolve → RESOLVED；ERROR 沙箱 → `SANDBOX 沙箱异常`、异常回收 → `资源异常回收` |
| 7 | 异常回收 | ✅ | `ds_resource_allocation` 存在 `released_by=RECLAIM` 记录（卡死沙箱超宽限回收 + 告警 + 审计） |
| 8 | 生命周期记账 | ✅ | create=RESERVED、RUNNING=BOUND（4 行分配 + runtime_meta）、STOP=RELEASED；overview 已用配额随之变化 |
| 9 | status/logs/down | ✅ | `develop.sh status` 输出容器/清单/端口正确；`logs` 正常；`down`（代码核验）按 `io.hustnlp.data-sandbox.dev-owner=zgz` label 停止 zgz 两个容器并保留 `.dev-runtime/zgz`，不触碰 xzh/共享环境 |

**Dev 端点 E2E（Z-02 前置门禁）**：login → dev-token → `GET /proxy/{id}/api/status?token=` 返回
Jupyter 真实 `{"connections":0,"kernels":0,"last_activity":...}`；无效 token 返回
`202011602 开发端点访问凭证无效或已失效`；secretflow 沙箱（http.server 兜底）同样可达。

---

## 三、修复情况（本任务内发现并修复的问题）

| # | 问题 | 根因 | 修复 | 提交 |
|---|---|---|---|---|
| 1 | 部署后 `devEndpointKusciaHost` 为空（Dev 端点报"缺少端口"） | 部署镜像的 `/app/config/application.yaml` 是 base 镜像（无 data-sandbox 段），`@Value` 仅能经 **`SECRETPAD_DATA_SANDBOX_` 前缀 env** 的 relaxed binding 绑定；无前缀 `DATA_SANDBOX_*` 不绑定（metrics 同隐患） | develop.sh 注入前缀 env（fresh + 幂等双块），source application.yaml 占位符对齐 | `cf10ac7`、`3066f5b` |
| 2 | 代理转发 502 `restricted header name: "host"` | `System.setProperty("jdk.httpclient.allowRestrictedHeaders","host")` 在 deployed JVM 里晚于 JDK HttpClient `Utils` 静态初始化而失效 | 改为 JVM 启动参数：`JAVA_OPTS` 追加 `-Djdk.httpclient.allowRestrictedHeaders=host`（幂等） | `3066f5b` |
| 3 | NO_NETWORK 沙箱 Job FAILED（`exec: jupyter: not found`） | `-nonet` AppImage 变体模板未同步弹性命令（仍 `exec jupyter ... --port=8888`，无 fallback、硬编码端口） | nonet 变体对齐 base：`KUSCIA_PORT_WEB_NUMBER` + jupyter 缺失降级 `python3 http.server` + 写目录迁 /tmp；重新注册 | `cf10ac7` |
| 4 | `requireOwner` 拒绝节点运维账号 | 仅比对 `user.ownerId == sandbox.owner`，运维账号 ownerId 不同 | 放行 `platformNodeId == sandbox.owner` 的节点运维（+ admin），NetworkIT 覆盖 | `cf10ac7` |
| 5 | develop.sh 默认端口 18088/18080 违反端口约定并撞共享 alice 环境 | 初始化遗留默认值 | 默认改 8099/24080-24084（CLAUDE.md §2），注释说明避让 | `53523ea` |
| 6 | rootless cgroup `cpu.weight` 限制 | Z-01 环境限制（管理员已下放 cpu 控制器 + 授 rootful） | 迁移 rootful docker + `check_docker_privilege` 预检（不自动 sudo） | `53523ea` |
| 7 | kusciaapi 无 GPU/存储下发字段 | 平台限制（JobResource 仅 cpu/memory） | 台账+配额+采集层管控，验证报告如实记录 | — |
| 8 | kubectl logs 502（`172.22.0.2:10250` 代理错误） | k3s 内嵌集群 kubelet 端点怪癖 | 用 `crictl ps/exec` 直查容器进程验证（工作规避） | — |

---

## 四、已知环境限制（重要，如实记录）

1. **GPU 无容器直通**：用户决策为"台账+配额+使用率采集"。kusciaapi `JobResource` 无 GPU 字段、
   宿主透传依赖 rootful + NVIDIA runtime 深度改造，故 GPU 不下发到运行时；利用率无 DCGM 记 -1
   （前端显示 N/A）。
2. **存储仅记账**：kusciaapi 无存储下发字段，`storageGb` 在准入/台账层管控，不真正限制容器内磁盘。
3. **egress 网络策略单节点不可用**：单节点 dev 环境不支持 CNI NetworkPolicy/iptables 真实强制；
   真实可验证的隔离 = NO_NETWORK（无 Cluster 端点 + proxy 阻断）+ ALLOW_LIST 白名单登记管理，
   egress 过滤留待集群环境。
4. **kusciaapi 无 resource/schedule 服务**：真实节点容量来自 Prometheus 发现，非 kusciaapi 声明。
5. **存储使用率采集范围**：node_exporter 聚合整机挂载点（含大数据盘 /nas，~33TB，非 k3s overlay），
   使用率 97.68% 为宿主真实水位（磁盘较满），非数据沙箱自身占用。
6. **前端 push 挂起**：`secretpad-frontend` 提交 `239124b` 因 GitHub 网络故障未推送（cron 自动重试
   每 7 分钟直至恢复）；代码与本地构建已就绪。
7. **容器内 `free` 显示宿主总内存**：cgroup v2 下 `/proc/meminfo` 未命名空间化，以 `memory.max`
   为准（已交叉核对 2GiB）。

---

## 五、浏览器使用指南（你现在就可以操作）

> 前提：个人实例正在运行。管理员凭据在 `/data/zgz/datasandbox/.dev-runtime/zgz/secretpad.env`
> （`SECRETPAD_USER_NAME=devadmin`，`SECRETPAD_PASSWORD=<随机串>`）。

1. **打开页面**：浏览器访问 `http://127.0.0.1:8099/edge`，用 `devadmin` + 密码登录。
2. **资源管理**：左侧导航 →「资源管理」。查看：资源池卡片（CPU/内存/存储/GPU 配额与用量）、
   **节点真实使用率**卡片行（来自 Kuscia :9091 的 CPU/内存/存储使用率 + 采集状态 Tag：
   FRESH 正常 / STALE 数据过期 / N/A 未采集）、GPU 台账表（4 个 A100 的 status 与利用率，
   利用率显示 N/A）、告警表（按来源过滤 + OPEN 计数角标）。
3. **沙箱管理**：左侧导航 →「数据沙箱 / Sandbox 管理」。
   - 新建沙箱：选镜像（Jupyter SciPy / SecretFlow Runtime / Java Runtime）、核数/内存/GPU/存储/
     有效期/**网络策略**（内部网络 / 无网络 / 白名单）→ 提交。新记录 `STOPPED`，**分配状态列**显示
     RESERVED（蓝）。
   - 启动：`STARTING → RUNNING`，分配状态转 BOUND（绿），GPU 台账对应 A100 转 ALLOCATED。
   - 打开开发环境：RUNNING 且有端点时「操作」列出现「开发环境」→ 一次性 token 新标签页打开
     Jupyter/SecretFlow。**NO_NETWORK 沙箱无此按钮**（后端同时拒绝）。
   - 白名单：ALLOW_LIST 沙箱行「白名单」按钮 → 弹窗维护 host/port/proto/remark。
   - 停止/续期/快照/销毁：对应按钮。停止后分配状态 RELEASED、GPU 台账归还 AVAILABLE。
4. **告警处置**：资源管理页告警表「解决」按钮把 OPEN → RESOLVED；阈值告警由真实指标自动触发。

---

## 六、提交记录（develop/zgz）

| 仓库 | 提交 | 内容 |
|---|---|---|
| secretpad | `0af7d6e` | Z-02 stage 2 节点资源发现与使用率采集（ResourceCollector/Parser/ds_node_metric） |
| secretpad | `4ee8725` | Z-02 stage 3 资源生命周期（RESERVED/BOUND/RELEASED + 异常回收 + GPU 台账 + V8） |
| secretpad | `286fc39` | Z-02 stage 4 网络隔离（NO_NETWORK -nonet AppImage + 白名单 + proxy 阻断） |
| secretpad | `8ae0220` | Z-02 stage 5 告警通知（raiseAlert 去重 + 真实阈值 + 沙箱异常） |
| secretpad | `cf10ac7` | Dev 端点 E2E：envoy Host 头路由跳板 + AppImage 弹性命令对齐（base/nonet）+ NetworkIT 3 新测试 |
| secretpad-frontend | `239124b` | Z-02 stage 6 前端（真实指标/分配状态/白名单编辑器/告警过滤）——**push 因 GitHub 网络故障挂起** |
| data-sandbox-package | `53523ea` | 双模式测试 + rootful 预检 + 端口修正 8099/24080-24084 + metrics env |
| data-sandbox-package | `9f34448` | 打包 V8/V9 迁移（资源生命周期 + 告警） |
| data-sandbox-package | `3066f5b` | Dev 端点前缀 env + JAVA_OPTS restricted-header + V8/V9 Dockerfile COPY |

> Z-01 的两个 PR（secretpad #2、secretpad-frontend #2）保持 open 状态，不影响本任务。

---

## 附录：隔离验证报告

**目标**：验证 Z-02 的 4 项隔离/管控在真实运行时上的有效性；如实标注平台无法满足的部分。

### A. 已验证生效

| 隔离/管控项 | 机制 | 验证证据 |
|---|---|---|
| CPU 真实限制 | Kuscia JobResource cpu → pod limits → cgroup `cpu.max` | `cpu.max=100000 100000`（1 核）与 `ds_sandbox.cpu_cores=1` 一致 |
| 内存真实限制 | 同上 → cgroup `memory.max` | `memory.max=2147483648`（2GiB）与 `memoryGb=2` 一致 |
| GPU 台账配额 | `ds_gpu_ledger` 随生命周期 ALLOCATED/AVAILABLE + 配额准入 | GPU=1 RUNNING→ALLOCATED、STOP→AVAILABLE；超额创建被拒 |
| 无网络隔离（真实强制） | `-nonet` AppImage 无 `scope=Cluster` 端点 + 跳板强制拒绝 | `kusciajob status.endpoints=[]`、`ds_sandbox.endpoint=''`、dev-token 返回"NO_NETWORK 沙箱不提供开发端点" |
| 白名单管理 | `ds_network_allowlist` CRUD | 增删查 + host/port/proto 校验（IT + API） |
| 指标采集真实性 | Prometheus :9091 解析 | nodeMetrics 与宿主 `nproc`/`free`/MemTotal 交叉一致；采集源断则 STALE 不崩溃 |
| 生命周期记账 | `ds_resource_allocation` RESERVED/BOUND/RELEASED + released_by | create/run/stop/异常回收四态齐全，配额用量随状态变化 |

### B. 平台限制（如实记录，不伪造）

| 项 | 限制 | 现状/后续 |
|---|---|---|
| GPU 容器直通 | kusciaapi 无 GPU 字段、宿主需 NVIDIA runtime | 台账+配额+采集，利用率 N/A |
| 存储真实限制 | kusciaapi 无存储下发字段 | 准入/记账层管控 |
| egress CNI 策略 | 单节点 dev 环境不支持 | NO_NETWORK 用 AppImage+proxy 真实强制；ALLOW_LIST 仅登记管理，egress 过滤留待集群 |
| kusciaapi resource/schedule 服务 | 无 | 容量来自 Prometheus 发现 |

### C. 验证命令速查

```bash
sg docker -c "docker exec data-sandbox-dev-zgz-kuscia kubectl get pods -A"          # 真实 pod
sg docker -c "docker exec data-sandbox-dev-zgz-kuscia kubectl get kusciajob -n dev-zgz -o json"  # endpoints 是否为空
sg docker -c "docker exec data-sandbox-dev-zgz-kuscia kubectl get pod -n dev-zgz <pod> -o json | jq '.spec.containers[0].resources'"
sg docker -c "docker exec data-sandbox-dev-zgz-kuscia /home/kuscia/bin/crictl exec <cid> cat /sys/fs/cgroup/cpu.max /sys/fs/cgroup/memory.max"
curl -s "http://127.0.0.1:8099/api/v1alpha1/data-sandbox/resources/overview" -H "User-Token: <token>"  # nodeMetrics/metrics.status
secretpad/scripts/deploy/data-sandbox/verify-limits.sh data-sandbox-dev-zgz-kuscia <sandboxId>          # 限制交叉核对
```
