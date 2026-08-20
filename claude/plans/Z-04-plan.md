# Z-04「数据抽样与脱敏服务」开发计划（zgz）

> 执行前说明：本计划批准后，**执行阶段的第一步**就是把这份（含用户补充的）最终版计划原样
> 写入 `/data/zgz/datasandbox/claude/plans/Z-04-plan.md` 留存，然后再开始 Stage 0。

## Context

Z-01/Z-02/Z-03 已交付真实沙箱运行时、资源调度隔离、沙箱申请审批闭环。但**数据治理能力为零**：
抽样/脱敏/水印全库无实现（唯一的 `DesensitizationUtils` 只是日志/界面打码）；数据目录只有原版
SecretPad 的 `data-manager`（上传 CSV + 授权 + 下载，`DatatableController`）。数据表元数据是 Kuscia
`DomainData`（gRPC 查询，SecretPad 本地只存 `project_datatable` 授权关系），物理文件是 CSV，位于
SecretPad `/app/data/<nodeId>/<随机名>.csv`（`secretpad.data.dir-path`，默认 `/app/data/`）。无任何
"返回行数据"API（唯一文件通道是 `data/download` 流式 CSV）。

Z-04 目标（任务书）：
1. 实现随机、分层、整群/分块、等距等**至少三种**可配置抽样方法。
2. 提供受控的自定义代码抽样能力和执行隔离。
3. 实现掩码、替换、哈希、取整、空值/清除等脱敏方法。
4. 保存抽样和脱敏策略、任务记录、数据血缘及结果数据集。
5. 保证处理过程不暴露未经授权的真实数据。

交付物：数据治理 API、执行组件、策略模型、审计日志和测试数据集。

**验收原则（CLAUDE.md）**：数据抽样和脱敏必须产生可追溯的新数据集，且全过程形成审计记录；
"已完成"必须同时具备前端操作、后端接口、持久化、权限、异常处理和测试证据。

## 用户已确认决策

1. **自定义代码执行隔离 = 一次性 Kuscia 执行容器**：新建 AppImage `data-sandbox-sampler`（Python
   基础镜像），一次性 Kuscia Job 运行。**输入数据经 `task_input_config` 携带**（已实证机制：AppImage
   `configTemplates` 用 `"task_input_config": "{{.TASK_INPUT_CONFIG}}"` + 容器 `configVolumeMounts`
   挂载读取，见 `scripts/templates/tee-image.yaml` 先例），CPU/内存限额 + 超时 kill（stopJob）+
   跑完即删（deleteJob），结果经容器 Cluster HTTP 端口由平台经 `secretpad.gateway`（Kuscia 节点
   envoy :80，Host 头路由，复用 `SandboxProxyController` 的 `.svc` 机制）取回。
2. **内置抽样/脱敏全部在后端进程内 Java 执行**：随机 RANDOM、等距 SYSTEMATIC、分层 STRATIFIED、
   整群 CLUSTER（4 种抽样）+ 掩码 MASK、替换 REPLACE、哈希 HASH、取整 ROUND、空值/清除 CLEAR（5 种
   脱敏）。进程内复用 `DataServiceImpl.download` 路径解析读物理 CSV，写结果 CSV，注册 DomainData。
3. **治理任务不加审批流**，但执行前做**数据权限校验**（发起人只能处理已授权到其项目的 `project_datatable`，
   或 `nodeId==user.ownerId` 平台自有数据）+ 全程 `ds_unified_log` 审计 + 血缘。
4. **结果数据集注册为 Kuscia DomainData（type=table, CSV）+ 可选挂项目（source=CREATED）**，并修复
   develop.sh 挂载偏差：secretpad `/app/data` 与 kuscia `/home/kuscia/var/storage/data` 指向同一宿主目录
   （对齐官方 `scripts/deploy/secretpad.sh` 行为），使 dev 中上传/产出的表同源可被 SecretFlow 消费。

## 阶段划分

