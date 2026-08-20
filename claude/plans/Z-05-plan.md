# Z-05「JAR、SQL 与 Python 开发能力」开发计划（zgz）

> 执行前说明：本计划批准后，**执行阶段的第一步**就是把本最终版计划原样写入
> `/data/zgz/datasandbox/claude/plans/Z-05-plan.md` 留存，然后再开始 Stage 0。
> 收尾阶段（Stage 6）要求：**Z-05 开发完毕并测试通过后，参考 `claude/plans/Z-01-task-report.md`
> 的结构编写 `Z-05-task-report.md`**（六章结构，无附录），并同步 CLAUDE.md 与开发文档。

## Context

Z-01~Z-04 已交付真实沙箱运行时、资源隔离、申请审批闭环、抽样脱敏治理。但**计算任务开发能力为零**：
平台无法上传/管理 JAR 制品，无法执行 SQL，无法开发受控 Python 函数。现有能力碎片：
- `data-sandbox-jar` AppImage 只跑镜像内预置的 `/app/app.jar`，**无上传/挂载/版本机制**；
- SQL 只有内部 `JdbcTemplate` CRUD 与 MPC SCQL 图组件，**无 SQL 编辑/执行/调试/预览**；
- Python 只有 JupyterLab 沙箱（交互）与一次性 sampler（脚本，无依赖控制），**无函数注册、无依赖白名单、无受控生态库导入**；
- 无统一任务模型（创建/运行/停止/重试闭环），无制品/版本表。

Z-05 目标（任务书）：
1. JAR 包上传、校验、版本管理、参数配置、调试和运行。
2. SQL 编辑、执行、调试、结果预览和任务保存。
3. Python 函数开发、依赖库白名单和受控生态库导入。
4. 区分开发与生产运行模式，形成任务创建、运行、停止和重试闭环。

交付物：计算任务 API、运行组件、制品管理、版本管理和调试日志。

## 用户已确认决策（必须逐字执行）

1. **SQL 引擎 = 平台内嵌 SQLite（进程内）**：已实证 `org.xerial:sqlite-jdbc:3.42.0.0` 在依赖树
   （`secretpad/pom.xml` L51/198 + `secretpad-persistence/pom.xml` L41），**无需新增依赖**。用独立
   `jdbc:sqlite::memory:` 连接（不动平台 `jdbcTemplate` DataSource），每任务一个连接、用完即关。
2. **JAR 传递 = task_input_config base64**：仿 Z-04 输入子集机制，JAR 原始字节上限默认
   `DEV_JAR_BYTES:48MB`（base64≈64MB），超限报 `DEV_INPUT_TOO_LARGE`；大小上限可配，超限为已知限制。
3. **运行模式 = 统一任务 + runMode 字段**：同一执行器，差异在成功处理——DEV 调试运行（即时返回日志
   +结果预览，不注册结果表）；PROD 正式运行（全审计 + 结果注册 Kuscia DomainData + 血缘 + 可挂载项目 source=CREATED）。
4. **Python 依赖白名单 = 白名单表 + 运行时 import 校验**：平台维护 `ds_dev_dependency` 白名单；
   runner 容器无网络、禁 pip、仅预装白名单包（numpy/pandas）；提交时平台侧 `DevDependencyChecker`
   校验脚本顶层 import（白名单 ∪ 标准库），runner 侧 `builtins.__import__` 守卫兜底。

## 复用基础（已验证，文件路径）

| 组件 | 位置 | 复用方式 |
|---|---|---|
| 一次性 Kuscia Job 执行器（创建/轮询/取回/超时/删除） | `secretpad-web/.../service/governance/GovernanceCustomExecutor.java` | 整体仿写为 `DevJobExecutor`（`fetchOutput/extractEndpoint/effectiveKusciaState/writeResultCsv/registerResultDomainData`） |
| 任务状态机 + 认领 + 重试/取消/权限/挂载/预览 | `secretpad-web/.../service/governance/DataGovernanceService.java` | 仿写 `DataDevService`（`claimTask` 条件 UPDATE、`retryTask`、`checkSourcePermission`、`mountResult` source=CREATED） |
| 跨切面帮助 | `DataSandboxMvpService.auditAs/raiseAlert/dispatchWebhooks/appendRuntimeMeta` | 直接复用 |
| CSV 工具 | `.../service/governance/CsvUtil.java` | 直接复用 |
| 数据访问 | `DataServiceImpl` + `DatatableManager` + `resolveSource`/`readCsv` | 复用路径解析 + canonical 安全校验 |
| 迁移 | `secretpad-web/config/schema/{center,edge,p2p}/V11__data_governance.sql` | 下一个 **V12**，三份一致；package `Dockerfile`/`build.sh` 同步 COPY |
| AppImage 模板+注册脚本（**在 secretpad 仓库**） | `secretpad/scripts/templates/data-sandbox-sampler.yaml` + `scripts/deploy/data-sandbox/register-data-sandbox-sampler-appimages.sh` | 仿建 jar/python runner 模板（+`-nonet`）与注册脚本 |
| 容器侧 runner（**在 data-sandbox-package 仓库**） | `data-sandbox-package/docker/data-sandbox-sampler/sampler_server.py` | 抽公共 `runner_common.py`，jar/python runner 复用；sampler 入口保留 |
| 前端页面范式 | `secretpad-frontend/apps/platform/src/modules/data-governance/index.tsx` | 仿建 `modules/data-dev`；services 加 `DataDevApi`；`pages/edge.tsx` 加菜单 |
| 测试基建 | `DataGovernanceControllerTest` / `DataGovernanceCustomIT` | MockMvc 真登录 + MockKusciaGrpcServer + 本地 HttpServer |

