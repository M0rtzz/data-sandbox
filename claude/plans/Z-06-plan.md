# Z-06「模型测试执行与 API 发布」开发计划（zgz）

> 执行前说明：本计划批准后，**执行阶段的第一步**就是把本最终版计划原样写入
> `/data/zgz/datasandbox/claude/plans/Z-06-plan.md` 留存，然后再开始 Stage 0。
> 收尾阶段（Stage 6）要求：**Z-06 开发完毕并测试通过后，参考 `claude/plans/Z-05-task-report.md`
> 的结构编写 `Z-06-task-report.md`**（六章结构，无附录），并同步 CLAUDE.md 与开发文档。

## Context

Z-05 已交付计算制品（JAR/SQL/PYTHON 上传/校验/版本）+ 任务闭环（DEV/PROD 运行）+ 白名单 + 调试日志。
但平台**没有模型层**：现有 V6 的 `ds_model_approval` 是未绑定实际制品的薄表（仅 model_id/model_name 自由文本，
raw JDBC 在 `DataSandboxMvpService.submitModel/approvalAction`），无模型制品/版本绑定、无测试执行、无评估指标、
无受控发布 API；`ds_api_client` 提供凭证模式（sha256 + 常量时间比对）但无按模型绑定、无授权用户、无 IP 白名单、
无有效时间窗口；全仓库无 inference/predict/评估指标代码。

Z-06 目标（任务书）：
1. 将模型审批单与实际模型制品、版本和项目绑定。
2. 支持审批人员配置测试参数、选择测试数据并执行模型。
3. 保存测试日志、输入摘要、输出摘要和评估指标。
4. 实现模型发布 API、调用凭证、授权用户、IP 白名单和有效时间控制。

交付物：模型测试执行服务、审批结果模型、受控模型 API。

## 用户已确认决策（必须逐字执行）

1. **审批单 = 扩展现有 `ds_model_approval` 表**：V13 用 ALTER 加 `artifact_id` / `artifact_version_id` /
   `test_evidence` 列；新建 `ModelApprovalService` 统一管理（含测试门禁），复用现有状态机
   MODEL_REVIEW→RESOURCE_REVIEW→APPROVED→PUBLISHED 与 `ds_model_approval_history`；新流程行
   `model_id = ds_model.id`（`dm-`），与旧流程行（legacy modelId 字符串）并存；旧
   `DataSandboxMvpService.submitModel/approvalAction/assertModelApproved` 保持不变（兼容 legacy ML-serving 路径）。
2. **审批强制测试门禁**：RESOURCE_REVIEW 阶段 APPROVE 前必须 ≥1 次成功的模型测试且已保存评估指标
   （`MODEL_TEST_REQUIRED` 拒绝），形成「注册→测试→审批→发布」闭环。
3. **模型 = Z-05 制品（仅 JAR/PYTHON）+ 版本**：`ds_model` 引用 `ds_dev_artifact` + `ds_dev_artifact_version` +
   `project_id`（SQL 非模型，注册即拒绝）。
4. **测试执行复用 DevJobExecutor / ds_dev_task**：`ds_model_test` 引用 `ds_dev_task`（`channel='model'`），
   由现有 `@Scheduled pollDevTasks` 收尾（日志/结果/血缘）；`ds_model_test` 读取时惰性收官（镜像任务状态 +
   计算摘要/指标）。**API 调用走新增同步 `DevJobExecutor.runAndAwait`**（`channel='api'`，调度器不轮询）。
5. **评估指标 = 平台侧纯 Java**（`ModelMetricsEvaluator`）：预测列（结果 CSV）× 真实列（输入 CSV）按行对齐
   （1:1，不一致即 `MODEL_METRIC_ALIGNMENT` 拒绝）；自动分类/回归：分类→accuracy/macro precision/recall/F1
   （二分类含混淆矩阵计数），回归→MAE/RMSE/R²。

## 复用基础（已验证，文件路径）