| 阶段 | 内容 | 关键产出 |
|---|---|---|
| 0 | 计划落盘 + V11 迁移 + 纯类（CsvUtil/抽样/脱敏）与单测 | `claude/plans/Z-04-plan.md`、V11 SQL×3+副本、`GovernanceSamplingExecutor`/`GovernanceMaskingExecutor`/`CsvUtil`+Test |
| 1 | 内置抽样/脱敏引擎 + 权限校验 + 结果注册 + 审计 | `DataGovernanceService`、`GovernanceIT` |
| 2 | 自定义代码执行组件（AppImage + 一次性 Job + 输出取回） | `data-sandbox-sampler` AppImage 模板+注册脚本、`GovernanceCustomExecutor`、`GovernanceCustomIT` |
| 3 | 数据治理 API | `DataGovernanceController` + `DataGovernanceControllerTest` |
| 4 | 前端 | `modules/data-governance/`、`services/data-sandbox.ts`、edge 菜单 |
| 5 | 测试数据集 + develop.sh 挂载修复 + E2E | `gov_sample*.csv`、挂载修复、10 项 E2E 清单 |
| 6 | OpenAPI 契约 + 报告 + CLAUDE.md 同步 | `claude/plans/Z-04-task-report.md`（仿 Z-03 六章）、CLAUDE.md、三仓库提交 |

---

## Stage 0 — 计划落盘 + V11 迁移 + 纯类与单测（先做）

1. 将本计划复制到 `/data/zgz/datasandbox/claude/plans/Z-04-plan.md`。
2. **V11 迁移**，三份内容一致（`secretpad-web/config/schema/{center,edge,p2p}/V11__data_governance.sql`，
   仿 V6/V9 风格：License 头 + 注释、varchar PK、`varchar(32)` 时间、`deleted` 软删、`create index if not exists`）：

```sql
-- 策略表：可保存复用的抽样/脱敏策略
create table if not exists ds_governance_policy (
    id              varchar(64)  primary key,       -- 'gp-' + shortId()
    name            varchar(128) not null,
    description     varchar(512) default '',
    policy_type     varchar(16)  not null,           -- SAMPLING / MASKING / SAMPLING_MASKING
    sampling_method varchar(16)  default '',         -- RANDOM/SYSTEMATIC/STRATIFIED/CLUSTER
    sampling_params varchar(2048) default '{}',      -- JSON {count|ratio|strataColumns|clusterColumn|blockSize|seed|limit}
    masking_columns varchar(4096) default '[]',      -- JSON [{column,method,params}]
    created_by      varchar(64)  not null,
    created_at      varchar(32)  not null,
    updated_at      varchar(32)  not null,
    deleted         integer      not null default 0
);
create index if not exists idx_gp_type on ds_governance_policy(policy_type, deleted);

-- 任务表：每次执行一条记录，payload 全快照可追溯
create table if not exists ds_governance_task (
    id                   varchar(64)  primary key,   -- 'gt-' + shortId()
    name                 varchar(128) not null,
    description          varchar(512) default '',
    policy_id            varchar(64)  default '',
    exec_mode            varchar(16)  not null,      -- BUILTIN / CUSTOM
    source_node_id       varchar(64)  not null,
    source_datatable_id  varchar(64)  not null,
    source_relative_uri  varchar(255) default '',
    exec_params          varchar(8192) default '{}', -- 全快照 {sampling:{method,params},masking:[...]}
    script_content       varchar(65535) default '',  -- CUSTOM 脚本文本
    status               varchar(16)  not null default 'PENDING', -- PENDING/RUNNING/SUCCEEDED/FAILED/CANCELLED
    result_node_id       varchar(64)  default '',
    result_datatable_id  varchar(64)  default '',
    source_rows          bigint default 0,
    result_rows          bigint default 0,
    error_message        varchar(2048) default '',
    kuscia_job_id        varchar(128) default '',
    retry_count          integer      not null default 0,
    created_by           varchar(64)  not null,
    created_at           varchar(32)  not null,
    started_at           varchar(32)  default '',
    finished_at          varchar(32)  default '',
    deleted              integer      not null default 0
);
create index if not exists idx_gt_status on ds_governance_task(status, deleted);
create index if not exists idx_gt_source on ds_governance_task(source_node_id, source_datatable_id, deleted);

-- 血缘表：source → 策略/任务 → target 全链
create table if not exists ds_governance_lineage (
    id                   integer primary key autoincrement,
    task_id              varchar(64)  not null,
    source_node_id       varchar(64)  not null,
    source_datatable_id  varchar(64)  not null,
    target_node_id       varchar(64)  not null,
    target_datatable_id  varchar(64)  not null,
    op_type              varchar(16)  not null,      -- SAMPLE/MASK/SAMPLE_MASK/CUSTOM
    created_by           varchar(64)  not null,
    created_at           varchar(32)  not null,
    deleted              integer      not null default 0
);
create index if not exists idx_gl_source on ds_governance_lineage(source_node_id, source_datatable_id);
create index if not exists idx_gl_target on ds_governance_lineage(target_node_id, target_datatable_id);
```

   design：不建独立 result 表——结果数据集 = 注册的 Kuscia DomainData，由 task 的
   `result_datatable_id/result_node_id` 记录，结果列表由 task 表 status=SUCCEEDED 派生；血缘单独建表
   （不复用 `project_read_data`——其语义是项目读取，治理血缘需要 source→target 全链）。
   package 副本：`data-sandbox-package/build.sh`（COPY schema 段）+ `data-sandbox-package/Dockerfile`
   （COPY 段）追加 V11 三行（仿 V10 处理）。

