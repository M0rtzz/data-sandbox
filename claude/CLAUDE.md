# 数据沙箱系统开发 —— zgz 项目说明

> 本文件依据项目目录下《数据沙箱系统开发文档.md》编写，是 zgz 个人的开发指南。
> 详细内容（总体进度、完整任务分工、协作规则、阶段标准等）请以开发文档原文为准。

## 1. 项目概述

数据沙箱管理 MVP：基于现有 SecretPad/Kuscia（项目、数据表、隐私计算任务和可视化建模基础），
新增沙箱管理、资源管理、模型审批、统一日志、系统对接和运维服务的前后端入口。
按采购文件 100 分技术评分项加权估算，当前总体完成度约 **41%**，剩余约 **59%**。

### 仓库结构（本地工作目录 /data/zgz/datasandbox）

| 目录 | 仓库 | 说明 |
| --- | --- | --- |
| `secretpad/` | https://github.com/M0rtzz/secretpad.git | 后端，开发分支 `develop/zgz` |
| `secretpad-frontend/` | https://github.com/M0rtzz/secretpad-frontend.git | 前端，开发分支 `develop/zgz` |

> 另外文档中还提到根仓库只记录已验证的 submodule commit；当前本地工作目录未建根仓库，
> 前后端各自独立 clone 并开发。

### 阶段目标（M0~M4）

- **M0 管理 MVP**：六个管理模块及前后端入口 —— 基本完成
- **M1 真实沙箱**：运行时、资源隔离、网络策略和状态同步 —— 待开发
- **M2 数据治理与开发**：抽样、脱敏、JAR、SQL、Python 和使用控制 —— 待开发
- **M3 审批与系统对接**：资源审批、模型测试、租户计费和可信平台 —— 待开发
- **M4 产品化验收**：信创、文档、测评、性能、案例和交付 —— 待准备

## 2. 开发人员、分支与端口约定

- 本分支开发人员：**zgz**，使用分支 **`develop/zgz`**（前端与后端一致）。
- 协作开发人员 xzh 使用 `develop/xzh` 分支；两人使用各自的系统用户、工作目录和 Git 工作副本，
  禁止直接修改同一个工作目录。
- **每次开始开发前先 `git pull` 拉取远程最新代码；推送前再次拉取并处理冲突**，确保本地提交
  基于最新远程版本。
- **禁止对共享分支强制推送**；冲突必须在个人工作目录中解决、测试并形成新提交，
  不得通过覆盖他人文件解决冲突。
- 本地分支已跟踪 `origin/develop/zgz`；完成后通过合并请求或明确 commit 合并，不直接向 master
  强制推送。

### 端口约定（zgz 私有实例）

多人共用同一台开发机，端口必须互不占用。已确认的端口占用情况：

| 端口 | 归属 | 说明 |
| --- | --- | --- |
| **8088** | xzh | 后端 secretpad webserver（部署脚本 `-s` 参数默认值，见 `secretpad/scripts/deploy/secretpad.sh`） |
| **9088** | xzh | 前端 |
| 8080 | 系统默认 | 后端默认 http-port（`secretpad/config/application.yaml`） |
| 8083 | 系统默认 | Kuscia API 端口（`KUSCIA_API_PORT` 默认值） |
| 443 / 9001 | 系统默认 | 默认 https 端口 / inner 端口 |

**zgz 个人前后端端口约定：**

- **后端（secretpad）：8099**
- **前端（secretpad-frontend）：9099**

> Z-02 变更记录（2026-08-18）：个人实例迁移 rootful docker 后**端口约定不变**——后端 8099、
> 前端 9099、Kuscia 24080-24084，见 `data-sandbox-package/develop.sh` 默认值。

使用原则：
- **禁止使用 8088、9088**（xzh 已占用），也不得占用上表其他系统默认端口。
- 以上端口仅用于 zgz 私有的 `data-sandbox-package/develop.sh` 个人测试实例；
  共享 Alice/Bob 演示环境的端口由 xzh 统一管理，zgz 不操作。
- 后续如新增服务端口（Kuscia、数据库等），同样遵循"避开同事与系统默认端口"原则分配。

## 3. zgz 任务清单（Z-01 ~ Z-09）

### Z-01 真实沙箱运行时
- 制作并注册 Jupyter/Python、JAR 和 SecretFlow Kuscia AppImage。
- 打通沙箱创建、启动、停止、销毁、续期和状态同步。
- 为每个沙箱生成可访问的开发端点并完成鉴权。
- 将沙箱状态与 Kuscia Job/Task、容器和存储真实状态保持一致。
- 失败时返回明确错误，**禁止将未创建容器的记录标记为运行中**。