## 阶段划分

| 阶段 | 内容 | 关键产出 |
|---|---|---|
| 0 | 计划落盘 + V12 迁移 + 纯类（DevSqlEngine/DevDependencyChecker/DevJarValidator）与单测 | `claude/plans/Z-05-plan.md`、V12×3+副本、3 纯类 + 3 测试类 |
| 1 | `DataDevService` 核心：制品/版本/依赖 CRUD + SQL 进程内 DEV/PROD 执行 + 权限/审计/挂载/调试日志 | `DataDevService`、`DataDevIT` |
| 2 | runner 镜像 + AppImage 模板（±`-nonet`）+ 注册脚本 + `DevJobExecutor` + 自定义执行 IT | docker/data-sandbox-{jar,python}-runner、runner_common、4 模板、2 注册脚本、`DevJobExecutor`、`DataDevCustomIT` |
| 3 | 计算任务 API | `DataDevController` + 多部分上传 + `DataDevControllerTest` |
| 4 | 前端 | `modules/data-dev/`、`services/data-sandbox.ts` DataDevApi、edge 菜单 |
| 5 | 测试数据集（参考 sample jar + CSV）+ develop.sh E2E | devdata、E2E 清单逐项 |
| 6 | OpenAPI 契约 + **Z-05 任务报告（参考 Z-01 结构）+ 测试收尾** + CLAUDE.md/开发文档同步 | `claude/plans/Z-05-task-report.md`、三仓库提交 |

---

## Stage 0 — 计划落盘 + V12 迁移 + 纯类与单测（先做）

1. 将本计划复制到 `/data/zgz/datasandbox/claude/plans/Z-05-plan.md`。
2. **V12 迁移** `secretpad-web/config/schema/{center,edge,p2p}/V12__data_dev.sql`（风格仿 V11：License 头
   + 注释、varchar PK、`varchar(32)` 时间、`deleted` 软删、`create index if not exists`）：