3. **纯类 + 单测**（`secretpad-web/.../web/service/governance/`，仿 `SandboxStatusMachine` 纯类风格，无 Spring）：
   - `CsvUtil`：手写 RFC4180 CSV 读写（引号/逗号/换行/CRLF/BOM 处理）。**不引入 opencsv/commons-csv**
     （项目现无 CSV 库；受控 CSV 场景 + 避免新依赖；如需回退在报告附录注明 commons-csv 为已论证选项）。
   - `GovernanceSamplingMethod` 枚举 + `GovernanceSamplingExecutor`（纯函数：rows+header+params+seed →
     输出行）：RANDOM（count/ratio，可 seed）、SYSTEMATIC（等距取 k）、STRATIFIED（按 strataColumns
     分组每组取 count/ratio）、CLUSTER（按 clusterColumn 或连续块整群取 blockSize）。
   - `GovernanceMaskingMethod` 枚举 + `GovernanceMaskingExecutor`（纯函数，按列方法集应用）：
     MASK（保留前缀/后位，如 `138****1234`）、REPLACE（列内常量替换）、HASH（SHA-256 + 每列盐，
     不可逆）、ROUND（数值小数位取整）、CLEAR（置空）。
   - 单测：`CsvUtilTest`、`GovernanceSamplingExecutorTest`（4 方法 × 参数边界 × 计数断言）、
     `GovernanceMaskingExecutorTest`（5 方法 × 类型边界）。

**Stage 0 提交（secretpad）**：迁移 + 纯类 + 单测。

---

## Stage 1 — 内置抽样/脱敏引擎（Java 进程内）

`DataGovernanceService`（`secretpad-web/.../web/service/governance/DataGovernanceService.java`，注入
`DataSandboxMvpService` + `JdbcTemplate` + `KusciaGrpcClientAdapter` + `DatatableManager` + repositories）：

- **数据读取**：复用 `DataServiceImpl` 路径解析——`dirPath = storeDir + nodeId + "/"`（`storeDir`
  = `secretpad.data.dir-path`，默认 `/app/data/`），`filePath = dirPath + relativeUri`，canonical path
  安全校验（仿 `DataServiceImpl.download` 的 `checkPathInWhitelist` + `startsWith` 检查），读时跳过 BOM。
  元数据用 `DatatableManager.findByNodeId`/`findById` 拿 `relativeUri` + `schema`（列名/类型/注释）。
- **权限前置校验** `checkSourcePermission(user, nodeId, datatableId)`：
  1. `UserContextDTO.projectIds` 取当前用户项目集；
  2. `ProjectDatatableRepository` 校验 `(nodeId, datatableId, is_deleted=0)` 落在用户任一项目；
     **或** `nodeId == user.ownerId`（平台自有数据，经 `nodeRepository` 校验平台节点）。
  3. 拒绝 → 明确错误（`GOV_NO_PERMISSION`）。