交付物：AppImage、运行时控制接口、状态同步任务和真实沙箱演示环境。

### Z-02 资源调度与隔离
- 接入节点 CPU、GPU、内存、存储的真实发现和使用率采集。
- 实现资源预占、分配、绑定、释放和异常回收。
- 将 CPU、内存、GPU 和存储规格下发到真实运行时并验证限制生效。
- 实现内部网络、无网络和白名单策略的实际网络隔离。
- 建立资源阈值告警、沙箱异常告警和通知机制。

交付物：资源控制器、监控指标、告警规则和隔离验证报告。

> **Z-02 用户决策与变更记录（2026-08-18）**：
> - **GPU 范围**：台账 + 配额 + 使用率采集，**不做容器 GPU 直通**（kusciaapi `JobResource`
>   无 GPU 字段、宿主透传依赖 rootful + NVIDIA runtime 改造），验证报告如实注明平台限制。
> - **环境**：个人实例**直接迁移到 rootful docker**（管理员已授权），沙箱容器可真实启动；
>   Z-01 的 rootless cgroup `cpu.weight` 限制在 rootful 下解除。
> - **指标采集环境变量**：新增 `DATA_SANDBOX_METRICS_ENABLED` / `DATA_SANDBOX_METRICS_URL`
>   （`http://<kuscia>:9091`）/ `DATA_SANDBOX_METRICS_INTERVAL`，见
>   `secretpad-web/config/application.yaml` 的 `secretpad.data-sandbox.metrics` 段。
> - **测试方法**：按管理员 develop/xzh 脚本意图改为双模式（默认工作树直接测试，
>   `--pushed-only` 严格校验），见 §4 构建与部署边界。
> - **实现进展（截至 2026-08-19：全部完成，Stage 8 E2E 9 项清单通过，报告见
>   `claude/plans/Z-02-task-report.md`）**：
>   - **V8/V9 迁移**：`ds_sandbox.alloc_state`（''/RESERVED/BOUND/RELEASED）、`ds_resource_allocation`、
>     `ds_node_metric`、`ds_gpu_ledger`、`ds_network_allowlist`、`ds_alert_event.dedupe_key`；存量回填 RESERVED。
>   - **资源生命周期**：预占→绑定→释放（released_by=MANUAL/EXPIRE/RECLAIM/DESTROY）+ 每分钟异常回收；
>     配额用量生命周期感知（RESERVED+BOUND 计数）；GPU 台账随 START/STOP 绑定/归还。
>   - **真实指标**：`ResourceCollector` 采集 `:9091/metrics` 写 `ds_node_metric`；`/resources/overview`
>     新增 `nodeMetrics` 与 `metrics.status`（FRESH/STALE/N/A）；GPU 利用率 DCGM 缺失则为 -1。
>   - **网络隔离**：`-nonet` AppImage 变体（无 Cluster 端口/无探针）；NO_NETWORK 拒绝 dev-token/proxy；
>     ALLOW_LIST 白名单 CRUD（`/resources/network/allowlist`）。
>   - **告警**：`raiseAlert` 按 (source, dedupe_key) 去重 + `alert.created` webhook HMAC；NODE_METRIC
>     阈值、RESOURCE 配额 ≥90%、SANDBOX 异常/绑定超时/异常回收。
>   - **前端**：资源管理页真实使用率 + metrics 状态 Tag + GPU 台账利用率列 + 告警来源过滤/OPEN 角标；
>     沙箱页分配状态列 + 白名单编辑器；NO_NETWORK 隐藏开发端点入口。
>   - **限制验证**：`scripts/deploy/data-sandbox/verify-limits.sh` + `POST /operations/limit-verify`。
>   - **E2E 已验证**：CPU/内存限制真实下发（pod limits + cgroup cpu.max/memory.max）；Dev 端点经
>     envoy Host 头路由直达沙箱 Jupyter；NO_NETWORK 无 Cluster 端点 + 跳板拒绝；GPU 台账随
>     生命周期 ALLOCATED/AVAILABLE；NODE_METRIC 阈值告警真实触发 + resolve 生效；异常回收 RECLAIM
>     记录 + 审计 + 告警。前端提交 `239124b` push 因 GitHub 网络故障挂起（cron 自动重试）。
>   - **新增修复**：Dev 端点仅 `SECRETPAD_DATA_SANDBOX_` 前缀 env 可绑定（deployed config 为 base 镜像）；
>     `JAVA_OPTS` 注入 `-Djdk.httpclient.allowRestrictedHeaders=host`（JDK HttpClient Utils 静态初始化早于
>     System.setProperty）；`-nonet` AppImage 对齐弹性命令（jupyter 缺失降级 http.server + 端口变量）。