```sql
-- Z-05 计算任务开发能力：制品管理 + 版本管理 + 任务执行 + 依赖白名单 + 调试日志
-- ds_dev_artifact:     可保存复用的计算制品（JAR/SQL/PYTHON）
-- ds_dev_artifact_version: 制品每次保存/编辑生成新版本（version 自增，不可变）
--   content_text SQL/PYTHON 脚本全文；file_path JAR 相对路径；sha256/size 校验
--   params_schema 参数声明 JSON；default_params 缺省参数；dependency_names PYTHON 依赖名列表
-- ds_dev_task:         每次执行一条记录，params/脚本快照全量可追溯
--   run_mode DEV 调试 | PROD 正式；exec_type JAR/SQL/PYTHON；status PENDING/RUNNING/SUCCEEDED/FAILED/CANCELLED
--   result_preview JSON 调试/前 N 行预览；result_* PROD 注册结果 DomainData
-- ds_dev_dependency:   Python 依赖库白名单（runner 无网络、禁 pip、仅预装白名单包，导入前校验）
-- ds_dev_run_log:      每次尝试（attempt=retry_count）的调试日志全文
create table if not exists ds_dev_artifact (
    id              varchar(64)  primary key,        -- 'da-' + shortId()
    name            varchar(128) not null,
    type            varchar(8)   not null,           -- JAR / SQL / PYTHON
    description     varchar(512) default '',
    latest_version  integer      not null default 0,
    created_by      varchar(64)  not null,
    created_at      varchar(32)  not null,
    updated_at      varchar(32)  not null,
    deleted         integer      not null default 0
);
create index if not exists idx_da_type on ds_dev_artifact(type, deleted);

create table if not exists ds_dev_artifact_version (
    id               varchar(64)  primary key,       -- 'dav-' + shortId()
    artifact_id      varchar(64)  not null,
    version          integer      not null,
    content_text     varchar(65535) default '',
    file_path        varchar(255) default '',
    sha256           varchar(64)  default '',
    size             bigint       default 0,
    params_schema    varchar(4096) default '[]',
    default_params   varchar(2048) default '{}',
    dependency_names varchar(2048) default '[]',
    description      varchar(512) default '',
    created_by       varchar(64)  not null,
    created_at       varchar(32)  not null,
    deleted          integer      not null default 0,
    unique(artifact_id, version)
);
create index if not exists idx_dav_artifact on ds_dev_artifact_version(artifact_id, version);

create table if not exists ds_dev_task (
    id                   varchar(64)  primary key,   -- 'dt-' + shortId()
    name                 varchar(128) not null,
    description          varchar(512) default '',
    artifact_id          varchar(64)  default '',
    version              integer      default 0,
    run_mode             varchar(8)   not null,      -- DEV / PROD
    exec_type            varchar(8)   not null,      -- JAR / SQL / PYTHON
    source_node_id       varchar(64)  not null,
    source_datatable_id  varchar(64)  not null,
    source_relative_uri  varchar(255) default '',
    params               varchar(8192) default '{}',
    content_snapshot     varchar(65535) default '',
    dependency_names     varchar(2048) default '[]',
    status               varchar(16)  not null default 'PENDING',
    result_node_id       varchar(64)  default '',
    result_datatable_id  varchar(64)  default '',
    result_preview       varchar(8192) default '',
    source_rows          bigint       default 0,
    result_rows          bigint       default 0,
    error_message        varchar(2048) default '',
    kuscia_job_id        varchar(128) default '',
    retry_count          integer      not null default 0,
    created_by           varchar(64)  not null,
    created_at           varchar(32)  not null,
    updated_at           varchar(32)  not null default '',
    started_at           varchar(32)  default '',
    finished_at          varchar(32)  default '',
    deleted              integer      not null default 0
);
create index if not exists idx_dt_status on ds_dev_task(status, deleted);
create index if not exists idx_dt_source on ds_dev_task(source_node_id, source_datatable_id, deleted);
create index if not exists idx_dt_artifact on ds_dev_task(artifact_id, version);

create table if not exists ds_dev_dependency (
    id              varchar(64)  primary key,        -- 'dep-' + shortId()
    name            varchar(128) not null,
    version_spec    varchar(64)  default '',
    description     varchar(512) default '',
    enabled         integer      not null default 1,
    created_by      varchar(64)  not null,
    created_at      varchar(32)  not null,
    updated_at      varchar(32)  not null,
    deleted         integer      not null default 0
);
create index if not exists idx_dd_enabled on ds_dev_dependency(enabled, deleted);
-- 预置与 data-sandbox-python-runner 镜像内预装一致的白名单（新条目须同步重镜像）
insert or ignore into ds_dev_dependency(id,name,version_spec,description,enabled,created_by,created_at,updated_at,deleted)
values('dep-numpy','numpy','>=1.24','NumPy 数值计算',1,'system','2026-08-19 00:00:00','2026-08-19 00:00:00',0);
insert or ignore into ds_dev_dependency(id,name,version_spec,description,enabled,created_by,created_at,updated_at,deleted)
values('dep-pandas','pandas','>=2.0','Pandas 数据分析',1,'system','2026-08-19 00:00:00','2026-08-19 00:00:00',0);

create table if not exists ds_dev_run_log (
    id          varchar(64)  primary key,            -- 'dl-' + shortId()
    task_id     varchar(64)  not null,
    attempt     integer      not null default 0,
    log_text    varchar(65535) default '',
    created_at  varchar(32)  not null
);
create index if not exists idx_dl_task on ds_dev_run_log(task_id, attempt);
```

   设计要点：调试日志独立表 `ds_dev_run_log`（按 attempt 保留重试历史，满足交付物「调试日志」）；
   `result_preview` 存任务行（DEV 预览 + PROD 前 N 行）；JAR 存盘（`file_path` 相对路径 + sha256/size），
   提交时读盘 base64（不落库）；`unique(artifact_id, version)` 保证版本不可变。package 副本：
   `data-sandbox-package/build.sh`（COPY schema 段）+ `Dockerfile`（COPY 段）追加 V12 三行（仿 V11）。