| 组件 | 位置 | 复用方式 |
|---|---|---|
| 一次性 Kuscia 执行器（submit/stop/delete/pollDevTasks/finalize 全链路） | `secretpad-web/.../service/dev/DevJobExecutor.java` | 模型测试走异步（channel=model）；invoke 新增同步 `runAndAwait`（循环复用私有 `pollDevTask`） |
| 任务表 + 运行日志 + 结果注册 + 血缘 | `ds_dev_task` / `ds_dev_run_log` / `registerResultDomainData` / `insertLineage` | 测试建 `ds_dev_task` 行（channel=model）+ `DevJobExecutor.submit` |
| 制品/版本 | `ds_dev_artifact` / `ds_dev_artifact_version`（V12） | 模型引用 artifact_id+artifact_version_id；JAR 读盘 base64 / PYTHON 脚本 + 白名单校验 |
| 凭证模式 | `DataSandboxMvpService.createApiClient/authenticateApiClient`（sha256 + `MessageDigest.isEqual` 常量时间 + 一次性展示） | `ds_model_api` 自持 app_id/secret，复用模式 |
| 鉴权拦截 | `LoginInterceptor.preHandle`（dev-proxy 分支先于 `if(!enable)` 的强制校验范式） | invoke 分支同款：`/api/v1alpha1/model-api/invoke` 精确匹配 + X-APP-ID/X-APP-SECRET |
| 审计/webhook/告警 | `DataSandboxMvpService.auditAs/raiseAlert/dispatchWebhooks` | `MODEL_*` 动作直接复用 |
| 迁移 | `secretpad-web/config/schema/{center,edge,p2p}/V12__data_dev.sql` + package `build.sh`/`Dockerfile` COPY 段 | 下一个 **V13**，三份字节一致；package 同步 COPY |
| 审批状态机范式 | `SandboxApprovalStateMachine`（Z-03 纯类）+ 现有 MODEL_STATES | 抽纯类 `ModelApprovalStateMachine` |
| 前端范式 | `modules/data-dev` + `DataDevApi` + `pages/edge.tsx` 菜单 | 仿建 `modules/model-center` + `DataModelApi` |
| 测试基建 | `DataDevIT`/`DataDevCustomIT`/`DataDevControllerTest`（MockKusciaGrpcServer 50055 + 本地 HttpServer + MockMvc 真 token 50056） | 同构 |
| 报告结构 | `claude/plans/Z-05-task-report.md`（六章无附录） | Stage 6 镜像 |

## 阶段划分

| 阶段 | 内容 | 关键产出 |
|---|---|---|
| 0 | 计划落盘 + V13 迁移（ALTER 审批单/ds_dev_task + 新建 ds_model/ds_model_test/ds_model_api）+ 纯类（ModelMetricsEvaluator/ModelApprovalStateMachine/ModelApiGuard/ModelErrors）与单测 | `claude/plans/Z-06-plan.md`、V13×3+打包、4 纯类 + 3 测试类 |
| 1 | `ModelApprovalService`（注册/审批/门禁）+ `ModelTestService`（测试执行/惰性收官/摘要/指标）核心 | 2 服务 + `DataModelIT`（stage-1 切片） |
| 2 | `DevJobExecutor` 同步 invoke + channel/result_uri 接线 | `runAndAwait` + 单测 + DataModelIT invoke 切片 |
| 3 | `ModelApiService` + LoginInterceptor invoke 分支 + 3 控制器 | `ModelApiService`、`ModelController`/`ModelTestController`/`ModelApiController`、`ModelControllerTest` |
| 4 | 前端模型中心（4 Tab） | `modules/model-center`、`DataModelApi`、edge 菜单 |
| 5 | 参考 scorer 模型 + 带标签测试集 + E2E | `devdata/sample-model`、`model_test_labeled.csv`、E2E 清单逐项 |
| 6 | OpenAPI 契约 + **Z-06 任务报告（参考 Z-05 结构）+ 测试收尾** + CLAUDE.md/开发文档同步 | `claude/plans/Z-06-task-report.md`、三仓库提交 |

---

## Stage 0 — 计划落盘 + V13 迁移 + 纯类与单测（先做）

1. 将本计划复制到 `/data/zgz/datasandbox/claude/plans/Z-06-plan.md`。
2. **V13 迁移** `secretpad-web/config/schema/{center,edge,p2p}/V13__model_test.sql`（三份字节一致，风格仿 V12；
   License 头 + 注释 + varchar PK + `varchar(32)` 时间 + `deleted` 软删 + 索引）。要点：