- **内置执行流** `submitBuiltinTask`：校验 → 读 CSV → 快照 `exec_params` → 落 task（PENDING）→
  条件 UPDATE PENDING→RUNNING（仿 Z-03 affected==1 并发控制）→ `GovernanceSamplingExecutor` 抽样 →
  `GovernanceMaskingExecutor` 脱敏 → 写结果 CSV 到 `storeDir + nodeId + "/" + <taskId>-<shortId>.csv` →
  **注册 DomainData**（复用 `LocalKusciaControlDatatableHandler.buildCreateDomainDataRequest` 构造
  `CreateDomainDataRequest{domaindata_id=genDomainDataId(), domainId=nodeId, name=<taskId>, type="table",
  fileFormat=CSV, relativeUri=<结果文件名>, columns=schema}`，`KusciaGrpcClientAdapter.createDomainData`）→
  回填 `result_datatable_id/result_rows` → RUNNING→SUCCEEDED → 写血缘；失败 → FAILED + `error_message` +
  `raiseAlert("WARNING","GOVERNANCE","数据治理任务执行失败",...,"gov:"+taskId+":failed")`。
- **审计**：`auditAs`/`audit` 写 `ds_unified_log`（submit/success/fail/cancel/retry 全链路），webhook
  事件 `governance.*`（复用 `dispatchWebhooks`）。
- **只输出策略允许的数据**：输出列 = 输入列经 CLEAR（清除列）过滤 + 抽样/脱敏后的行；全程不写任何
  中间文件到可被沙箱/他方读取的位置。

**Stage 1 测试（secretpad）**：`DataGovernanceIT`（@SpringBootTest + @ActiveProfiles("test") +
@TestInstance(PER_CLASS) + @Execution(SAME_THREAD) + 独立 `/tmp/ds-governance-it.sqlite` +
MockKusciaGrpcServer :50053 + test 资源 CSV）——4 抽样 × 5 脱敏组合各 1 例（断言结果行数/内容 +
`createDomainData` 被调 + 血缘 + 审计）；权限拒绝例（未授权表被拒、无项目用户被拒）；CLEAR 列过滤断言。

---

## Stage 2 — 自定义代码执行组件（一次性 Kuscia Job）

### 2.1 镜像与 AppImage

- **容器代码**（`data-sandbox-package/docker/data-sandbox-sampler/`）：`Dockerfile`（Python 基础镜像，
  quay.io/jupyter/scipy-notebook 或 secretflow-anolis8）+ `sampler_server.py`（stdlib `http.server`
  8000 端口 mini 服务，路由 `GET /status`、`GET /result`（结果 CSV）、`GET /log`）+ `start.sh`
  （读配置 → 解码输入 → 执行用户脚本 → 写结果/日志）。
- **AppImage 模板**（`secretpad/scripts/templates/data-sandbox-sampler.yaml`，仿 `tee-image.yaml`）：

```yaml
apiVersion: kuscia.secretflow/v1alpha1
kind: AppImage
metadata:
  name: data-sandbox-sampler
spec:
  configTemplates:
    samplerConf: |-
      {"task_input_config": "{{.TASK_INPUT_CONFIG}}"}
  deployTemplates:
    - name: sampler
      replicas: 1
      spec:
        containers:
          - command: [sh, -c, "python /app/sampler_server.py --config /etc/kuscia/sampler-conf.json"]
            configVolumeMounts:
              - mountPath: /etc/kuscia/sampler-conf.json
                subPath: samplerConf
            name: sampler
            ports:
              - name: sampler
                port: 8000
                protocol: HTTP
                scope: Cluster        # 结果取回通道（平台经 gateway Host 头路由访问）
            readinessProbe: { tcpSocket: { port: sampler } }
            livenessProbe: { tcpSocket: { port: sampler } }
            startupProbe: { failureThreshold: 60, tcpSocket: { port: sampler }, periodSeconds: 10 }
            workingDir: /app
        restartPolicy: Never
  image: { id: "{{.IMAGE_NAME}}:{{.IMAGE_TAG}}", name: {{.IMAGE_NAME}}, sign: "", tag: {{.IMAGE_TAG}} }
```

  另建 `data-sandbox-sampler-nonet.yaml`（scope 改 Domain，**无 Cluster 端点 = 不可达证明**，供 E2E
  隔离对照）。注册脚本 `secretpad/scripts/deploy/data-sandbox/register-data-sandbox-sampler-appimages.sh`
  （仿 register-data-sandbox-appimages.sh：docker exec kuscia + kubectl apply + sed 替换 IMAGE_NAME/TAG）。