3. **纯类 + 单测**（`secretpad-web/.../web/service/dev/`，无 Spring，仿 `CsvUtil` 纯类风格）：
   - `DevSqlEngine`：`execute(csvText, sql, params, maxResultRows, timeoutSeconds)` —— 独立
     `jdbc:sqlite::memory:` 连接 → 列名清洗 + 类型推断（全 long→INTEGER / 全 double→REAL / 其余 TEXT，
     采样 100 行）→ `CREATE TABLE src(...)` → 批量 INSERT → `PRAGMA query_only=ON`（SQLite 自身硬写阻断）
     → 语句门禁（首关键字仅 SELECT/WITH、单语句、禁 PRAGMA/ATTACH/VACUUM/EXPLAIN）→ `setQueryTimeout`
     → 无 LIMIT 则追加 `LIMIT n` → `{{param}}` 字面量插值（单引号加倍）→ `SqlResult(header,rows,sourceRows,resultRows,elapsedMs,logLines)`。
   - `DevDependencyChecker`：`extractImports(script)`（行级正则 `^\s*(import |from )`）+
     `validate(script, enabledWhitelist)`（顶层模块 ∈ 白名单∪标准库，含 `STDLIB` 常驻集合，相对导入拒绝）。
   - `DevJarValidator`：`validate(bytes, maxBytes)` —— ZIP 魔数（PK\x03\x04/05/06/07/08）+ 含
     `META-INF/MANIFEST.MF`（Main-Class 可选，文档注明）+ 大小上限。
   - 单测：`DevSqlEngineTest`、`DevDependencyCheckerTest`、`DevJarValidatorTest`。

**Stage 0 提交（secretpad）**：迁移 + 纯类 + 单测。

---

## Stage 1 — DataDevService 核心（制品/版本/依赖 + SQL 执行 + 任务闭环）

`DataDevService`（`secretpad-web/.../web/service/dev/DataDevService.java`，注入 `jdbcTemplate` +
`ObjectMapper` + `KusciaGrpcClientAdapter` + `DatatableManager` + `NodeRepository` + `DataSandboxMvpService` +
`DevJobExecutor`）。

错误码族 `DEV_*`（仿 `GOV_*`，`IllegalArgumentException` → 全局异常处理）：
`DEV_NO_PERMISSION / DEV_INPUT_TOO_LARGE / DEV_NOT_FOUND / DEV_STATE_CONFLICT / DEV_PARAM_INVALID / DEV_DEPENDENCY_REJECTED`。

- **制品 CRUD**：`createArtifact`（type∈JAR/SQL/PYTHON，同名拒绝）、`updateArtifact`（仅创建人）、
  `deleteArtifact`（软删制品+版本）、`listArtifacts(type,keyword)`、`artifactDetail`（含版本列表）。
- **版本管理**：`createVersion`（SQL/PYTHON 脚本版本，`version = max(version)+1` 自增，`latest_version` 回填）、
  `uploadJarVersion(artifactId, MultipartFile, ...)`（DevJarValidator 校验 + sha256 + 落盘
  `{storeDir}/{nodeId}/dev-artifacts/`）、`deleteVersion`（latest_version 回退）、`listVersions`/`versionDetail`。
  每次编辑生成新版本（不可变版本）。
- **依赖白名单**：`createDependency/updateDependency/deleteDependency/listDependencies(enabled,keyword)`。
- **任务提交** `submitTask`：校验 runMode/execType/源表 → `checkSourcePermission` → 分发：
  - **SQL → 进程内**：脚本 = req.sql 或版本 content_text；读授权 CSV 子集（行/字节上限）→
    `DevSqlEngine.execute` → 落 task → `claimTask` → DEV（同步返回 `result_preview`+`run_log`+SUCCEEDED，不注册结果）
    / PROD（`writeResultCsv` → `registerResultDomainData` → 血缘 → SUCCEEDED，同步）。
  - **JAR → DevJobExecutor**：需 artifactId+version，读盘 JAR base64（超 `DEV_JAR_BYTES` → `DEV_INPUT_TOO_LARGE`）。
  - **PYTHON → DevJobExecutor**：脚本 = req.script 或版本 content_text；`DevDependencyChecker.validate`（白名单
    ∪ 标准库，否则 `DEV_DEPENDENCY_REJECTED`）→ 落 task → `claimTask` → `devJobExecutor.submit(...)`。
- **任务操作**：`listTasks(status,runMode,execType,keyword)`、`taskDetail`（+血缘链 + runLogs 摘要）、
  `cancelTask`（PENDING/RUNNING→CANCELLED，RUNNING 停 Job）、`retryTask`（仅 FAILED，retry_count<maxRetries，
  重校验权限+依赖，重新提交，run_log attempt=新 retry_count）、`previewSource`（权限+前 N 行）、
  `viewResult`（仅创建人+SUCCEEDED，前 100 行）、`runLog(taskId,attempt)`、`mountResult`（PROD 结果挂项目
  source=CREATED）。
- **血缘**：由 `ds_dev_task` 派生（source_node/datatable → result_node/datatable），任务详情返回血缘链。
- **审计/webhook**：`audit("DEV_*")` 写 `ds_unified_log` + `dispatch("dev.*")`（复用 mvp 帮助）。
- 私有帮助仿照 governance：`claimTask`（条件 UPDATE affected==1）、`checkSourcePermission`（复制同款，避免耦合）、
  `resolveSource/readCsv/writeResultCsv/registerResultDomainData/insertLineage`（op_type=JAR/SQL/PYTHON）。