```sql
-- Z-06 模型测试执行与 API 发布：审批单绑定制品/版本 + 测试证据 + 受控模型 API
-- ① 审批单绑定实际模型制品/版本 + 测试证据（与现有 V6 表共存）
alter table ds_model_approval add column artifact_id varchar(64) not null default '';
alter table ds_model_approval add column artifact_version_id varchar(64) not null default '';
alter table ds_model_approval add column test_evidence varchar(4096) not null default ''; -- JSON {testId,metrics,ranAt}
-- ② ds_dev_task 增加执行通道 + 结果文件路径（模型测试/API 调用需持久化结果供指标计算）
alter table ds_dev_task add column channel varchar(16) not null default 'dev';   -- dev/model/api
alter table ds_dev_task add column result_uri varchar(255) default '';

-- ③ 模型注册表：绑定制品+版本+项目（仅 JAR/PYTHON）
create table if not exists ds_model (
    id varchar(64) primary key,                 -- 'dm-' + shortId()
    name varchar(128) not null,
    description varchar(512) default '',
    project_id varchar(128) not null,
    artifact_id varchar(64) not null,
    artifact_version_id varchar(64) not null,
    node_id varchar(64) default '',             -- 执行/调用运行节点（注册时取项目首个节点或创建人平台节点）
    version integer not null default 1,         -- 同项目同制品重注册自增（不加 DB unique，代码判重）
    status varchar(16) not null default 'DRAFT',-- DRAFT/APPROVING/APPROVED/REJECTED/PUBLISHED/OFFLINE
    created_by varchar(128) not null,           -- username
    created_by_owner varchar(128) default '',   -- ownerId（权限回退判定）
    created_at varchar(32) not null,
    updated_at varchar(32) not null,
    approved_at varchar(32) default '',
    published_at varchar(32) default '',
    deleted integer not null default 0
);
create index if not exists idx_dm_project on ds_model(project_id, deleted);
create index if not exists idx_dm_artifact on ds_model(project_id, artifact_id, deleted);
create index if not exists idx_dm_status on ds_model(status, deleted);

-- ④ 模型测试记录：一次执行一行，摘要/指标 JSON 全量可追溯
create table if not exists ds_model_test (
    id varchar(64) primary key,                 -- 'mt-' + shortId()
    model_id varchar(64) not null,
    approval_id varchar(64) default '',         -- 提交审批后绑定当前审批单
    task_id varchar(64) not null,               -- 关联 ds_dev_task（channel='model'）
    run_mode varchar(8) not null default 'DEV', -- DEV/PROD
    exec_type varchar(8) not null,              -- JAR/PYTHON
    source_node_id varchar(64) not null,
    source_datatable_id varchar(64) not null,
    source_relative_uri varchar(255) default '',
    params varchar(8192) default '{}',
    label_column varchar(128) default '',       -- 真实列（输入 CSV）
    prediction_column varchar(128) default '',  -- 预测列（结果 CSV）
    metric_type varchar(16) default 'auto',     -- auto/classification/regression
    status varchar(16) not null default 'RUNNING', -- RUNNING/SUCCEEDED/FAILED/CANCELLED
    input_summary varchar(4096) default '{}',   -- {header,rowCount,columnCount}
    output_summary varchar(4096) default '{}',  -- {header,rowCount,previewRows}
    metrics varchar(4096) default '{}',         -- {metricType,...}
    result_preview varchar(8192) default '',
    error_message varchar(2048) default '',
    created_by varchar(128) not null,
    created_at varchar(32) not null,
    updated_at varchar(32) not null,
    started_at varchar(32) default '',
    finished_at varchar(32) default '',
    deleted integer not null default 0
);
create index if not exists idx_mt_model on ds_model_test(model_id, deleted);
create index if not exists idx_mt_approval on ds_model_test(approval_id, status);

-- ⑤ 受控模型 API：调用凭证 + 授权用户 + IP 白名单 + 有效时间
create table if not exists ds_model_api (
    id varchar(64) primary key,                 -- 'mapi-' + shortId()
    model_id varchar(64) not null,
    name varchar(128) not null,
    description varchar(512) default '',
    status varchar(16) not null default 'ENABLED', -- ENABLED/DISABLED
    app_id varchar(128) not null unique,        -- 'ai-' + shortId()
    secret_hash varchar(128) not null,          -- sha256(secret)
    authorized_users varchar(4096) default '[]',-- JSON 用户名数组（空=仅凭证调用）
    ip_whitelist varchar(4096) default '[]',    -- JSON IP/CIDR 数组（空=任意 IP）
    valid_from varchar(32) default '',
    valid_to varchar(32) default '',
    call_count bigint not null default 0,
    last_called_at varchar(32) default '',
    created_by varchar(128) not null,
    created_at varchar(32) not null,
    updated_at varchar(32) not null,
    deleted integer not null default 0
);
create index if not exists idx_map_model on ds_model_api(model_id, deleted);
```

   package 副本：`data-sandbox-package/build.sh`（仿 V12 COPY 段）+ `Dockerfile`（COPY 段）追加 V13 三行。
3. **纯类 + 单测**（`secretpad-web/.../web/service/`，无 Spring）：
   - `model/ModelErrors.java`：`MODEL_*` 错误码常量。
   - `dev/ModelMetricsEvaluator.java`：静态 `evaluate(labels, predictions, metricType)` —— 行数不一致抛
     `MODEL_METRIC_ALIGNMENT`；分类（accuracy、macro precision/recall/F1、二分类混淆矩阵计数）/ 回归（MAE/RMSE/R²）；
     auto 判定：标签数值型且去重数 > 阈值（默认 20）→ 回归，否则分类。
   - `model/ModelApprovalStateMachine.java`：纯 `next(from, action)` → `{to, stage, versionBump}`（镜像
     SandboxApprovalStateMachine）。
   - `model/ModelApiGuard.java`：纯静态守卫 `enabled`/`validityWindow(now)`/`ipAllowed(ip, list)`（IP/CIDR
     匹配）/`userAllowed(name, users)`。
   - 单测：`ModelMetricsEvaluatorTest`（~12）、`ModelApprovalStateMachineTest`（~10）、`ModelApiGuardTest`（~12）。

**Stage 0 提交（secretpad + data-sandbox-package）**：迁移 + 纯类 + 单测 + 打包接线。

---

## Stage 1 — ModelApprovalService + ModelTestService 核心（注册/审批/测试/门禁）