### Z-03 沙箱资源申请与审批流程
- 建立创建、延期、规格变更和回收申请单模型。
- 实现开发方提交、供数方/运营方审核、驳回、复审和审批记录。
- 审批通过后自动完成资源分配和沙箱拉起，失败时支持补偿和重试。
- 增加审批权限、并发审批和幂等控制。

交付物：资源申请 API、审批状态机、数据库迁移和流程测试。

> **已完成（2026-08-19，报告 `claude/plans/Z-03-task-report.md`）**。三仓库已推送 develop/zgz。
> - **V10 迁移**：`ds_sandbox_approval`（8 态 + payload_json 快照）+ `ds_sandbox_approval_history`（center/edge/p2p 三套）。
> - **状态机**：`SandboxApprovalStateMachine` 纯类；DATA_PROVIDER_REVIEW→OPERATOR_REVIEW→APPROVED→EXECUTING→COMPLETED；
>   REJECTED(RESUBMIT version+1)、FAILED(RETRY)、CANCELLED。
> - **门禁**：`approval.required` 默认 **true**（env `SECRETPAD_DATA_SANDBOX_APPROVAL_REQUIRED`）；**直通仅限 admin 或
>   ownerId/platformNodeId=kuscia-system**（platformNodeId 单实例恒等，不能用于判定运营方——cefef1f 修复直通恒真 bug）。
>   门禁在 Controller 层（create 与 RENEW/DESTROY），START/STOP/快照不拦；Service 直调不受影响。
> - **执行引擎**：`@Scheduled` 10s 认领 APPROVED→EXECUTING（条件 UPDATE affected==1 并发安全），失败回退 APPROVED 自动重试
>   （maxRetries=3，env `SECRETPAD_DATA_SANDBOX_APPROVAL_MAX_RETRIES`）→ FAILED+告警(dedupe `approval:<id>:failed`)；
>   RETRY 同步 executeOne；reclaimStuckExecuting 10min 兜底；执行期复查容量+镜像 enable。
> - **权限/幂等**：角色校验（供数方=非申请方/非运营方/不同 ownerId；运营方=admin/kuscia-system；复审/撤回=申请人）；
>   提交幂等（同 owner 同类型 OPEN 拒绝）。
> - **端点**：`GET /approvals?status&type&keyword`、`POST /approvals/submit`、`POST /approvals/action`、
>   `GET /approvals/history?id=`、`GET /approvals/config`（返回 `{required,types,maxRetries}`）。
> - **前端**：`sandbox-approval` 审批页（提交 Modal 四类型条件字段/审批 Modal/Timeline 记录/重试/复审/撤回）+ edge 菜单；
>   sandbox-manager 门禁适配（创建按钮改「申请沙箱」/续期回收提示）。
> - **测试**：Z-03 新增 34 例全绿（StateMachine 16 + IT 9 + Controller 9）；全量回归 404 例，9 失败均 pre-existing
>   （LoginInterceptor 1 + ModelManagement 8，基线可复现）；RepositoryTest 2 例为共享 sqlite 残留（清库后过）。
> - **E2E**：门禁/两阶段审批/自动执行/dev-token/驳回复审/并发单赢家/失败重试告警/RETRY/四类型/幂等/status 全通过。
> - **已知限制**：单节点供数方需第二 owner 账号（carol）；P2P 单节点下第二个 ownerId 账号过不了平台接口权限（`DefaultApiResourceAuth` 要求 ownerId==节点.inst_id）→ 供数方需 `owner_type=EDGE` + 最小权限角色 `DATA_PROVIDER`（10 读接口 code，含补录 `INST_GET`）才能进浏览器（dev 实例已配）；SPEC_CHANGE 有重启窗口 + 本环境 k3s 无法拉起新容器；执行期禁用镜像报「记录不存在」。

### Z-04 数据抽样与脱敏服务
- 实现随机、分层、整群/分块、等距等**至少三种**可配置抽样方法。
- 提供受控的自定义代码抽样能力和执行隔离。
- 实现掩码、替换、哈希、取整、空值/清除等脱敏方法。
- 保存抽样和脱敏策略、任务记录、数据血缘及结果数据集。
- 保证处理过程不暴露未经授权的真实数据。