### 2.2 平台侧 `GovernanceCustomExecutor`

- **task_input_config 结构**（Kuscia 挂载进容器为 JSON，容器内解码）：

```json
{ "script": "<python 源码>", "input_csv_b64": "<base64 授权输入CSV>", "params": { "seed": 1 } }
```

  **输入子集化**：平台先按源表全量读入，应用策略允许的列过滤（去敏感列），并限制行数（默认 ≤
  `SECRETPAD_DATA_SANDBOX_GOVERNANCE_INPUT_ROWS:5000`，可配）；**base64 后字节上限**默认
  `SECRETPAD_DATA_SANDBOX_GOVERNANCE_INPUT_BYTES:262144`（256KB，超限返回明确 `GOV_INPUT_TOO_LARGE`
  错误）——保证只有授权的受限子集进入容器。
- **Job 生命周期**（仿 `DataSandboxMvpService.startKuscia` + `ModelExportServiceImpl`）：
  `jobId = "gov-" + taskId`（taskId 本身含短 id，天然唯一）、`taskId=jobId+"-task"`、alias=`governance`、
  party domainId=nodeId role=server、`JobResource{cpu,memory}`（env `SECRETPAD_DATA_SANDBOX_GOVERNANCE_CPU/MEMORY`，
  默认 0.5/512Mi）、`max_parallelism=1`、`task_input_config=<上述 JSON>`、custom_fields 记
  `task_id/network_policy=GOVERNANCE`。
- **提交**：任务 PENDING→RUNNING → `createJob`（已存在同 jobId → 重建或 restartJob 幂等）。
- **轮询取回**：`@Scheduled` 10s（条件 UPDATE RUNNING→RUNNING 认领，仿 Z-03 认领模式）`queryJob`：
  - Succeeded → `extractEndpoint`（portName=`sampler`、scope=Cluster，复用 `syncKusciaStatuses` 的
    `extractEndpoint` 逻辑）→ 平台经 `secretpad.gateway`（:80，Host 头 = endpoint）GET `/result` →
    校验 CSV（表头与预期 schema 一致、行数/大小上限）→ 写 `storeDir+nodeId+"/"+<taskId>-<shortId>.csv` →
    注册 DomainData（同 Stage 1）→ 回填 → RUNNING→SUCCEEDED → 血缘。
  - Failed → FAILED + `error_message`（从 queryJob err_msg）+ 告警。
  - **超时**（默认 `SECRETPAD_DATA_SANDBOX_GOVERNANCE_TIMEOUT_SECONDS:300`）→ `stopJob` + FAILED +
    `raiseAlert(dedupe "gov:"+taskId+":timeout")`。
  - **无论成败收尾 `deleteJob`**（先取回后删除，遵守"查询/拉取必须在 deleteJob 之前"）。
- **retry**：FAILED 任务 `retry` → 校验 → 条件 UPDATE FAILED→RUNNING → 重新 buildKusciaParams 提交
  （幂等，retry_count 上限 env `...MAX_RETRIES:3` → 超限拒绝）。
- **隔离声明（E2E 可验证）**：一次性 Job、无卷无密钥、仅 task_input_config 入参、CPU/内存限额、超时 kill、
  跑完即删、`-nonet` 对照无 Cluster 端点。

**Stage 2 测试（secretpad）**：扩展 MockKusciaGrpcServer 的 JobService 桩（静态字段注入 `/status` 桩 CSV
+ 测试内起本地 `HttpServer` 模拟容器输出端口）；`DataGovernanceCustomIT`——成功路径（createJob→Succeeded→
取回→注册）/超时 kill 路径/失败告警路径/retry 幂等/输入超限拒绝。提交：容器代码在 package 仓库、
模板+注册脚本+执行器在后端仓库。