### 1.1 `model/ModelApprovalService.java`（注入 jdbcTemplate + objectMapper + mvp + ModelTestService + DatatableManager）
- **注册** `registerModel`：校验 artifact 类型 ∈ {JAR,PYTHON}（SQL → `MODEL_PARAM_INVALID`）+ 版本存在 +
  项目存在；`node_id` = 项目首个节点或创建人平台节点；同项目同制品非终结态重注册 → `MODEL_ALREADY_EXISTS`
  （代码判重，非 DB 唯一约束），否则 `version = 上一版+1`；落 `ds_model`（status=DRAFT）。创建人 = actor()，
  `created_by_owner` = 当前用户 ownerId。
- **审批** `submitApproval(modelId, comment)`：DRAFT→APPROVING；写 `ds_model_approval`（model_id=ds_model.id +
  artifact_id/artifact_version_id/project_id 绑定）+ `ds_model_approval_history`（SUBMIT）。
- **审批动作** `approvalAction`：复用 `ModelApprovalStateMachine.next`（APPROVE 分两段 REVIEW/REJECT/RESUBMIT/
  PUBLISH）；**APPROVE→APPROVED 前硬门禁**：`modelTestService.finalizeAllForApproval(approvalId)` 后统计
  `ds_model_test where approval_id=? and status='SUCCEEDED' and metrics not in ('','{}')` ≥1，否则
  `MODEL_TEST_REQUIRED`；写 history + audit `MODEL_APPROVAL_*` + webhook `model.*`。PUBLISH → model PUBLISHED +
  `published_at`。
- **模型** list/detail（+当前审批 + 测试 + API）/update（创建人）/delete（创建人；仅 DRAFT/REJECTED/OFFLINE）。
- **权限**：`checkModelPermission(user, model)` —— 创建人可管；审批动作限 submitter/reviewer。

### 1.2 `model/ModelTestService.java`（注入 DevJobExecutor + mvp + storeDir 路径）
- **测试权限** `checkTestPermission(user, model, approval, nodeId, datatableId)`：角色 = 模型创建人
  **或** 当前审批 reviewer；测试数据集须 ∈ `project_datatable where project_id=model.project_id and
  node_id=? and datatable_id=? and is_deleted=0`（**数据集属于模型项目即可，审批人不必是项目成员**），
  回退 `nodeId==created_by_owner or node.instId==created_by_owner`。审批处于
  MODEL_REVIEW/RESOURCE_REVIEW/APPROVED 才可测试。**这是对 Z-05 owner-only 的明确放宽，报告中注明。**
- **执行** `executeTest`：读取测试数据集 CSV 子集（行/字节上限）→ **直接建 `ds_dev_task` 行**
  （`channel='model'`、exec_type=制品类型、run_mode=DEV|PROD、artifact_id/version、source、params、content_snapshot）
  → 建 `ds_model_test`（RUNNING，approval_id 绑定）→ `devJobExecutor.submit(taskId, nodeId, inputB64, execType,
  jarB64OrScript, params, allowedImports)`；JAR 读盘 base64，PYTHON 过 `DevDependencyChecker.validate`。
- **惰性收官** `finalizeTestIfNeeded(testId)`：读关联 task —— SUCCEEDED 且 test 仍 RUNNING → 条件 UPDATE
  `where id=? and status='RUNNING'`（affected==1 单写者）：镜像状态、读 `ds_dev_task.result_uri` 结果 CSV
  （canonical 路径安全，仿 `readCsv` ~15 行本地实现，不碰 Z-05）、计算 `input_summary`（输入 CSV header/行数列数）+
  `output_summary` + `ModelMetricsEvaluator.evaluate`（label 列←输入 CSV，prediction 列←结果 CSV）→ 写
  `ds_model_test` + 审批 `test_evidence` + audit `MODEL_TEST_SUCCEEDED`/`MODEL_TEST_FAILED`；FAILED 镜像
  error_message。
- `finalizeAllForApproval(approvalId)`：收官该审批下所有 RUNNING 的 test。
- 测试列表/detail（读时收官）/log（经 task_id 查 `ds_dev_run_log`，attempt 支持）/cancel（RUNNING，stop+delete+置
  CANCELLED）/retry（FAILED 且 retry_count<max，重建 task+test，attempt=retry_count）。

### 1.3 `DataModelIT`（stage-1 切片）
注册（JAR/PYTHON 放行、SQL 拒绝、版本自增、重复拒绝）→ 提交审批 → DEV 调试测试（SUCCEEDED+指标+摘要，无结果表）
→ **门禁无测试 → `MODEL_TEST_REQUIRED`** → 有测试 → APPROVED → REJECT/RESUBMIT → PUBLISH。

**Stage 1 提交（secretpad）**：2 服务 + DataModelIT。

---

## Stage 2 — DevJobExecutor 同步 invoke + channel/result_uri 接线

改 `DevJobExecutor.java`（单文件）：
1. **`pollDevTasks` 查询加 `and channel in ('dev','model')`** —— `channel='api'` 的 invoke 任务绝不被调度器
   双收官（否则 runAndAwait 与 poll 并发取结果/删 Job → 重复血缘/webhook）。