**Stage 1 测试（secretpad）**：`DataDevIT`（@SpringBootTest + test profile + PER_CLASS + SAME_THREAD +
独立 `/tmp/ds-dev-it.sqlite` + MockKusciaGrpcServer + 测试资源 CSV）——SQL DEV（预览+日志，**无** DomainData/
血缘）、SQL PROD（注册+血缘+挂载）、制品 CRUD + 版本自增、JAR 上传校验、PYTHON 依赖拒绝、权限拒绝、状态冲突
（取消已成功/重试非失败/挂载无结果）。

---

## Stage 2 — runner 镜像 + AppImage 模板 + DevJobExecutor

### 2.1 容器侧（data-sandbox-package 仓库）
- 抽公共库 `docker/data-sandbox-runner-lib/runner_common.py`：`load_config`（双重 JSON 解析）、
  `decode_payload`、`write_inputs`、`run_subprocess(cmd,timeout,log_path)`、`ResultHandler`（`/status /result /log`）、
  `serve(port_env, default_port)`。`sampler_server.py` 改为委托 runner_common（行为保留，Z-04 E2E 回归防护；
  高险时退回复制方案）。
- `docker/data-sandbox-jar-runner/`（`FROM eclipse-temurin:17-jre`）`jar_runner.py`：读
  `/etc/kuscia/jar-conf.json` → payload `{jar_b64, params, input_csv_b64}` → 写 `/app/app.jar` + input.csv +
  params.json → `java -jar /app/app.jar --input ... --output ... --params ...`（env `DS_INPUT_CSV/DS_OUTPUT_CSV/
  DS_PARAMS_JSON` 同步注入）+ subprocess 超时 → 兜底取 stdout 为结果 CSV → serve 8000（`KUSCIA_PORT_JAR_NUMBER`）。
  **JAR 运行契约（UI tooltip + 说明书注明）**：CLI 程序把结果 CSV 写 `--output` 或 stdout；长驻服务超时 kill → FAILED。
- `docker/data-sandbox-python-runner/`（`FROM python:3.11-slim` + `pip install numpy pandas`）`python_runner.py`：
  读 `/etc/kuscia/py-conf.json` → payload `{script, params, input_csv_b64, allowed_imports}` → 给 script.py 前置
  **import 守卫 prologue**（`builtins.__import__` 包裹，顶层模块 ∈ allowed_imports ∪ `sys.stdlib_module_names`，
  否则 `ImportError("dependency not allowed: <top>")`）→ `python script.py --input ... --output ... --params ...`
  + 超时 → serve 8000（`KUSCIA_PORT_PY_NUMBER`）。硬保证：无网络（network_policy + 仅结果 Cluster 端口）、
  无 pip、仅预装白名单包 → 即使守卫被绕过也无法 import 非白名单三方包。
- **容器 smoke test**：本机 `docker build` + 手写 conf 运行，断言 `/result` 返回预期 CSV、import guard 拒 requests。

### 2.2 AppImage 模板 + 注册脚本（secretpad 仓库）
- `scripts/templates/data-sandbox-jar-runner.yaml`（+`-nonet` 无 Cluster 端口对照）：`configTemplates.jarConf`
  `{"task_input_config":"{{.TASK_INPUT_CONFIG}}"}` + `configVolumeMounts` 挂 `/etc/kuscia/jar-conf.json`
  （subPath jarConf）、命令 `python /app/jar_runner.py --config /etc/kuscia/jar-conf.json`、端口
  `name: jar, port: 8000, scope: Cluster`、tcp 探针、`restartPolicy: Never`。
- `scripts/templates/data-sandbox-python-runner.yaml`（+`-nonet`）：同构，`pyConf`/`py` 端口。
- `scripts/deploy/data-sandbox/register-data-sandbox-jar-runner-appimages.sh` +
  `register-data-sandbox-python-runner-appimages.sh`（仿 sampler 注册脚本：sed 渲染 + docker cp + kubectl
  apply，幂等；env `DATA_SANDBOX_JAR_RUNNER_IMAGE`/`DATA_SANDBOX_PYTHON_RUNNER_IMAGE` 默认
  `data-sandbox-jar-runner:latest`/`data-sandbox-python-runner:latest`）。

### 2.3 `DevJobExecutor`（secretpad-web，仿 `GovernanceCustomExecutor`）
- `submit(taskId, nodeId, inputB64, execType, jarB64OrScript, params, allowedImports, appImage)`：payload
  `{jar_b64|script, params, input_csv_b64, allowed_imports}` → 一次性 Job `"dt-"+taskId`，AppImage 按 execType
  选 jar/python-runner，resources cpu=0.5/memory=512Mi（可配），custom fields `{task_id, network_policy=GOVERNANCE}`；
  写 `ds_dev_task.kuscia_job_id`。