---

## Stage 3 — 数据治理 API

`DataGovernanceController`（`secretpad-web/.../web/controller/DataGovernanceController.java`），
`@RequestMapping("/api/v1alpha1/data-governance")`（独立前缀，与 data-sandbox 拆分）：

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/policies` | 创建策略（同名幂等拒绝） |
| POST | `/policies/update` | 更新策略（仅创建人） |
| POST | `/policies/delete` | 软删策略 |
| GET | `/policies?type&keyword` | 策略列表 |
| GET | `/policies/detail?id=` | 策略详情 |
| POST | `/tasks/submit` | 提交任务（`{policyId 或 内联 execParams, execMode, nodeId, datatableId, scriptContent?}`） |
| GET | `/tasks?status&execMode&keyword` | 任务列表（按创建人） |
| GET | `/tasks/detail?id=` | 详情（含血缘链） |
| POST | `/tasks/cancel` | 取消（PENDING/RUNNING→CANCELLED + stopJob） |
| POST | `/tasks/retry` | 失败重试 |
| GET | `/tasks/results?nodeId` | 结果数据集（status=SUCCEEDED 且 result_datatable_id 非空） |
| POST | `/tasks/mount` | 结果挂载项目（insert `project_datatable` source=CREATED，仿现有授权插入） |
| GET | `/lineage?nodeId&datatableId` | 血缘查询（source 或 target 命中） |
| GET | `/preview?nodeId&datatableId&limit` | 源数据预览（前 N 行 + schema + 行数，**强制权限校验**） |

权限：策略/任务按创建人隔离；preview/submit/mount 走 `checkSourcePermission`。所有写操作 audit +
webhook。错误码：`GOV_NO_PERMISSION`、`GOV_INPUT_TOO_LARGE`、`GOV_NOT_FOUND`、`GOV_STATE_CONFLICT`、
`GOV_PARAM_INVALID`（沿用全局异常体系）。

**Stage 3 测试（secretpad）**：`DataGovernanceControllerTest`（MockMvc + user_tokens 硬删除/重插
ADMIN/BOB/CAROL 三登录 token，照 `DataSandboxControllerTest`）——CRUD/权限拒绝/参数校验/状态冲突/错误码。

---

## Stage 4 — 前端（secretpad-frontend，apps/platform/src）

- `services/data-sandbox.ts`：新增 `governanceBase = '/api/v1alpha1/data-governance'` +
  `governancePolicies/tasks/results/lineage/preview/mount` 等 API（get/post + `responseData` 解包，
  仅依赖已声明字段——OpenAPI 契约）。
- 新模块 `modules/data-governance/index.tsx`（仿 `sandbox-approval` 整页范式：MvpPage → 筛选 Space →
  Table(Tag 着色+操作列) → Modal → Drawer+Timeline）：
  - **Tab 策略管理**：策略列表 + 创建/编辑/删除 Modal（policyType + 抽样方法/参数表单 + 脱敏列配置）。
  - **Tab 任务管理**：任务列表 + 提交 Modal（选源表（nodeId+datatableId，来自 `/preview` 元数据）+
    选策略或内联参数 + 自定义脚本（execMode=CUSTOM）+ 预览前 N 行）、状态 Tag、重试/取消、结果数据集入口、
    任务详情 Drawer（Timeline + 血缘）。
  - **Tab 血缘**：按节点/数据表查询血缘。
- `pages/edge.tsx`：menuItems[] 追加 `{label:'数据治理', icon:<DeploymentUnitOutlined/>, key:'data-governance',
  component:lazy(...)}`。

**Stage 4 收尾**：前端提交（服务封装 + 页面 + 菜单），`pnpm --filter secretpad build` 通过。

---

## Stage 5 — 测试数据集 + develop.sh 挂载修复 + E2E

### 5.1 测试数据集（Z-04 交付物）

- `secretpad-web/src/test/resources/gov/sample_full.csv`（约 200 行）与 `gov/sample_small.csv`（20 行）：
  列 `id,name,phone,id_card,category,amount,score,memo`，含手机号/身份证/金额/类别（A/B/C）/空值/超长
  字符串——供单测/IT 断言抽样计数与脱敏内容。
- 开发种子 `data-sandbox-package/devdata/gov_sample.csv`（同上，供 E2E 上传数据管理）。

### 5.2 develop.sh 挂载修复（只改 zgz 私有脚本）

`data-sandbox-package/develop.sh`：secretpad 容器 `/app/data` 卷源从 `${SECRETPAD_DATA_DIR}`（
`${DEV_ROOT}/secretpad/data`）改为 `${KUSCIA_DATA_DIR}`（`${DEV_ROOT}/kuscia/data`，即 kuscia
`/home/kuscia/var/storage/data` 的同一宿主目录）——对齐官方 `secretpad.sh` 的
`PAD_INSTALL_DIR/KUSCIA_INSTALL_DIR` 同目录关系。迁移兜底：启动脚本内一次性 `cp -rn
${SECRETPAD_DATA_DIR}/ ${KUSCIA_DATA_DIR}/`（带 marker 文件保证幂等），旧上传表在新路径仍可读。
**影响（改进）**：此后 SecretPad 上传/产出的表，dev 的 SecretFlow/Kuscia 同源可读；本计划内置引擎
（写结果到 storeDir）与自定义容器（经挂载数据目录）数据路径一致。**不触碰 xzh/共享环境**。

### 5.3 E2E 清单（`./develop.sh up --branch develop/zgz`，dev 实例 8099/9099/kuscia 24080-24084）

1. 策略 CRUD：创建 SAMPLING/MASKING/SAMPLING_MASKING 策略、编辑、软删、列表。
2. 内置抽样 ×4：RANDOM/SYSTEMATIC/STRATIFIED/CLUSTER 各提交一次，结果行数符合抽样参数（seed 复现）。
3. 内置脱敏 ×5：掩码/替换/哈希/取整/清除各验证结果 CSV 内容（如手机号 `138****1234`、哈希不可逆）。
4. 自定义代码：提交 Python 脚本任务 → 一次性容器拉起 → 经 Cluster 端口取回输出 → 注册结果数据集。
5. 执行隔离：脚本尝试外联失败（无 egress）；pod limits 下发（CPU/内存限额）；故意 sleep 超时 → stopJob
   + FAILED + 告警。
6. 权限：非授权用户/未授权数据表提交被拒；`/preview` 越权被拒。
7. 血缘：成功任务生成 lineage，`/lineage` 查询可见。
8. 审计：`ds_unified_log` 覆盖 submit/success/fail/cancel/retry。
9. 结果挂载项目（source=CREATED）后数据管理页可见、可下载。
10. 挂载修复验证：上传表在 `/app/data` 与 kuscia storage 同源，SecretFlow/DAG 可读。

`./develop.sh down` → 提交推送（secretpad / secretpad-frontend / data-sandbox-package）。

---

## Stage 6 — OpenAPI 契约 + 报告 + CLAUDE.md 同步

1. **OpenAPI 契约**：上述全部端点 request/response JSON + 错误码（`GOV_*`）同步到接口文档；前端仅依赖
   已声明字段。
2. **`claude/plans/Z-04-task-report.md`**：**形式完全参照 `claude/plans/Z-03-task-report.md` 六章结构**：
   - 一、功能完成情况（按 Z-04 5 项需求逐一列完成情况与交付物，含阶段表）
   - 二、测试情况（2.1 后端单元/集成测试表格含例数、2.2 前端构建、2.3 个人实例 E2E 编号清单逐项结果）
   - 三、修复情况（任务内发现并修复的问题，逐条根因+修复+提交）
   - 四、已知环境限制（一次性容器输入大小上限、挂载修复需重传存量表、task_input_config 大小约束、
     kuscia 未启用时自定义代码不可跑等，如实列出）
   - 五、浏览器使用指南（创建策略、提交内置/自定义任务、查看结果与血缘、预览、挂载项目、审计查询）
   - 六、提交记录（develop/zgz 各仓库提交清单）
   - 需要时加"附录"（bash 验证代码块）。
3. 同步更新 `claude/CLAUDE.md` Z-04 进展小节与《数据沙箱系统开发文档.md》涉及的新端点/配置项/进度。

---

## OpenAPI 契约新增（汇总）

- `/api/v1alpha1/data-governance/policies`（CRUD + detail）
- `/api/v1alpha1/data-governance/tasks`（submit/list/detail/cancel/retry/results/mount）
- `/api/v1alpha1/data-governance/lineage`、`/preview`
- 错误码：`GOV_NO_PERMISSION / GOV_INPUT_TOO_LARGE / GOV_NOT_FOUND / GOV_STATE_CONFLICT / GOV_PARAM_INVALID`

## 新增配置（env 前缀 `SECRETPAD_DATA_SANDBOX_GOVERNANCE_*`，relaxed binding 同既有先例）

```yaml
secretpad.data-sandbox.governance:
  input-rows: ${SECRETPAD_DATA_SANDBOX_GOVERNANCE_INPUT_ROWS:5000}
  input-bytes: ${SECRETPAD_DATA_SANDBOX_GOVERNANCE_INPUT_BYTES:262144}
  timeout-seconds: ${SECRETPAD_DATA_SANDBOX_GOVERNANCE_TIMEOUT_SECONDS:300}
  max-retries: ${SECRETPAD_DATA_SANDBOX_GOVERNANCE_MAX_RETRIES:3}
  poll-interval-ms: ${SECRETPAD_DATA_SANDBOX_GOVERNANCE_POLL_INTERVAL:10000}
  cpu: ${SECRETPAD_DATA_SANDBOX_GOVERNANCE_CPU:0.5}
  memory: ${SECRETPAD_DATA_SANDBOX_GOVERNANCE_MEMORY:512Mi}