2. **`completeSuccess` DEV 分支**：`runMode=PROD || channel in ('model','api')` 时也 `writeResultCsv` +
   写 `result_node_id`+`result_uri`（供指标计算/调用取数）。纯 Z-05 dev 任务行为不变（仅预览，现有断言不受影响）。
3. **新增 `public Map<String,Object> runAndAwait(String taskId)`**：循环读 `ds_dev_task` → 非 RUNNING 即返回
   `{status, header, rows, errorMessage, elapsedMs}`；否则复用私有 `pollDevTask(task)`（它就是幂等收官循环体，
   **不复制 finalize 逻辑**）；死线超时 → `stop+delete+fail`（镜像 cancelTask）。
4. 新增 `submit` 重载支持 `channel` 参数（默认 'dev'，模型测试 'model'，invoke 'api'）。

**Stage 2 测试**：`DevJobExecutorTest` 增 runAndAwait 用例（channel='api' 不被 poll 选中、结果/耗时返回、
DEV result_uri 落盘）+ DataModelIT invoke 切片。

**Stage 2 提交（secretpad）**。

---

## Stage 3 — ModelApiService + LoginInterceptor 分支 + 控制器

### 3.1 `model/ModelApiService.java`
- **CRUD**：`create`（要求 model.status ∈ {APPROVED, PUBLISHED}，一次性生成 `app_id='ai-'+shortId` + 随机
  secret，sha256 存 `secret_hash`，**明文只返回一次**；model → PUBLISHED + `published_at`）、list/detail
  （不回显 secret）、`update`（authorizedUsers/ipWhitelist/validFrom/validTo/status/描述）、`regenerate-secret`
  （新一次性）、enable/disable、delete（软删）。
- **`authenticateInvoke(request, appId, secret)`**（供 LoginInterceptor 调用）：空 → `AUTH_FAILED`；查
  `ds_model_api by app_id and deleted=0`（未找到 → `AUTH_FAILED` + WARN audit）；`MessageDigest.isEqual(sha256(secret),
  secret_hash)` 常量时间比对；`request.setAttribute("modelApiId", id)`；构造 `UserContextDTO`（name=`api:{appId}`，
  ownerType/platformType/platformNodeId 同 interceptor 的 `createTmpUserForPlatformType` 副本）+ `UserContext.setBaseUser`。
- **`invoke`**（凭证或 User-Token 调用者统一走这里）：守卫顺序 = 记录存在 → `ENABLED`（`MODEL_API_DISABLED`）→
  `now ∈ [valid_from, valid_to]`（`MODEL_API_EXPIRED`）→ `RequestUtils.getRemoteHost()` ∈ ip_whitelist
  （非空才校验，`MODEL_API_IP_DENIED`）→ User-Token 调用者 username ∈ authorized_users（非空才校验，
  `MODEL_API_USER_DENIED`）。通过后：请求体 `{rows:[{col:val}], params?}` 建内存 CSV（≤ api.max-rows /
  max-input-bytes，超限 `MODEL_INPUT_TOO_LARGE`）→ 解析制品（JAR 读盘/PYTHON 脚本 + 白名单）→ 建
  `ds_dev_task`（channel='api'，不落结果注册）→ `devJobExecutor.runAndAwait(taskId)` → 返回
  `{header, rows, resultRows, elapsedMs}`；`call_count+1`、`last_called_at`；audit `MODEL_API_INVOKE`
  （含调用方 identity/ip/success）。

### 3.2 LoginInterceptor invoke 分支（精确形状，位于 `preHandle` 的 dev-proxy 块之后、`if(!enable)` 之前 ——
受控凭证校验独立于 `auth.enabled`，与 dev-proxy 同款强制）

```java
if (request.getRequestURI().equals("/api/v1alpha1/model-api/invoke")) {
    String appId  = request.getHeader("X-APP-ID");
    String secret = request.getHeader("X-APP-SECRET");
    if (StringUtils.isNotBlank(appId) || StringUtils.isNotBlank(secret)) {
        modelApiService.authenticateInvoke(request, appId, secret); // 失败抛 AUTH_FAILED
        return true;
    }
    // 无凭证 → 落回 User-Token 流程（授权用户校验在服务层 invoke 内）
}
```
- **精确 `.equals()` 全路径**，不做 `startsWith("/api/v1alpha1/model-api/")` —— admin 端点
  （create/list/detail/update/regenerate/enable/disable/delete）仍走 `processByUserRequest` 的 User-Token；
  现有 data-sandbox `X-Client-Id` 分支（路径前缀不匹配）不受影响。
- `@Resource private ModelApiService modelApiService;`；无循环依赖（ModelApiService→DataSandboxMvpService，
  不反向引用 interceptor）。

### 3.3 控制器（`SecretPadResponse<T>` + `@Operation`，写操作 audit + webhook）
- `controller/ModelController.java` — `@RequestMapping("/api/v1alpha1/models")`：register/list/detail/update/delete +
  approvals submit/list/detail/action/history（注意与 legacy `/api/v1alpha1/model` 单数不冲突）。