交付物：数据治理 API、执行组件、策略模型、审计日志和测试数据集。

> **已完成（2026-08-19，报告 `claude/plans/Z-04-task-report.md`）**。三仓库已推送 develop/zgz。
> - **V11 迁移**：`ds_governance_policy`（策略 CRUD+软删）、`ds_governance_task`（8 态 + exec_params 全快照 +
>   script_content + kuscia_job_id + retry_count）、`ds_governance_lineage`（source→target 全链）× center/edge/p2p 三套。
> - **内置引擎**（Java 进程内）：抽样 4 种（RANDOM count/ratio+seed 复现、SYSTEMATIC 等距、STRATIFIED 按列分层、
>   CLUSTER 整群/块）+ 脱敏 5 种（MASK 掩码、REPLACE 替换、HASH SHA-256+列盐、ROUND 取整、CLEAR 置空/删列）；
>   输出列 = 输入列经 CLEAR 过滤，全程不落中间文件。
> - **自定义代码执行 + 隔离**：一次性 Kuscia Job（AppImage `data-sandbox-sampler`，python:3.11-slim），输入经
>   `task_input_config` 内联（≤5000 行/256KB，超限 `GOV_INPUT_TOO_LARGE`），结果经 **scope=Cluster 端口**由平台
>   取回；隔离：无卷无密钥、仅入参、CPU/内存限额（默认 0.5CPU/512Mi）、容器脚本超时 + 平台 300s stopJob 兜底、
>   跑完即删、`-nonet` 变体（scope=Domain）对照。
> - **权限**：`checkSourcePermission`——仅已授权 `project_datatable` 或 `nodeId==ownerId` 平台自有数据可处理；
>   策略/任务按创建人隔离；preview/submit/mount 全程校验 + 审计（`GOVERNANCE_*` 事件写 `ds_unified_log`）+ 血缘。
> - **端点**：`/api/v1alpha1/data-governance/*` 15 个（policies CRUD/detail、tasks submit/list/detail/cancel/retry/
>   results/mount/**results/view**、lineage、preview）；错误码 `GOV_NO_PERMISSION/GOV_INPUT_TOO_LARGE/GOV_NOT_FOUND/GOV_STATE_CONFLICT/
>   GOV_PARAM_INVALID`。
> - **结果展示（后增，fd1ea4a）**：`GET /tasks/results/view?taskId=` 查看任务结果数据——仅 `SUCCEEDED` 且含结果数据集
>   可查；**脱敏门禁**：masked 派生自 `exec_params.masking` 非空，未脱敏（纯抽样/自定义输出）返回告警消息、不返回行数据，
>   保证不暴露真实数据；表头携带数据源（sourceName/node/datatableId → resultName/node/datatableId + 抽样方法 + masked
>   标记 + sourceRows/resultRows + header + 前 100 行）；结果读取复用 readCsv 解析结果 CSV（结果表属主目录）。
>   前端任务列表/结果数据集增加「查看结果」入口（`feat(data-governance): z-04 结果数据展示`）；测试 +4 例（总 16 例全绿）。
>   使用说明书见 `claude/docs/数据治理页面使用说明书.md`（用例表 gov_bank_sample/qpfcjppm，含真实实测记录）。
> - **配置**（env 前缀 `SECRETPAD_DATA_SANDBOX_GOVERNANCE_*`）：`input-rows:5000`、`input-bytes:262144`、
>   `timeout-seconds:300`、`max-retries:3`、`poll-interval-ms:10000`、`cpu:0.5`、`memory:512Mi`、`app-image:data-sandbox-sampler`。
> - **结果挂载修复**：SecretPad `/app/data` 与 Kuscia `/home/kuscia/var/storage/data` 指向同一宿主目录（对齐官方
>   secretpad.sh），dev 上传/产出的表同源可被 SecretFlow 消费；结果表 `mount` 到 P2P 项目（source=IMPORTED）。
>   2026-08-20 修复：此前 `mount` 写 `source=CREATED`，而项目「数据集」树（`ProjectServiceImpl#getProjectDatatableDtos`）
>   仅按 `IMPORTED` 查询，导致挂载后项目内看不到结果表；已改为写 `IMPORTED`（governance+dev 双 mount，IT 断言同步）。
> - **测试**：Z-04 新增 71 例全绿（CsvUtil 7 + 抽样 12 + 脱敏 11 + DataGovernanceIT 19 + CustomIT 8 + ControllerTest 14）；
>   全量回归基线同 Z-03（404 例，9 pre-existing）。E2E 10 项全过（策略 CRUD/抽样×4/脱敏×5/自定义代码/隔离
>   （外联阻断+pod限额+超时kill+cancel+retry）/权限/血缘/审计/结果挂项目/挂载修复 MD5 一致）。
> - **已知限制**：CUSTOM 输入子集上限（行/字节，超限拒绝）；`task_input_config` 挂载路径 `/etc/kuscia/sampler-conf.json`
>   依赖 Kuscia 0.13.0b0；`/data/download` 只服务 Job 产物（治理结果经 preview/project_datatable 消费）；
>   P2P 项目可见性需审批流产物（`project_inst`+approval config+vote 行，dev 模拟）。
> - **2026-08-20 修复（前端 `c14ac78`）**：任务提交表单此前**无策略选择控件**（说明书所述「策略 ID」字段实际不存在），且内联字段名
>   `samplingMethod/samplingParams/maskingColumns` 与后端契约（`sampling`Map/`masking`List/`policyId`）不匹配，导致手工填写
>   的抽样/脱敏被静默丢弃、任务退化为全量拷贝（100→100）。已新增「复用策略」下拉（选择后自动填充抽样/脱敏并直接执行，内联可覆盖）
>   + 提交时组装后端契约；实测选策略（100→30 + 5 列脱敏）与内联（100→30 + phone/id_card MASK，查看结果 `180****6075`）均通过。

### Z-05 JAR、SQL 与 Python 开发能力
- 实现 JAR 包上传、校验、版本管理、参数配置、调试和运行。
- 提供 SQL 编辑、执行、调试、结果预览和任务保存。
- 提供 Python 函数开发、依赖库白名单和受控生态库导入。
- 区分开发与生产运行模式，形成任务创建、运行、停止和重试闭环。

交付物：计算任务 API、运行组件、制品管理、版本管理和调试日志。

> **已完成（2026-08-19，报告 `claude/plans/Z-05-task-report.md`）**。三仓库已推送 develop/zgz。
> - **V12 迁移**：`ds_dev_artifact`（制品）+ `ds_dev_artifact_version`（版本自增不可变，content/file/sha256/params_schema/
>   dependency_names）+ `ds_dev_task`（任务全快照，run_mode DEV/PROD）+ `ds_dev_dependency`（白名单，预置 numpy/pandas）+
>   `ds_dev_run_log`（按 attempt 调试日志）× center/edge/p2p 三套 + package 打包接线。
> - **制品管理**：JAR 上传（ZIP 魔数 + MANIFEST.MF 校验 + sha256 + 落盘，默认 48MB `DEV_JAR_BYTES`）+ SQL/PYTHON 脚本版本；
>   版本自增不可变，latest_version 回填/回退；仅创建人可改删。
> - **任务闭环**：提交（DEV 调试 / PROD 正式，JAR/SQL/PYTHON）→ 运行（SQL 内嵌 SQLite 进程内只读执行；JAR/PYTHON 走一次性
>   Kuscia 容器 `data-sandbox-{jar,python}-runner`，CPU 0.5/512Mi、无网络、跑完即删）→ 取消（RUNNING **deleteJob 终止 pod**）→
>   重试（FAILED，retry_count<maxRetries=3，run_log attempt 保留）。
> - **Python 依赖白名单**：平台侧 `DevDependencyChecker` 校验顶层 import（白名单∪标准库，否则 `DEV_DEPENDENCY_REJECTED`）；
>   runner 侧 `builtins.__import__` 守卫兜底（放行已安装包集=镜像硬边界，`import requests` 报 `dependency not allowed`）。
> - **调试日志不丢失**：runner 失败不退出（`/status=failed` 常驻提供 `/log`），executor 取回原因写 `ds_dev_run_log` +
>   `error_message`（如 `执行容器失败: py failed rc=1: ImportError: dependency not allowed: requests`，无 `[py]` 前缀）。
> - **PROD 结果**：注册 Kuscia DomainData（`dev-<taskId>`）+ `DEV_TASK_LINEAGE` 血缘 + 可挂项目 source=IMPORTED（重复挂载
>   `DEV_STATE_CONFLICT`；2026-08-20 由 CREATED 修正为 IMPORTED，否则项目数据集树不展示）；DEV 仅结果预览不注册。
> - **权限/审计**：`checkSourcePermission` 源表授权；制品/任务/依赖按创建人隔离；viewResult/runLog 限创建人；写操作
>   `DEV_*` 事件写 `ds_unified_log` + webhook。
> - **端点**：`/api/v1alpha1/data-dev/*` 25 个（artifacts CRUD/versions/upload/download、tasks submit/list/detail/cancel/retry/
>   preview-source/results/results-view/log/mount、dependencies CRUD）；错误码 `DEV_NO_PERMISSION/DEV_INPUT_TOO_LARGE/DEV_NOT_FOUND/
>   DEV_STATE_CONFLICT/DEV_PARAM_INVALID/DEV_DEPENDENCY_REJECTED`（全局异常映射 `IllegalArgumentException`→UNKNOWN_ERROR，
>   与 GOV_* 同约定）。
> - **前端**：`modules/data-dev` 4 Tab（制品管理/任务管理/SQL 工作台/依赖白名单）+ `DataDevApi` + edge 菜单（`c610bb9`）。
> - **配置**（env 前缀 `SECRETPAD_DATA_SANDBOX_DEV_*`）：`input-rows:5000`、`input-bytes:262144`、`jar-bytes:50331648`、
>   `timeout-seconds:300`、`max-retries:3`、`poll-interval-ms:10000`、`cpu:0.5`、`memory:512Mi`、
>   `jar-app-image`/`python-app-image`、`sql-limit:100`、`sql-timeout-seconds:30`、`result-preview-rows:50`。
> - **测试**：Z-05 新增 67 例全绿（DevSqlEngine 10 + DevDependencyChecker 10 + DevJarValidator 5 + DevJobExecutor 5 +
>   DataDevIT 11 + DataDevCustomIT 7 + DataDevControllerTest 19）。E2E 8 项全过（JAR/SQL/PYTHON 全模态 DEV+PROD、
>   白名单/守卫/拒绝、取消终止 pod/重试、权限、审计、血缘、隔离 pod limits + nonet + 取回即删）。
> - **已知限制**：JAR 经 task_input_config base64（默认 48MB，Kuscia 大体积承载上限未实测）；SQL 为内嵌 SQLite 只读引擎
>   （非生产 SQL 引擎）；白名单条目须重建 python-runner 镜像；`-nonet` 无 Cluster 端点结果不可取回；挂载 P2P 项目依赖审批流产物。

### Z-06 模型测试执行与 API 发布
- 将模型审批单与实际模型制品、版本和项目绑定。
- 支持审批人员配置测试参数、选择测试数据并执行模型。
- 保存测试日志、输入摘要、输出摘要和评估指标。
- 实现模型发布 API、调用凭证、授权用户、IP 白名单和有效时间控制。

交付物：模型测试执行服务、审批结果模型和受控模型 API。

> **已完成（2026-08-20，报告 `claude/plans/Z-06-task-report.md`）**。三仓库已推送 develop/zgz。
> - **V13 迁移**：`ds_model_approval` 扩展 `artifact_id`/`artifact_version_id`/`test_evidence`（与 V6 legacy 行并存）；
>   `ds_dev_task` 增 `channel`（dev/model/api）+ `result_uri`；新建 `ds_model`/`ds_model_test`/`ds_model_api` × center/edge/p2p
>   三套 + package 打包接线。
> - **模型注册**：`/models/register` 绑定 Z-05 制品（**仅 JAR/PYTHON**，SQL → `MODEL_PARAM_INVALID`）+ 版本 + 项目；
>   版本自增，同项目同制品非终结态重复注册 `MODEL_ALREADY_EXISTS`；`ds_model`（DRAFT→APPROVING→APPROVED/REJECTED→PUBLISHED/OFFLINE）。
> - **审批 + 强制测试门禁**：`ModelApprovalService` 复用 `ModelApprovalStateMachine`（MODEL_REVIEW→RESOURCE_REVIEW→APPROVED→PUBLISHED）；
>   **APPROVE→APPROVED 前需 ≥1 次成功测试且保存评估指标**，否则 `MODEL_TEST_REQUIRED`。
> - **测试执行**：`/models/tests/execute` 审批人选项目内数据集 + 参数 + label/prediction 列 + metric_type → `ds_dev_task(channel='model')`
>   + `DevJobExecutor` 异步跑 → `ds_model_test` 读时惰性收官（镜像任务状态 + `ModelMetricsEvaluator` 行级对齐算指标：分类
>   accuracy/macro P/R/F1/混淆矩阵，回归 MAE/RMSE/R²）+ 输入/输出摘要 + 审批 test_evidence + run_log 按 attempt；取消/重试。
> - **受控 API 发布**：`ds_model_api`（`app_id='ai-'`+secret，sha256 常量时间比对，一次性展示/列表不回显）+ authorized_users +
>   IP 白名单 + valid_from/valid_to + call_count；`/model-api/invoke` 守卫顺序=启用→有效窗口→IP→授权用户（凭证调用者跳过），
>   两路鉴权（X-APP-ID/X-APP-SECRET 经 LoginInterceptor 强制分支；User-Token+body.appId 须在名单）；同步推理
>   `runAndAwait(channel='api')` 返回 `{header,rows,resultRows,elapsedMs}`（调度器不轮询 api 通道，防双收官）。
> - **权限/审计**：模型创建人可管；测试执行人=创建人或审批 reviewer（**数据集仅须属于模型项目，审批人不必是项目成员**——
>   对 Z-05 owner-only 的刻意放宽）；写操作 `MODEL_*` 事件写 `ds_unified_log` + webhook `model.*`。
> - **端点**：`/api/v1alpha1/models` 16 个（register/list/detail/update/delete + approvals submit/list/detail/action/history +
>   tests execute/list/detail/log/cancel/retry）+ `/api/v1alpha1/model-api` 9 个（create/list/detail/update/regenerate-secret/
>   enable/disable/delete/invoke）= 25；错误码 `MODEL_NO_PERMISSION/MODEL_NOT_FOUND/MODEL_STATE_CONFLICT/MODEL_PARAM_INVALID/
>   MODEL_INPUT_TOO_LARGE/MODEL_DEPENDENCY_REJECTED/MODEL_ALREADY_EXISTS/MODEL_TEST_REQUIRED/MODEL_METRIC_ALIGNMENT/
>   MODEL_API_CREDENTIAL_INVALID/MODEL_API_DISABLED/MODEL_API_EXPIRED/MODEL_API_IP_DENIED/MODEL_API_USER_DENIED`。
> - **前端**：`modules/model-center` 4 Tab（模型注册/模型审批+测试执行面板/测试记录/API 发布+调用控制台）+ `DataModelApi` +
>   edge 菜单（`5c93b6c`）。
> - **配置**（env 前缀 `SECRETPAD_DATA_SANDBOX_MODEL_*`）：`test.input-rows:5000`、`test.input-bytes:262144`、
>   `test.max-retries:3`、`test.result-preview-rows:50`、`api.max-rows:1000`、`api.max-input-bytes:262144`、
>   `api.timeout-seconds:300`、`metrics.classification-distinct-threshold:20`；测试超时/镜像/收官复用 `dev.*`。
> - **测试**：Z-06 新增 64 例全绿（ModelMetricsEvaluator 15 + ModelApprovalStateMachine 11 + ModelApiGuard 19 +
>   ModelControllerTest 5 + DevJobExecutorTest 5 + DataModelIT 9）。E2E 11 项全过（注册/SQL 拒绝、审批流转、测试+指标+摘要+
>   test_evidence、门禁负向、PUBLISH+API+一次性密钥、invoke+call_count、五类守卫负向、密钥轮换、PYTHON 路径、MODEL_* 审计、
>   隔离 pod 500m/512Mi + GOVERNANCE + 取回即删）。
> - **已知限制**：测试权限放宽（审批人不必是项目成员，但数据集须属模型项目）；invoke 执行任意模型代码（复用 Z-05 全套隔离，
>   平台不审查模型代码语义）；指标行级 1:1 对齐（不一致 `MODEL_METRIC_ALIGNMENT`，idColumn 联接留后续）；legacy/新审批单并存；
>   kuscia pod 取回删除后 GC 有 ~1–2 分钟窗口；IP 白名单须含实际出口 IP（个人实例经 docker bridge 172.22.0.1）。

### Z-07 租户、部署、计费与可信平台对接
- 实现租户开通、资源规格分配、规格变更和自动部署接口。
- 建立资源用量计量、费用计算和费用上报接口。
- 对接可信数据流通平台的数据推送、成果回传和访问控制策略。
- 实现数据开发与运算日志上报、签名验签、幂等、重试和对账。
- 提供完整 OpenAPI 文档、错误码、调用样例和联调工具。

交付物：专项适配器、接口文档、联调记录、失败补偿和对账记录。

### Z-08 安全、备份与运维增强
- 完善 API 凭证轮换、密钥加密存储、OIDC 登录和权限映射。
- 将备份范围扩展到数据库、配置、证书、沙箱元数据和必要制品。
- 实现备份校验、恢复演练、回滚和恢复点管理。
- 完善服务健康、节点健康、任务健康、存储和证书诊断。
- 建立安全审计、敏感信息脱敏和漏洞修复流程。

交付物：安全配置、备份恢复方案、恢复演练报告和诊断工具。

### Z-09 性能与稳定性验证
- 建设任务并发、沙箱并发和数据吞吐压测环境。
- 验证任务数大于 500，并逐步验证 1000 和 2000 任务等级。
- 验证分布式单节点并行沙箱实例数不少于 16。
- 验证结构化文本批量处理吞吐量不低于 30GB/h。
- 完成长时间稳定性、异常恢复、资源泄漏和容量边界测试。

交付物：压测工具、测试数据、性能报告、瓶颈分析和优化记录。

## 4. 协作边界与开发规范

### 协作边界
- 前后端以 **OpenAPI 为契约**：后端接口变更须同步接口文档和错误码，前端不得依赖未声明字段。
- xzh 负责页面交互、前端状态、权限入口和验收演示；**zgz 负责后端状态机、运行时、数据一致性、
  安全边界和基础设施联动**。
- 跨模块功能以端到端用例为完成标准，不能以页面存在、数据库有记录或接口返回成功作为完成依据。
- **每个功能提交必须包含必要的单元测试或集成测试**；涉及运行时、资源、数据安全和恢复的功能
  必须提供可重复验证步骤。
- 前后端修改分别提交到 `secretpad` 和 `secretpad-frontend`。

### 构建与部署边界（重要）
- **xzh 是共享系统唯一的构建和部署执行人。** zgz 不在共享 Alice/Bob 环境中执行
  `build.sh`、`install.sh`、容器替换、数据库迁移、恢复或回滚操作。
- zgz 可以在个人工作目录执行单元测试、静态检查和不影响共享环境的本地验证；正式 JAR、前端静态
  资源、Docker 镜像和部署包均由 xzh 从已推送代码统一生成。
- zgz 的集成测试统一使用个人代码副本中的 **`data-sandbox-package/develop.sh`**。该脚本只创建
  zgz 私有的 Kuscia、SecretPad、数据库、证书、网络、端口和运行目录，不得读取或挂载任何 xzh
  路径及共享 Alice/Bob 数据。
- **测试方法（双模式，对齐管理员 develop/xzh 脚本意图）**：`develop.sh up --branch <分支>`
  默认**直接构建当前工作树**——允许未提交改动，直接在分支上测试，测试通过后再提交推送；
  `--pushed-only` 恢复严格校验（clean + 与远程 upstream 完全一致）用于发布验证。
- zgz 可使用 `develop.sh status`、`logs`、`restart` 和 `down` 管理个人测试实例；`down` 只停止
  带有当前用户和当前工作区所有权标签的容器，并保留个人测试数据。

### 提交规范
- 提交信息应说明**模块、变更内容、数据库迁移、配置变更和兼容性影响**；未提交或未推送的代码
  不进入统一构建。
- **禁止提交到 Git**：本地运行日志、数据库、证书、密钥、镜像产物、运行时目录和个人配置。
- 不通过 scp、rsync、共享目录覆盖或手工复制源文件同步代码，只通过 Git pull/push。

## 5. 近期优先级（zgz 相关）

1. 先完成真实 Jupyter/Python 沙箱和资源隔离，消除"状态运行但无实际容器"的问题。
2. 完成资源申请审批闭环，使审批通过能够自动分配资源并拉起沙箱。
3. 完成数据抽样、脱敏和使用控制，覆盖采购文件中的必要数据治理能力。
4. 完成模型测试执行和受控 API 发布。
5. 根据可信数据流通平台实际协议完成专项对接，不以通用 Webhook 代替验收接口。

## 6. 验收判定原则（zgz 任务相关）

- "已完成"必须同时具备前端操作、后端接口、持久化、权限、异常处理和测试证据。
- 沙箱启动必须存在真实运行实例，并能够通过平台进入开发环境。
- CPU、GPU、内存、存储和网络策略必须在运行实例上实际生效。
- 数据抽样和脱敏必须产生可追溯的新数据集，且全过程形成审计记录。
- 审批必须能控制后续资源分配或模型发布，不接受仅修改审批状态的实现。
- 系统对接必须使用采购方确认的协议完成实际联调。
- 性能指标必须以可复现的测试脚本、环境参数和正式报告为依据。