- `@Scheduled(fixedDelayString="${secretpad.data-sandbox.dev.poll-interval-ms:10000}")` `pollDevTasks()`：
  选 RUNNING + kuscia_job_id≠'' 行 → `queryJob` → `effectiveKusciaState`：
  - SUCCEED → `finalizeSuccess`（**PROD**：`writeResultCsv` → `registerResultDomainData`（名 `dev-<taskId>`）→
    `result_preview`（前 `result-preview-rows`）→ `insertLineage` → audit `DEV_TASK_SUCCEEDED`；**DEV**：仅存
    `result_preview`+`result_rows`+audit `DEV_TASK_DEBUG_SUCCEEDED`，不注册结果）→ `delete(jobId)`。
  - FAIL → `fail` + `delete`；超时（`DEV_TIMEOUT_SECONDS:300`）→ `stop` + `fail` + 告警
    （dedupe `dev:<taskId>:failed|timeout`）。
  - 复用：`fetchOutput`（gateway Host 头路由 `.svc`）、`extractEndpoint`（按 execType 端口）、`delete`。
- 成功路径写 `ds_dev_run_log`（attempt=retry_count，容器 `/log`）。

**Stage 2 提交（secretpad + data-sandbox-package）**：`DevJobExecutor` + 4 模板 + 2 注册脚本 +
`DataDevCustomIT`（MockKusciaGrpcServer 端口 50055 + 本地 HttpServer：JAR/PYTHON payload 形状、DEV 只预览、
PROD 注册+血缘、RUNNING 就绪取回、超时 kill、createJob 失败、Job Failed、retry 成功 attempt=1）；
容器镜像在 package 仓库。

---

## Stage 3 — 计算任务 API