- `controller/ModelTestController.java` — `/api/v1alpha1/models/tests`：execute/list/detail/log/cancel/retry。
- `controller/ModelApiController.java` — `/api/v1alpha1/model-api`：create/list/detail/update/regenerate-secret/
  enable/disable/delete/invoke。

**Stage 3 测试**：`ModelControllerTest`（MockMvc 真 token 50056：CRUD/权限拒绝/参数校验/错误码/状态冲突；
invoke 用 X-APP-ID 头与 User-Token 两路）。

**Stage 3 提交（secretpad）**。

---

## Stage 4 — 前端（secretpad-frontend，apps/platform/src）

- `services/data-sandbox.ts`：新增 `DataModelApi`（仿 `DataDevApi`，base `/api/v1alpha1/models` +
  `/api/v1alpha1/model-api`；invoke 支持 header 透传）。
- 新模块 `modules/model-center/index.tsx`（仿 data-dev/data-governance 范式：MvpPage → Tabs → Table → Modal → Drawer），
  4 Tab：
  1. **模型注册**：模型表（名称/类型/版本/项目/状态 Tag）+ 注册 Modal（选项目 + 制品 + 版本 + 描述）+ 详情 Drawer。
  2. **模型审批**：审批表（状态/提交人/审批人/版本）+ 审批 Drawer（模型信息、**测试执行面板**：选测试表 + 参数
     JSON + label/prediction 列 + metric_type → 执行 → 展示指标卡片 + 输入/输出摘要 + 测试日志；门禁提示「通过前需
     一次成功测试」）+ APPROVE/REJECT/RESUBMIT/PUBLISH 操作。
  3. **测试记录**：测试表（状态/runMode/行数/指标摘要）+ 详情（指标卡片、混淆矩阵计数、摘要、日志）。
  4. **API 发布**：API 表（app_id/状态/调用次数/有效时间）+ 发布 Modal（一次性 app_id+secret 展示 + 授权用户多选 +
     IP 白名单 + validFrom/validTo + enable/disable/regenerate-secret）+ **调用测试控制台**（headers + rows 输入 →
     invoke 结果）。
- `pages/edge.tsx`：`menuItems[]` 追加 `{label:'模型中心', icon:<ExperimentOutlined/>, key:'model-center', component:lazy(...)}`
  （data-dev 之后）。

**Stage 4 收尾**：前端提交（`feat(model-center): ...`，commitlint conventional），`pnpm --filter secretpad build` 通过。

---

## Stage 5 — 参考 scorer 模型 + 测试集 + E2E

- `data-sandbox-package/devdata/sample-model/`：参考**行级 scorer** Java CLI（读 `--input` CSV、按 `--params`
  `{featureColumn, weightA, weightB, intercept, mode(classify|regress), threshold}` 计算并输出
  `prediction` 列，**输出行与输入 1:1 对齐**；契约同 `DataDevSample`，供模型测试/调用演示）。
- `devdata/model_test_labeled.csv`：带真实标签列的测试 CSV（如 `score` 数值 + `pass`=`score>=60` 二分类标签，
  100 行），用于有意义的分/回归指标。
- **E2E 清单**（`./develop.sh up --branch develop/zgz`，dev 8099/9099/kuscia 24080-24084，admin devadmin，
  源表 `gov_bank_sample` qpfcjppm；注册 sample-model JAR 为模型）：
  1. 注册 JAR 模型（制品+版本+项目）→ `ds_model` 行；SQL 制品注册被拒。
  2. 提交审批 → MODEL_REVIEW → APPROVE → RESOURCE_REVIEW。
  3. 审批人配置测试（测试表 + 参数 + label/prediction 列 + metric_type=auto）→ RUNNING → SUCCEEDED +
     分类指标（accuracy/precision/recall/F1）+ input/output 摘要 + 审批 `test_evidence` + run log。
  4. 负向：RESOURCE_REVIEW 下先 APPROVE → `MODEL_TEST_REQUIRED`；有测试后 APPROVE → APPROVED。
  5. PUBLISH → PUBLISHED → 创建 API → 一次性 app_id+secret → 配授权用户/IP 白名单/有效时间 → ENABLED。
  6. invoke（X-APP-ID/X-APP-SECRET）→ 预测行 + elapsedMs；`call_count` 递增。
  7. 守卫负向：错 secret / 停用 / 超有效期 / IP 不在白名单 / 未授权用户 → 明确 `MODEL_*` 错误。
  8. regenerate-secret → 旧失效新生效。
  9. PYTHON 模型路径：注册 python scorer（白名单校验）→ 测试 + invoke。
  10. 审计：`MODEL_*` 全动作写 `ds_unified_log`。
  11. 隔离抽查：invoke pod cpu=500m/memory=512Mi、network_policy=GOVERNANCE、取回后 Job 删除（无残留 `dt-*`）。

`./develop.sh down` → 三仓库提交推送。