```

## 风险与依赖

| 风险 | 等级 | 缓解 |
|---|---|---|
| task_input_config 挂载路径在不同 Kuscia 版本不一致 | 中 | 已实证 tee-image 先例（configTemplates+configVolumeMounts 到 /etc/kuscia/）；实现时先真实验证挂载路径，容器端多路径探测兜底 |
| 自定义容器结果取回依赖真实网络 | 中 | 复用 secretpad.gateway Host 头路由（SandboxProxyController .svc 机制）；E2E 用真实 Kuscia 验证 extractEndpoint+取回 |
| 大 CSV base64 内联超限 | 中 | 输入行/字节上限（默认 5000 行/256KB）返回 GOV_INPUT_TOO_LARGE；报告注明平台限制，大文件路径留待 Z-05 数据供给通道 |
| 挂载修复使存量 dev 表路径失效 | 中 | 启动脚本一次性 cp 兜底 + 文档注明可重新上传 |
| 内置引擎依赖真实数据目录存在 | 中 | 复用 DataServiceImpl 路径解析 + canonical 安全校验；测试用独立 sqlite + test 资源 CSV |
| SQLite 并发写锁 | 中 | 条件 UPDATE + affected 判定；各 IT 独立 DB 文件 |
| @Scheduled 不在 test 跑 | 低 | IT 手动调轮询方法（既有先例） |
| 内置方法把全量真实数据读入 JVM | 低 | 仅读权限校验通过的授权表；输出只含策略允许列；全程审计（验收原则"不暴露未授权真实数据"） |
| webhook/告警事件膨胀 | 低 | 新增 `governance.*` 前缀，沿用 events 精确/通配匹配 |

## 收尾（含 Z-04 任务报告要求）

1. **执行第一步**：将本最终版计划原样复制到 `/data/zgz/datasandbox/claude/plans/Z-04-plan.md`。
2. 各阶段完成后分别提交（secretpad / secretpad-frontend / data-sandbox-package），每提交带测试，推送
   develop/zgz；提交信息注明模块/迁移/配置变更。
3. **端到端测试完成并全部通过后，撰写 `/data/zgz/datasandbox/claude/plans/Z-04-task-report.md`，
   形式完全参照 `/data/zgz/datasandbox/claude/plans/Z-03-task-report.md` 六章结构**（功能完成情况 /
   测试情况 / 修复情况 / 已知环境限制 / 浏览器使用指南 / 提交记录，需要时加附录）。
4. 同步更新 `claude/CLAUDE.md` 的 Z-04 进展小节与《数据沙箱系统开发文档.md》。