`DataDevController`（`secretpad-web/.../web/controller/DataDevController.java`），
`@RequestMapping("/api/v1alpha1/data-dev")`，`SecretPadResponse<T>` + `@Operation`。

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/artifacts` | 创建制品（同名幂等拒绝） |
| POST | `/artifacts/update` | 更新（仅创建人） |
| POST | `/artifacts/delete` | 软删制品+版本 |
| GET | `/artifacts?type&keyword` | 制品列表 |
| GET | `/artifacts/detail?id=` | 制品详情（含版本列表） |
| POST | `/artifacts/versions` | 新增 SQL/PYTHON 脚本版本（版本自增） |
| POST | `/artifacts/versions/upload` | JAR 多部分上传（file + artifactId + 参数 schema/default params） |
| POST | `/artifacts/versions/delete` | 删版本 |
| GET | `/artifacts/versions?artifactId=` / `versions/detail?versionId=` / `versions/download?versionId=` | 版本列表/详情/JAR 下载 |
| POST | `/tasks/submit` | 提交任务（runMode/execType/源表/参数/脚本/制品引用） |
| GET | `/tasks?status&runMode&execType&keyword` | 任务列表 |
| GET | `/tasks/detail?id=` | 详情（+血缘链 + runLogs） |
| POST | `/tasks/cancel` / `/tasks/retry` | 取消/重试 |
| GET | `/tasks/preview-source?nodeId&datatableId&limit` | 源数据预览（强制权限） |
| GET | `/tasks/results/view?taskId=` | PROD 结果前 100 行（仅创建人+SUCCEEDED） |
| GET | `/tasks/log?taskId&attempt` | 调试日志全文 |
| POST | `/tasks/mount` | PROD 结果挂项目（source=CREATED） |
| GET | `/dependencies?enabled&keyword` | 白名单列表 |
| POST | `/dependencies` / `dependencies/update` / `dependencies/delete` | 白名单 CRUD |

权限：制品/任务/依赖按创建人隔离；preview/submit/mount 走 `checkSourcePermission`；viewResult/runLog/mount
限创建人。所有写操作 audit + webhook。错误码 `DEV_*`。

**Stage 3 测试（secretpad）**：`DataDevControllerTest`（MockMvc + user_tokens 硬删/重插 ADMIN/ALICE/CAROL，
端口 50056）——CRUD/权限拒绝/参数校验/状态冲突/错误码/JAR 上传大小与类型拒绝/预览/结果/日志/挂载。

---

## Stage 4 — 前端（secretpad-frontend，apps/platform/src）

- `services/data-sandbox.ts`：新增 `DataDevApi`（own `devBase='/api/v1alpha1/data-dev'` + `devGet/devPost`），
  含 `uploadJarVersion(artifactId, file, meta)`（FormData，仿 `services/secretpad/DataController.ts upload()`）。
- 新模块 `modules/data-dev/index.tsx`（仿 `data-governance/index.tsx` 范式：MvpPage → Tabs → Table(Tag 着色+
  操作列) → Modal → Drawer），4 个 Tab：
  1. **制品管理**：制品表（类型 Tag JAR/SQL/PYTHON、latestVersion、创建人）+ 新建/编辑 Modal +
     上传 JAR Modal（`Upload.Dragger` `.jar` + 参数 Schema JSON + 默认参数 JSON）+
     SQL/PYTHON 脚本编辑器 Modal（`Input.TextArea`，PYTHON 可多选白名单依赖）+
     版本列表 Modal（版本行：version/size/sha256/参数/查看/下载 JAR）。
  2. **任务管理**：任务表（状态 Tag/runMode Tag/execType Tag/源→结果行数）+ 提交任务 Modal
     （选制品+版本 或 内联脚本、runMode 单选 DEV/PROD、源节点+源表 ID + 预览前 N 行、参数 JSON、
     「保存任务」= 落制品+版本）+ 操作列（DEV 成功 → **调试日志 Drawer**（runLog + 结果预览表）；
     PROD 成功 → **结果 Drawer**（viewResult 表 + 挂载项目 Modal 用 `listP2PProject`）；RUNNING → 取消；
     FAILED → 重试；详情 Drawer（血缘 Timeline + 脚本快照 + 错误））。
  3. **SQL 工作台**：SQL 编辑器 + 源表选择 + 参数 + 「执行」（DEV 调试 → 结果预览）+「保存为制品」。
  4. **依赖白名单**：依赖 CRUD 表（name/versionSpec/enabled 开关/description/创建人）。
- `pages/edge.tsx`：`menuItems[]` 追加 `{label:'数据开发', icon:<CodeOutlined/>, key:'data-dev', component:lazy(...)}`。

**Stage 4 收尾**：前端提交（`feat(data-dev): ...`，commitlint conventional），`pnpm --filter secretpad build` 通过。

---

## Stage 5 — 测试数据集 + E2E

- 参考 sample JAR（`data-sandbox-package/devdata/`）：提交小型 Java CLI 源码 + 构建产物 jar（读 `--input`
  CSV、按 `--params` 过滤/聚合、写 `--output` CSV），供 E2E 演示 JAR 契约。
- 复用 `gov_bank_sample.csv`（100 行银行数据，已注册 qpfcjppm）作为 JAR/SQL/PYTHON 输入。
- **E2E 清单**（`./develop.sh up --branch develop/zgz`，dev 8099/9099/kuscia 24080-24084）：
  1. JAR 上传+校验（非法文件拒绝）+版本自增 + DEV 调试运行（日志+结果预览，无结果表）+ PROD 运行
     （结果 DomainData 注册+血缘+挂载项目 source=CREATED）。
  2. SQL 编辑→执行→结果预览（DEV）→保存为制品→PROD 运行注册结果+挂载。
  3. Python 函数开发→保存→提交（白名单 numpy/pandas 放行；`import requests` 平台侧 `DEV_DEPENDENCY_REJECTED`；
     runner 侧 import guard 阻断 → FAILED + 日志明确）。
  4. 停止（RUNNING 取消→stopJob）/ 重试（FAILED→成功，retry_count=1，run_log attempt=1）。
  5. 权限：carol 提交未授权表 → `DEV_NO_PERMISSION`；非创建人删制品/重试 → 拒绝。
  6. 审计：`DEV_TASK_SUBMIT/SUCCEEDED/FAILED/CANCEL/RETRY`、`DEV_ARTIFACT_*`、`DEV_DEPENDENCY_*` 写 `ds_unified_log`。
  7. 血缘：PROD SQL/JAR/PYTHON 各任务详情返回 source→target 链。
  8. 隔离：pod limits 0.5CPU/512Mi；`-nonet` 无 Cluster 端点不可取回；取回后 Job 删除。

`./develop.sh down` → 提交推送（secretpad / secretpad-frontend / data-sandbox-package）。

---

## Stage 6 — OpenAPI 契约 + Z-05 任务报告（参考 Z-01 结构）+ CLAUDE.md 同步

1. **OpenAPI 契约**：上述全部端点 request/response JSON + 错误码（`DEV_*`）同步到接口文档；前端仅依赖
   已声明字段。
2. **`claude/plans/Z-05-task-report.md`**：**形式完全参照 `claude/plans/Z-01-task-report.md`**（已通读，
   六章 + 无附录）：
   - 头部 blockquote：`> 执行人：zgz ｜ 日期：… ｜ 分支：develop/zgz（secretpad / secretpad-frontend / data-sandbox-package）` +
     `> 本报告含：功能完成情况、测试情况、修复情况、浏览器使用指南、已知环境限制。`
   - 一、功能完成情况（阶段表 + **核心行为变化（对用户可见）** bullet 列表）
   - 二、测试情况（2.1 后端单元/集成测试表格含例数、2.2 前端构建、2.3 个人实例端到端 # 编号清单逐项结果）
   - 三、修复情况（本任务内发现并修复的问题，表格：问题/根因/修复/提交）
   - 四、已知环境限制（重要）
   - 五、浏览器使用指南（你现在就可以操作）
   - 六、提交记录（develop/zgz，表格：仓库/提交/内容）
   - **无附录**（Z-01 无附录，与 Z-03/Z-04 不同，严格按 Z-01）。
   - 测试顺序：**先完成全部后端/前端测试 + E2E 并逐项记录结果，再撰写报告**。
3. 同步更新 `claude/CLAUDE.md` 的 Z-05 进展小节与《数据沙箱系统开发文档.md》（新端点/配置项/进度）。

---

## 配置（env 前缀 `SECRETPAD_DATA_SANDBOX_DEV_*`，relaxed binding）

```yaml
secretpad.data-sandbox.dev:
  input-rows: ${SECRETPAD_DATA_SANDBOX_DEV_INPUT_ROWS:5000}
  input-bytes: ${SECRETPAD_DATA_SANDBOX_DEV_INPUT_BYTES:262144}
  jar-bytes: ${SECRETPAD_DATA_SANDBOX_DEV_JAR_BYTES:50331648}      # JAR 48MB → base64≈64MB
  timeout-seconds: ${SECRETPAD_DATA_SANDBOX_DEV_TIMEOUT_SECONDS:300}
  max-retries: ${SECRETPAD_DATA_SANDBOX_DEV_MAX_RETRIES:3}
  poll-interval-ms: ${SECRETPAD_DATA_SANDBOX_DEV_POLL_INTERVAL:10000}
  cpu: ${SECRETPAD_DATA_SANDBOX_DEV_CPU:0.5}
  memory: ${SECRETPAD_DATA_SANDBOX_DEV_MEMORY:512Mi}
  jar-app-image: ${SECRETPAD_DATA_SANDBOX_DEV_JAR_APP_IMAGE:data-sandbox-jar-runner}
  python-app-image: ${SECRETPAD_DATA_SANDBOX_DEV_PYTHON_APP_IMAGE:data-sandbox-python-runner}
  sql-limit: ${SECRETPAD_DATA_SANDBOX_DEV_SQL_LIMIT:100}
  sql-timeout-seconds: ${SECRETPAD_DATA_SANDBOX_DEV_SQL_TIMEOUT:30}
  result-preview-rows: ${SECRETPAD_DATA_SANDBOX_DEV_RESULT_PREVIEW_ROWS:50}