---

## Stage 6 — OpenAPI 契约 + Z-06 任务报告（参考 Z-05 结构）+ CLAUDE.md/开发文档同步

1. **OpenAPI 契约**：全部端点 request/response JSON + `MODEL_*` 错误码 + invoke 鉴权头（X-APP-ID/X-APP-SECRET）
   + config 前缀同步到接口文档。
2. **`claude/plans/Z-06-task-report.md`**：**形式完全参照 `claude/plans/Z-05-task-report.md`**（六章 + 无附录）：
   - 头部 blockquote：`> 执行人：zgz ｜ 日期：… ｜ 分支：develop/zgz（secretpad / secretpad-frontend / data-sandbox-package）` +
     `> 本报告含：功能完成情况、测试情况、修复情况、浏览器使用指南、已知环境限制。`
   - 一、功能完成情况（阶段表 + **核心行为变化（对用户可见）** bullet）
   - 二、测试情况（2.1 后端单元/集成测试表格含例数、2.2 前端构建、2.3 个人实例端到端 # 编号清单逐项结果）
   - 三、修复情况（本任务内发现并修复的问题表：问题/根因/修复/提交 —— 含 channel 双收官、
     行对齐硬校验、DEV 结果文件增强、审批门禁等）
   - 四、已知环境限制（重要）—— 含**模型测试权限放宽说明**、invoke 执行任意模型代码的固有属性、
     行对齐契约、legacy/新审批单并存说明
   - 五、浏览器使用指南（你现在就可以操作）
   - 六、提交记录（develop/zgz）
   - **无附录**。
   - 测试顺序：**先完成全部后端/前端测试 + E2E 并逐项记录结果，再撰写报告**。
3. 同步更新 `claude/CLAUDE.md` 的 Z-06 进展小节与《数据沙箱系统开发文档.md》（新端点/错误码/配置/进度）。

---

## 端点总表（~25 个）

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/api/v1alpha1/models/register` | 注册模型（JAR/PYTHON 制品+版本+项目；版本自增；重复拒绝） |
| GET | `/models` `/models/detail` | 模型列表/详情（+当前审批+测试+API） |
| POST | `/models/update` `/models/delete` | 更新/删除（创建人） |
| POST | `/models/approvals/submit` | 提交审批（绑定制品+版本+项目 → MODEL_REVIEW，模型→APPROVING） |
| GET | `/models/approvals` `/approvals/detail` `/approvals/history` | 审批列表/详情/历史 |
| POST | `/models/approvals/action` | APPROVE/REJECT/RESUBMIT/PUBLISH（**APPROVE 门禁**） |
| POST | `/models/tests/execute` | 执行模型测试（测试表+参数+label/prediction 列+metric_type） |
| GET | `/models/tests` `/tests/detail` `/tests/log` | 测试列表/详情（惰性收官）/日志 |
| POST | `/models/tests/cancel` `/tests/retry` | 取消/重试 |
| POST | `/api/v1alpha1/model-api/create` | 发布模型为 API（一次性 app_id+secret；要求 APPROVED） |
| GET | `/model-api/list` `/model-api/detail` | API 列表/详情（不回显 secret） |
| POST | `/model-api/update` `/regenerate-secret` `/enable` `/disable` `/delete` | 更新授权/白名单/有效时间/状态；重发密钥；启停；删除 |
| POST | `/model-api/invoke` | 受控调用（X-APP-ID/X-APP-SECRET 或 User-Token；守卫后同步推理） |

错误码 `MODEL_*`（`IllegalArgumentException("MODEL_*: …")` → 全局 UNKNOWN_ERROR，同 DEV_* 约定）：
`MODEL_NO_PERMISSION` `MODEL_NOT_FOUND` `MODEL_STATE_CONFLICT` `MODEL_PARAM_INVALID` `MODEL_INPUT_TOO_LARGE`
`MODEL_DEPENDENCY_REJECTED` `MODEL_ALREADY_EXISTS` `MODEL_TEST_REQUIRED` `MODEL_METRIC_ALIGNMENT`
`MODEL_API_CREDENTIAL_INVALID` `MODEL_API_DISABLED` `MODEL_API_EXPIRED` `MODEL_API_IP_DENIED`
`MODEL_API_USER_DENIED`。

---

## 配置（env 前缀 `SECRETPAD_DATA_SANDBOX_MODEL_*`，relaxed binding）

```yaml
secretpad.data-sandbox.model:
  test:
    input-rows: ${SECRETPAD_DATA_SANDBOX_MODEL_TEST_INPUT_ROWS:5000}
    input-bytes: ${SECRETPAD_DATA_SANDBOX_MODEL_TEST_INPUT_BYTES:262144}
    max-retries: ${SECRETPAD_DATA_SANDBOX_MODEL_TEST_MAX_RETRIES:3}
    result-preview-rows: ${SECRETPAD_DATA_SANDBOX_MODEL_TEST_RESULT_PREVIEW_ROWS:50}
  api:
    max-rows: ${SECRETPAD_DATA_SANDBOX_MODEL_API_MAX_ROWS:1000}
    max-input-bytes: ${SECRETPAD_DATA_SANDBOX_MODEL_API_MAX_INPUT_BYTES:262144}
    timeout-seconds: ${SECRETPAD_DATA_SANDBOX_MODEL_API_TIMEOUT_SECONDS:300}
  metrics:
    classification-distinct-threshold: ${SECRETPAD_DATA_SANDBOX_MODEL_METRICS_CLASSIFICATION_DISTINCT_THRESHOLD:20}