```

## 风险与依赖

| 风险 | 等级 | 缓解 |
|---|---|---|
| task_input_config 大 base64（JAR 48MB→64MB）可能超 Kuscia config 上限 | 中 | `DEV_JAR_BYTES` 可调；报告如实注明；提交前用真实 Kuscia 验证 ~1MB jar 基线；备选共享卷留待后续 |
| 内嵌 SQLite 与平台同进程 | 中 | 独立 `:memory:` 连接 + `PRAGMA query_only=ON` 硬阻断 + 语句门禁（仅 SELECT/WITH 单语句）+ LIMIT + setQueryTimeout 多层防护 |
| runner 镜像需构建导入 + AppImage 注册才可 E2E | 中 | Stage 2 提供构建/注册脚本 + 本机 docker smoke test + 幂等注册 |
| 白名单表与镜像预装包耦合 | 低 | V12 预置 numpy/pandas（与镜像一致）；UI 提示"新条目须重建 runner 镜像" |
| JAR 运行契约（CLI 写 --output / stdout 兜底；长驻超时）与用户预期偏差 | 低 | 契约写 UI tooltip + 说明书；devdata 参考 sample jar 演示 |
| 重构 sampler_server.py 回归 Z-04 | 中 | 保留入口抽公共库 + Z-04 E2E 回归；高险时退回复制方案 |
| 端口/测试端口冲突 | 低 | 只用 8099/9099/24080-24084；mock 端口 50055/50056 |
| DEV 结果预览暴露"真实"输出 | 低 | DEV 面向创建人本人调试（输入已授权、代码自有），viewResult 仍限创建人+SUCCEEDED |
| sqlite-jdbc 3.42.0.0 行为差异 | 低 | DevSqlEngineTest 覆盖关键行为；报告注明版本 |

## 收尾（含 Z-05 任务报告要求）

1. **执行第一步**：将本最终版计划原样复制到 `/data/zgz/datasandbox/claude/plans/Z-05-plan.md`。
2. 各阶段完成后分别提交（secretpad / secretpad-frontend / data-sandbox-package），每提交带测试，推送
   develop/zgz；提交信息注明模块/迁移/配置变更。
3. **端到端测试完成并全部通过后，撰写 `/data/zgz/datasandbox/claude/plans/Z-05-task-report.md`，
   形式完全参照 `/data/zgz/datasandbox/claude/plans/Z-01-task-report.md` 六章结构**（功能完成情况 /
   测试情况 / 修复情况 / 已知环境限制 / 浏览器使用指南 / 提交记录，无附录）。
4. 同步更新 `claude/CLAUDE.md` 的 Z-05 进展小节与《数据沙箱系统开发文档.md》。