```
测试超时/镜像复用 `secretpad.data-sandbox.dev.timeout-seconds` / `dev.jar-app-image` / `dev.python-app-image`；
测试收官由 `dev.poll-interval-ms` 驱动（channel='model' 在轮询集内）。

---

## 测试矩阵

| 测试类 | 覆盖 |
|---|---|
| `ModelMetricsEvaluatorTest`（~12） | 分类（二分类混淆矩阵计数、accuracy、macro P/R/F1、多分类）、回归（MAE/RMSE/R²）、auto 阈值判定、行数不一致→`MODEL_METRIC_ALIGNMENT`、空→`MODEL_PARAM_INVALID` |
| `ModelApprovalStateMachineTest`（~10） | 全状态流转、REJECT/RESUBMIT version+1、非法流转、门禁位 |
| `ModelApiGuardTest`（~12） | 守卫顺序、CIDR/IP 匹配、空白名单任意、空授权仅凭证、停用/过期/IP/用户拒绝 |
| `DataModelIT`（~15，MockKusciaGrpcServer+本地 HttpServer+SQLite） | 注册/审批/门禁/测试/指标/摘要/发布/API 守卫/invoke（headers+User-Token）/PYTHON 白名单 |
| `ModelControllerTest`（~20，MockMvc 真 token） | 鉴权/CRUD/权限拒绝/错误码/状态冲突/invoke 两路 |
| `DevJobExecutorTest`（+runAndAwait） | runAndAwait 返回+耗时、channel='api' 不被 poll、DEV result_uri 落盘 |
| 前端 | `pnpm --filter secretpad build` |

---

## 风险与依赖

| 风险 | 等级 | 缓解 |
|---|---|---|
| invoke 与调度轮询双收官 | 中 | `ds_dev_task.channel` 列隔离：poll 仅 `channel in ('dev','model')`；`runAndAwait` 复用幂等 `pollDevTask` + 条件 UPDATE 单写者 |
| 指标行对齐 | 高 | `ModelMetricsEvaluator` 硬校验 `labels.size()==predictions.size()` 否则 `MODEL_METRIC_ALIGNMENT`；UI tooltip + 参考 scorer 明示「行级 1:1 对齐契约」；报告注明可加 idColumn 联接键（留后续） |
| DEV 无结果文件 → 无法算指标 | 中 | `ds_dev_task.result_uri` + `completeSuccess` DEV 分支在 `channel in ('model','api')` 或 PROD 时写结果 CSV（纯 Z-05 dev 行为不变） |
| 扩展现有 `ds_model_approval` 影响 legacy | 中 | 仅 ADD COLUMN（向后兼容）；新流程行与旧行并存；旧 DataSandboxMvpService 方法不改；`assertModelApproved` 两路皆通 |
| invoke 执行任意模型代码 | 中 | 复用 Z-05 全套隔离（network_policy=GOVERNANCE、无卷/密钥、CPU/mem 限制、一次性、超时 kill、取回删除）；报告注明固有属性 |
| LoginInterceptor 改动回归 | 中 | 新增分支精确匹配 invoke 全路径，置于 dev-proxy 后；现有 data-sandbox X-Client-Id 分支路径前缀不匹配不受影响；ModelControllerTest 全量回归 |
| 测试权限放宽被误用 | 低 | 仅审批人/创建人可执行 + 数据集必须属于模型项目；门禁要求成功测试；报告注明偏差 |
| 大体积 JAR base64 传递（同 Z-05） | 低 | 复用 `DEV_JAR_BYTES` 上限，报告如实注明 |

---

## 收尾（含 Z-06 任务报告要求）

1. **执行第一步**：将本最终版计划原样复制到 `/data/zgz/datasandbox/claude/plans/Z-06-plan.md`。
2. 各阶段完成后分别提交（secretpad / secretpad-frontend / data-sandbox-package），每提交带测试，推送
   develop/zgz；提交信息注明模块/迁移/配置变更。
3. **端到端测试完成并全部通过后，撰写 `/data/zgz/datasandbox/claude/plans/Z-06-task-report.md`，
   形式完全参照 `/data/zgz/datasandbox/claude/plans/Z-05-task-report.md` 六章结构**（功能完成情况 /
   测试情况 / 修复情况 / 已知环境限制 / 浏览器使用指南 / 提交记录，无附录）。
4. 同步更新 `claude/CLAUDE.md` 的 Z-06 进展小节与《数据沙箱系统开发文档.md》。
