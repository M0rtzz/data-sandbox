# Z-03 沙箱资源申请与审批流程 开发计划（zgz）

> 执行前说明：本计划批准后，**执行阶段的第一步**就是把这份（含用户补充的）最终版计划原样
> 写入 `/data/zgz/datasandbox/claude/plans/Z-03-plan.md` 留存，然后再开始 Stage 0。

## Context

Z-01/Z-02 已交付真实沙箱运行时与资源调度隔离（预占/绑定/释放/异常回收、真实指标、网络隔离、告警）。
但沙箱的**创建、续期、规格、回收仍是直接操作**：`createSandbox` 只做 `ensureQuota + assertCapacity`
就落库（无人工审批环节）、`sandboxAction` 的 RENEW/DESTROY 直接执行、没有"规格变更"能力。
审批先例只有模型审批（`ds_model_approval` 两阶段状态机 `submitModel/approvalAction/approvalHistory`）。

Z-03 目标（任务书）：
1. 建立**创建、延期、规格变更、回收**申请单模型。
2. 实现**开发方提交、供数方/运营方审核、驳回、复审、审批记录**。
3. 审批通过后**自动完成资源分配和沙箱拉起**，失败时支持**补偿和重试**。
4. 增加**审批权限、并发审批、幂等控制**。

交付物：资源申请 API、审批状态机、数据库迁移和流程测试。

**验收原则（CLAUDE.md）**：审批必须**实际控制**后续资源分配/沙箱拉起，不接受仅修改审批状态的实现。

## 用户已确认决策

1. **两级审批**：供数方审核 → 运营方审核 → 已批准（对齐模型审批 MODEL_REVIEW→RESOURCE_REVIEW→APPROVED）；
   任一级驳回 → REJECTED，可 RESUBMIT 复审（version+1）。
2. **身份复用现有体系**：运营方 = kuscia-system/admin 或同 platformNodeId 运维账号（复用
   `requireOwner` 判定 L331-344）；供数方 = 与申请方**不同 ownerId** 的登录用户（非申请方本人、非运营方）。
   不做 RBAC 改造。
3. **配置门禁**：新增 `secretpad.data-sandbox.approval.required`（env `SECRETPAD_DATA_SANDBOX_APPROVAL_REQUIRED`，
   默认 **true**）。开启时四类操作必须走申请单且审批通过才能执行；运营方/admin 直通；关闭时保留直接操作。
   门禁落在 **Controller 层**（不动 Service，避免破坏既有 5 个 DataSandbox IT 与直调）。

## 阶段划分

| 阶段 | 内容 | 关键产出 |
|---|---|---|
| 0 | 计划落盘 + V10 迁移 + 申请单状态机纯类与单测 | `claude/plans/Z-03-plan.md`、V10 SQL×3、`SandboxApprovalStateMachine`+Test |
| 1 | 服务拆分 + 门禁 + 配置 + 打包接线 | `SandboxApprovalGate`、DataSandboxMvpService public 化、Controller 门禁守卫、application.yaml、develop.sh/build.sh |
| 2 | 申请单 CRUD + 审批动作 + 权限/并发/幂等 + 历史 + webhook + config 端点 | `SandboxApprovalService`、`SandboxApprovalController` |
| 3 | 执行引擎（轮询/认领/补偿重试/卡死兜底）+ 四类型执行流 | `executeApprovals/executeOne/execCreate/execRenew/execSpecChange/execRecycle` |
| 4 | 集成 + Controller 测试 | `SandboxApprovalStateMachineTest`、`DataSandboxApprovalIT`、`DataSandboxApprovalControllerTest` |
| 5 | 前端 | `sandbox-approval` 页、`data-sandbox.ts`、sandbox-manager 门禁适配、edge 菜单 |
| 6 | E2E + 文档 + 提交 + 报告 | 9 项 E2E 清单、`claude/plans/Z-03-task-report.md`（仿 Z-01 六章）、CLAUDE.md 同步 |

---

## Stage 0 — 计划落盘 + V10 迁移 + 状态机纯类（先做）

1. 将本计划复制到 `/data/zgz/datasandbox/claude/plans/Z-03-plan.md`。
2. **V10 迁移**，三份内容一致（center/edge/p2p），仿 V6/V9 风格（License 头 + 注释、varchar PK、
   `varchar(32)` 时间、`deleted` 软删、`create index if not exists`）：

```sql
-- approval_type: CREATE 创建 | RENEW 续期 | SPEC_CHANGE 规格变更 | RECYCLE 回收(销毁)
-- status:
--   DATA_PROVIDER_REVIEW 待供数方审核 / OPERATOR_REVIEW 待运营方审核 / APPROVED 已批准(待执行)
--   EXECUTING 执行中(轮询器认领) / COMPLETED 已完成 / REJECTED 已驳回(可RESUBMIT,version+1)
--   FAILED 执行失败(可人工RETRY) / CANCELLED 已撤回
-- payload_json 请求参数快照:
--   CREATE      {name,imageId,networkPolicy,cpuCores,memoryGb,gpuCount,storageGb,validDays,projectId?,reason}
--   RENEW       {days,reason}      SPEC_CHANGE {cpuCores?,memoryGb?,gpuCount?,storageGb?,reason}   RECYCLE {reason}
create table if not exists ds_sandbox_approval (
    id             varchar(64)  primary key,        -- 'apr-' + shortId()
    approval_type  varchar(32)  not null,
    sandbox_id     varchar(64)  not null default '', -- CREATE 执行时回填；变更类提交时填写
    owner_id       varchar(128) not null,            -- 申请方所属节点/owner
    submitter      varchar(128) not null,
    payload_json   varchar(4096) not null default '{}',
    status         varchar(32)  not null,
    current_stage  varchar(32)  not null,
    version        integer      not null default 1,
    executor       varchar(128) default '',          -- 执行引擎认领者
    reviewer       varchar(128) default '',          -- 最近一次审核人
    review_comment varchar(1024) default '',
    last_error     varchar(1024) default '',
    retry_count    integer      not null default 0,
    submitted_at   varchar(32)  not null,
    approved_at    varchar(32)  default '',
    completed_at   varchar(32)  default '',
    created_at     varchar(32)  not null,
    updated_at     varchar(32)  not null,
    deleted        integer      not null default 0
);
create index if not exists idx_ds_sandbox_apr_owner   on ds_sandbox_approval(owner_id, status, deleted);
create index if not exists idx_ds_sandbox_apr_status  on ds_sandbox_approval(status, approval_type, deleted);
create index if not exists idx_ds_sandbox_apr_sandbox on ds_sandbox_approval(sandbox_id, status, deleted);

create table if not exists ds_sandbox_approval_history (
    id          integer primary key autoincrement,
    approval_id varchar(64)  not null,
    action      varchar(32)  not null,  -- SUBMIT/APPROVE/REJECT/RESUBMIT/RETRY/CANCEL/EXECUTE/COMPLETE/FAIL
    from_status varchar(32)  default '',
    to_status   varchar(32)  not null,
    operator    varchar(128) not null,
    comment     varchar(1024) default '',
    created_at  varchar(32)  not null
);
create index if not exists idx_ds_sandbox_apr_his on ds_sandbox_approval_history(approval_id);
```

   路径：`secretpad-web/config/schema/{center,edge,p2p}/V10__sandbox_approval.sql`（另有打包目录
   `secretpad-web/config/schema/` 下副本，与既有 V6-V9 同样处理）。

3. **状态机纯类** `secretpad-web/src/main/java/org/secretflow/secretpad/web/service/sandbox/SandboxApprovalStateMachine.java`
   （仿 `SandboxStatusMachine`，纯函数、无 Spring、可单测）：
   - 枚举 `ApprovalStatus`（上述 8 态）与 `ApprovalAction`（SUBMIT/APPROVE/REJECT/RESUBMIT/CANCEL/RETRY/EXECUTE/COMPLETE/FAIL）。
   - `canTransition(from, action)`、`transition(from, action)`（非法抛明确异常）。
   - 流转表：

| from \ action | APPROVE | REJECT | RESUBMIT | CANCEL | RETRY | EXECUTE | COMPLETE | FAIL |
|---|---|---|---|---|---|---|---|---|
| DATA_PROVIDER_REVIEW | OPERATOR_REVIEW | REJECTED | ✗ | CANCELLED | ✗ | ✗ | ✗ | ✗ |
| OPERATOR_REVIEW | APPROVED | REJECTED | ✗ | CANCELLED | ✗ | ✗ | ✗ | ✗ |
| APPROVED | ✗ | ✗ | ✗ | CANCELLED | ✗ | EXECUTING | ✗ | ✗ |
| EXECUTING | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | COMPLETED | FAILED |
| REJECTED | ✗ | ✗ | DATA_PROVIDER_REVIEW | ✗ | ✗ | ✗ | ✗ | ✗ |
| FAILED | ✗ | ✗ | ✗ | ✗ | EXECUTING | ✗ | ✗ | ✗ |
| COMPLETED / CANCELLED | 终态，任何动作 ✗ | | | | | | | |

   - `isReviewPending(status)`（前两级）。

4. **单测** `.../service/sandbox/SandboxApprovalStateMachineTest.java`：全流转表逐格断言 + 非法流转抛异常 + 非法入参 false。

---

## Stage 1 — 服务拆分 + 门禁 + 配置

### 服务拆分（避免 1570 行单类膨胀 + 无循环依赖）

- **public 化最小方法集**（`DataSandboxMvpService` 仅改访问修饰符 + Javadoc 注明"供 Z-03 审批执行引擎复用"）：
  `auditAs`、`dispatchWebhooks`、`raiseAlert`、`raiseSandboxErrorAlert`、`appendRuntimeMeta`、
  `ensureQuota`、`assertCapacity`、`usage`、`reserveAllocations`、`releaseAllocations`、
  `startKuscia`、`stopKuscia`、`deleteKuscia`（13 个）。不 public：`bindAllocations`/`insertAllocation`/
  `bindGpuLedger`/`releaseGpuLedger`/`createSnapshot`。
- 新建 `SandboxApprovalGate.java`（只读配置 + `UserContext` 静态判定，无服务依赖）：
  `isApprovalRequired()`、`isAdmin()`（kuscia-system/admin）、`isAdminOrOperator(ownerId)`
  （admin 或 `user.platformNodeId==ownerId`，复用 requireOwner 逻辑）、`isDataProvider(approval)`
  （`user.name!=submitter && !isAdminOrOperator && user.ownerId!=approval.owner_id`）。
- 新建 `SandboxApprovalService.java`（注入 `DataSandboxMvpService` + `JdbcTemplate` + `SandboxApprovalGate`，
  单向依赖，无循环）。

### 门禁（Controller 层）

`DataSandboxController` 注入 `SandboxApprovalGate`：
- `POST /sandboxes/create`：`gate.assertDirectCreateAllowed()`——`required && !admin/operator(currentOwner)`
  → 抛明确错误"创建沙箱需提交申请单审批（GET /approvals/config 查看门禁）"。
- `POST /sandboxes/action`：`action in (RENEW, DESTROY)` 且非 admin/operator → 抛"该操作需提交{续期/回收}
  申请单审批"。START/STOP/SNAPSHOT 不设门禁。
- SPEC_CHANGE 无直接操作（仅走申请）。

### 配置

`secretpad-web/config/application.yaml` 的 `secretpad.data-sandbox` 段新增（env 前缀 `SECRETPAD_DATA_SANDBOX_APPROVAL_*`，relaxed binding 同既有先例）：

```yaml
approval:
  required: ${SECRETPAD_DATA_SANDBOX_APPROVAL_REQUIRED:true}
  executor-interval-ms: ${SECRETPAD_DATA_SANDBOX_APPROVAL_EXECUTOR_INTERVAL:10000}
  max-retries: ${SECRETPAD_DATA_SANDBOX_APPROVAL_MAX_RETRIES:3}
```

### 打包接线

- `data-sandbox-package/develop.sh`：`ensure_credentials` 幂等追加 `SECRETPAD_DATA_SANDBOX_APPROVAL_REQUIRED=true`。
- `data-sandbox-package/build.sh`/Dockerfile：补 V10 COPY 到三套 schema 目录（现只拷 V6-V9）。
- `data-sandbox-package` 的 `config/schema/*` 同步 V10（与 Z-02 同模式）。

---

## Stage 2 — 申请单 CRUD + 审批动作 + 权限/并发/幂等 + 历史 + webhook

`SandboxApprovalService` 方法（每动作后写 history + `audit("AUDIT","SANDBOX_APPROVAL_<ACTION>","SANDBOX_APPROVAL",id,comment,true)`
+ `dispatchWebhooks("sandbox.approval.<event>", ...)`）：

- `listApprovals(status, type, keyword)`：`select ... from ds_sandbox_approval where deleted=0`，仿 listApprovals 过滤。
- `approval(id)`：详情 + `approvalHistory(id)`。
- `submit(Map)`：
  - 校验类型 ∈ {CREATE,RENEW,SPEC_CHANGE,RECYCLE}；变更类必填 sandboxId（沙箱存在且 deleted=0）；
    CREATE 校验 imageId 存在且 enabled=1、网络策略合法、规格 >0、validDays∈[1,365]。
  - **提交幂等**：同 owner 同类型（CREATE 按 owner_id；变更类按 sandbox_id）存在
    `status in (DATA_PROVIDER_REVIEW,OPERATOR_REVIEW,APPROVED,EXECUTING)` → 抛"已有同类型申请单处理中，请等待完成或取消"。
  - 插入 `apr-<shortId>`，status/current_stage=`DATA_PROVIDER_REVIEW`，payload_json=请求快照，submitted_at/created_at=now。
  - history(SUBMIT,"","DATA_PROVIDER_REVIEW",reason)。
- `approvalAction(Map)`：action ∈ {APPROVE,REJECT,RESUBMIT,RETRY,CANCEL}，先 `canTransition` 预检 + **角色校验**，再
  **条件 UPDATE**（WHERE 含 from-status），`affected!=1` → 抛"该申请单已被他人处理，请刷新"（并发审批）。
  - 角色：APPROVE/REJECT 阶段1 → `isDataProvider`；阶段2 → `isAdminOrOperator(owner)`；RESUBMIT/CANCEL → 申请人本人
    （`user.name==submitter`）；RETRY → 申请人或运营方。不满足抛 AUTH_FAILED 明确文案。
  - 动作 SQL（节选）：
    - 阶段1 APPROVE：`update ... set status='OPERATOR_REVIEW',current_stage='OPERATOR_REVIEW',reviewer=?,review_comment=?,updated_at=? where id=? and status='DATA_PROVIDER_REVIEW' and deleted=0`
    - 阶段2 APPROVE：`... set status='APPROVED',current_stage='APPROVED',reviewer=?,review_comment=?,approved_at=?,updated_at=? where id=? and status='OPERATOR_REVIEW' and deleted=0`
    - REJECT：`... set status='REJECTED',reviewer=?,review_comment=?,updated_at=? where id=? and status in ('DATA_PROVIDER_REVIEW','OPERATOR_REVIEW') and deleted=0`
    - RESUBMIT：`... set status='DATA_PROVIDER_REVIEW',current_stage='DATA_PROVIDER_REVIEW',version=version+1,reviewer='',review_comment='',updated_at=? where id=? and status='REJECTED' and deleted=0`
    - CANCEL：`... set status='CANCELLED',current_stage='CANCELLED',updated_at=? where id=? and status in ('DATA_PROVIDER_REVIEW','OPERATOR_REVIEW','APPROVED') and deleted=0`
    - RETRY：`... set status='EXECUTING',current_stage='EXECUTING',executor=?,retry_count=0,last_error='',updated_at=? where id=? and status='FAILED' and deleted=0`；成功后**同步**调 `executeOne(id)`（不等轮询）。
  - 阶段2 APPROVE 成功后若门禁开着，申请单留 `APPROVED` 待轮询器认领（10s 内自动执行）。
- `approvalHistory(id)`：`select * from ds_sandbox_approval_history where approval_id=? order by id desc`。
- `approvalConfig()`：`{required, types:[CREATE,RENEW,SPEC_CHANGE,RECYCLE], maxRetries}`。
- 可选：`DataSandboxMvpService.operationOverview()` counts 加 `pendingSandboxApprovals`
  （`status in (DATA_PROVIDER_REVIEW,OPERATOR_REVIEW,APPROVED,EXECUTING)`）。

`SandboxApprovalController.java`（`@RequestMapping("/api/v1alpha1/data-sandbox/approvals")`）：
`GET /approvals?status=&type=&keyword=`、`POST /approvals/submit`、`POST /approvals/action`、
`GET /approvals/history?id=`、`GET /approvals/config`。

---

## Stage 3 — 执行引擎（自动执行 + 补偿重试 + 卡死兜底）

`SandboxApprovalService`：

```java
@Scheduled(fixedDelayString = "${secretpad.data-sandbox.approval.executor-interval-ms:10000}")
public void executeApprovals() {
    // 无论 approval.required 开关如何，已存在的 APPROVED 申请单都必须执行（门禁只拦直接操作）
    for (Map<String,Object> row : jdbc.queryForList(
            "select id from ds_sandbox_approval where status='APPROVED' and deleted=0 order by approved_at asc limit 20")) {
        String id = string(row.get("id"));
        // 认领：只有 status='APPROVED' 可认领，affected==1 才是赢家（并发安全）
        int claimed = jdbc.update("update ds_sandbox_approval set status='EXECUTING',current_stage='EXECUTING',executor=?,updated_at=? "
                + "where id=? and status='APPROVED' and deleted=0", "system:" + nodeId, now(), id);
        if (claimed != 1) continue;
        approvalHistory(id, "EXECUTE", "APPROVED", "EXECUTING", "");
        executeOne(id);
    }
    reclaimStuckExecuting();
}

private void executeOne(String id) {   // 非事务：每步自提交，避免跨 gRPC 长事务
    Map<String,Object> approval = requireApproval(id);
    try {
        switch (string(approval.get("approval_type"))) {
            case "CREATE"      -> execCreate(approval);
            case "RENEW"       -> execRenew(approval);
            case "SPEC_CHANGE" -> execSpecChange(approval);
            case "RECYCLE"     -> execRecycle(approval);
        }
        complete(id, type, sandboxId);
    } catch (Exception e) {
        failAndRetry(id, truncate(e.getMessage(), 900));
    }
}
```

- `complete(id,type,sandboxId)`：`update ... set status='COMPLETED',completed_at=?,last_error='',updated_at=? where id=? and status='EXECUTING'`
  → history(COMPLETE) + audit + webhook(`sandbox.approval.completed`)。
- `failAndRetry(id,error)`：`retry_count+1`；`retry_count >= maxRetries` → 置 `FAILED` + history(FAIL) + audit(false) +
  webhook(`sandbox.approval.failed`) + `raiseAlert("WARNING","SANDBOX","沙箱申请执行失败",...,"approval:"+id+":failed")`；
  否则**回退 APPROVED**（下个轮询周期自动重试，~10s）+ history(RETRY, EXECUTING→APPROVED)。失败回退 APPROVED 而非保持
  EXECUTING，轮询器只认领 APPROVED，天然形成自动重试循环。
- `reclaimStuckExecuting()`：`status='EXECUTING' and updated_at < now-10min`（JVM 崩溃残留）→ retry_count>=max ? FAILED : 回退 APPROVED，
  均写 history + audit。

### 四类型执行流（幂等）

- **CREATE**：
  1. 若 `approval.sandbox_id` 为空 → 执行时重新 `assertCapacity`（提交到批准间容量可能变化）+ 镜像 enable 校验
     → `service.createSandbox(payload + ownerId=approval.owner_id)`（**异步无 UserContext，必须显式传 ownerId**）
     → 回填 `approval.sandbox_id=created.id`。
  2. 若已建过（重试）→ `service.sandbox(sandbox_id)`；deleted/DESTROYED → fail。
  3. 状态 ∈ {RUNNING, STARTING} → complete；∈ {STOPPED, ERROR} → `service.sandboxAction(START)`（置 STARTING + reserve + startKuscia），
     取回后 `ERROR` → fail；沙箱后续由现有 `syncKusciaStatuses` 推进 RUNNING。
  4. complete。
- **RENEW**：`service.sandboxAction(RENEW, days=payload.days)`（幂等：重设 expires_at，EXPIRED→STOPPED）→ complete。
  沙箱 deleted/DESTROYED → complete（无可续）。
- **SPEC_CHANGE**（无直接操作）：`kuscia_job_id` 非空 → `deleteKuscia`（失败 → fail，保留 job id 供重试再删）→
  按 payload 新规格 `update ds_sandbox set cpu_cores=?,memory_gb=?,gpu_count=?,storage_gb=?,kuscia_job_id='',endpoint='',kuscia_job_state='',status='STARTING',intent='START',last_error=''`
  → `releaseAllocations(old,"SPEC_CHANGE")` → 重新取行 → `reserveAllocations(fresh)` → `startKuscia(fresh)`（job id 已清 → createJob 新规格，
  不会走 restartJob）→ 非空 → 沙箱置 ERROR + fail → `appendRuntimeMeta(sandbox_id,{spec_changed:true,prev_job:oldJob})` → complete。
- **RECYCLE**：deleted/DESTROYED → complete（已回收）→ `stopKuscia + deleteKuscia`（幂等，job 空返回 ""）→
  `update ds_sandbox set status='DESTROYED',deleted=1` → `releaseAllocations(sandbox,"DESTROY")` → complete。
- **kuscia 未启用快失败**：`executeOne` 前对需要拉起的类型（CREATE/SPEC_CHANGE）若 `!kusciaEnabled` → 快速 failAndRetry（避免空转 3 次）；
  RENEW/RECYCLE 不依赖运行时。

---

## Stage 4 — 测试

**Stage 0 提交（secretpad）**：`SandboxApprovalStateMachineTest`（纯类全流转表）。

**Stage 4 提交（secretpad）**：
- `DataSandboxApprovalIT.java`（照 `DataSandboxResourceIT`：`@SpringBootTest + @ActiveProfiles("test") + @TestInstance(PER_CLASS)
  + @Execution(SAME_THREAD)`，独立 `/tmp/ds-sandbox-approval-it.sqlite`，`MockKusciaGrpcServer :50053`，`kuscia.enabled=true`，
  `approval.required=true`；**@Scheduled 在 test profile 不运行**，测试手动调 `service.executeApprovals()`）：
  1. CREATE 全链路：提交 → 供数方 APPROVE → 运营方 APPROVE → `executeApprovals` → `createJob` 被调（断言
     `JobService.State.lastCreateJobRequest`）→ 沙箱建出 STOPPED/RESERVED → START → STARTING → `syncKusciaStatuses` → RUNNING/BOUND。
  2. 驳回与复审：阶段1 REJECT → REJECTED；RESUBMIT → version=2 → 复审通过。
  3. 并发审批：两线程同时 APPROVE 阶段2 → 恰一个成功、另一个 affected=0 抛冲突。
  4. 失败重试：`createJobCode` 先非 OK → 回退 APPROVED；再 OK → COMPLETED；连续失败 ≥3 → FAILED。
  5. 提交幂等：同 owner 存在 OPEN CREATE → 重复 submit 抛错；变更类按 sandbox 同理。
  6. 四类型执行流：CREATE/RENEW（expires_at 前移）/SPEC_CHANGE（新规格 + 新 job id + 释放重预留）/RECYCLE（deleted=1 + releaseAllocations(DESTROY)）。
  7. 卡死兜底：人工置 EXECUTING + updated_at 早于 10min → `reclaimStuckExecuting` 回退 APPROVED/FAILED。
- `DataSandboxApprovalControllerTest.java`（照 `DataSandboxControllerTest`：MockMvc + 独立 SQLite + user_tokens 真实登录，
  `auth.enabled=true`，`kuscia.enabled=false`，`approval.required=true`；prep 写 admin/bob 双登录 token 供门禁/角色分支）：
  1. 非审核人 APPROVE → 明确 401/403；申请人 RESUBMIT 成功；历史返回。
  2. 门禁：非管理员 `POST /sandboxes/create` 被拒（文案含"申请单审批"）；admin 直通；`/sandboxes/action {action:DESTROY}` 非管理员被拒；START 不被拒。
  3. `GET /approvals/config` 返回 required/types/maxRetries。
- 回归：`mvn test -pl secretpad-web -am` 全量，确认既有 5 个 DataSandbox IT 不受门禁影响（门禁在 Controller 层，服务直调不变）。

**Stage 5 提交（secretpad-frontend）**：`pnpm --filter secretpad build` 4 项目通过。

---

## Stage 5 — 前端（secretpad-frontend，apps/platform/src）

- `services/data-sandbox.ts` 追加：`approvals(params?)` → GET `/approvals`、`approvalSubmit(data)` → POST `/approvals/submit`、
  `approvalAction(data)` → POST `/approvals/action`、`approvalHistory(id)` → GET `/approvals/history`、`approvalConfig()` → GET `/approvals/config`。
- 新增 `modules/sandbox-approval/index.tsx`（仿 `model-approval/index.tsx` 整页范式）：
  - 状态 Tag：`DATA_PROVIDER_REVIEW 待供数方审核(processing)` / `OPERATOR_REVIEW 待运营方审核(warning)` /
    `APPROVED 已批准(success)` / `EXECUTING 执行中(processing)` / `COMPLETED 已完成(success)` /
    `REJECTED 已驳回(error)` / `FAILED 失败(error)` / `CANCELLED 已撤回(default)`。
  - 提交申请 Modal：类型 Select（CREATE/RENEW/SPEC_CHANGE/RECYCLE）+ 条件字段（CREATE 复刻创建沙箱表单：名称/镜像/规格/有效期/原因；
    RENEW 天数；SPEC_CHANGE 新规格；RECYCLE 原因）。
  - 审批 Modal（`{action:APPROVE|REJECT, comment}`）；FAILED 行「重试」、REJECTED 行「提交复审」、待审/已批未执行行「撤回」（仅申请人可见按钮由后端权限兜底）。
  - Timeline Drawer 展示 history。
- `modules/sandbox-manager/index.tsx`：`useEffect` 读 `approvalConfig()`；`required && 非管理员` 时——创建按钮文案改「申请沙箱」→
  打开申请 Modal（或跳审批页预填）；续期/销毁按钮点击提示"需提交{续期/回收}申请审批"并引导；START/STOP/快照保持直操作。
- `pages/edge.tsx`：新增菜单项「沙箱申请审批」（lazy import，无角色过滤，沿用现状）。

---

## Stage 6 — 端到端验证（先测后提交）

`./develop.sh up --branch develop/zgz`（工作树模式）→ 跑清单 → `./develop.sh down` → 提交推送
（secretpad / secretpad-frontend / data-sandbox-package）→ 更新 CLAUDE.md → 写报告。

E2E 清单（对应交付物，dev 实例 8099）：
1. **供数方账号准备**：用现有用户管理创建第二个登录用户（供数方，ownerId 与申请方不同）→ 单节点两级审批可用
   （若无法提供第二用户，阶段1 由 admin 直通演示，见"风险"）。
2. 门禁：非管理员直接 `POST /sandboxes/create` 被拒（文案明确）；admin/运营方直通成功；`GET /approvals/config` 返回 required=true。
3. 提交 CREATE 申请单 → 供数方审批 → 运营方审批 → 自动执行：沙箱 STOPPED 自动建出 + 自动 START → 30s 同步 RUNNING +
   endpoint 提取 + alloc_state BOUND（createJob 真实调用，kubectl 可见 Job）。
4. 打开开发环境：RUNNING 沙箱 dev-token 进入 JupyterLab 正常（验证审批拉起的沙箱与既有跳板链路一致）。
5. 驳回与复审：阶段1 驳回 → REJECTED；「提交复审」→ version 2 → 复审通过 → 自动执行。
6. 并发审批：两个审核人同时 APPROVE → 一个成功、一个收到"已被他人处理"。
7. 失败重试与 FAILED：临时断 Kuscia（或 mock）使 createJob 失败 → 自动重试 → 恢复后 COMPLETED；或持续失败 3 次 → FAILED + 告警 + 可 RETRY。
8. 四类型执行：RENEW（expires_at +days）、SPEC_CHANGE（新规格下发，`verify-limits.sh` 核对 pod limits 更新 + 新 job）、
   RECYCLE（沙箱软删 + 资源 RELEASED(DESTROY)）。
9. `./develop.sh status/logs/down` label 清理正常、`.dev-runtime/zgz` 保留。

## OpenAPI 契约新增

- `GET /approvals?status=&type=&keyword=`、`POST /approvals/submit`、`POST /approvals/action`
  `GET /approvals/history?id=`、`GET /approvals/config` → `{required, types[], maxRetries}`。
- `POST /sandboxes/create`、`POST /sandboxes/action`（RENEW/DESTROY）在门禁开启且非管理员时返回明确业务错误
  （提示提交申请单），错误码沿用既有全局异常体系。

## 风险与依赖

| 风险 | 等级 | 缓解 |
|---|---|---|
| 审批期间容量/镜像变化 | 中 | 执行时 createSandbox 重新 assertCapacity + 镜像 enable 校验；自动重试 3 次 → FAILED，申请人可取消重提 |
| kuscia 未启用时执行失败 | 高 | CREATE/SPEC_CHANGE 快失败（不空转）；部署必须 `SECRETPAD_DATA_SANDBOX_KUSCIA_ENABLED=true` |
| 门禁对现有 E2E/IT 影响 | 中 | 门禁仅在 Controller 层，Service 直调不变，既有 5 个 IT 不受影响；新 ControllerTest 双 token 覆盖门禁分支 |
| **单节点"供数方"死锁** | 高 | 供数方判定严格（非申请方/非运营方/不同 ownerId），单管理员实例无第二审核人 → 阶段1 卡住。缓解：E2E 创建第二登录用户作供数方；文档注明"需平台多用户"。可选配置 `stage1-admin-fallback`（本期默认关闭，不作为推翻决策的默认行为） |
| SPEC_CHANGE 重启窗口 | 中 | 删除旧 Job 重建新规格有短暂停机；提交弹窗明示；先释放后按新规格重预留，容量由引擎原子占用 |
| 异步执行无 UserContext | 中 | CREATE 执行显式传 `ownerId`；执行期 audit/history 的 actor 记"system:<nodeId>"（引擎身份），提交/审核人由申请单字段保留 |
| EXECUTING 卡死 | 低 | 10 分钟兜底回退 APPROVED/FAILED（reclaim 模式） |
| SQLite 并发写锁 | 中 | 条件 UPDATE + affected 判定；surefire parallel 下各 IT 独立 DB 文件 |
| @Scheduled 不在 test 跑 | 低 | IT 手动调 executeApprovals()（既有先例） |
| webhook 事件膨胀 | 低 | 新增 `sandbox.approval.*`，沿用 events 精确/通配匹配 |
| 门禁默认 true 改变直操作语义 | 中 | 文档 + 报告明确 required=false 可直通；GET /approvals/config 供前端感知 |

## 收尾（含 Z-03 任务报告要求）

1. **执行第一步**：将本最终版计划原样复制到 `/data/zgz/datasandbox/claude/plans/Z-03-plan.md`。
2. 各阶段完成后分别提交（secretpad / secretpad-frontend / data-sandbox-package），每提交带测试，推送 develop/zgz；
   提交信息注明模块/迁移/配置变更。
3. **端到端测试完成并全部通过后，撰写 `/data/zgz/datasandbox/claude/plans/Z-03-task-report.md`，
   形式完全参照 `/data/zgz/datasandbox/claude/plans/Z-01-task-report.md` 的六章结构**：
   - 一、功能完成情况（按 Z-03 4 项需求逐一列完成情况与交付物，含阶段表）
   - 二、测试情况（`2.1 后端单元/集成测试` 表格含例数、`2.2 前端构建`、`2.3 个人实例 E2E` 编号清单逐项结果）
   - 三、修复情况（任务内发现并修复的问题，逐条列根因+修复+提交）
   - 四、已知环境限制（单节点供数方需第二用户、SPEC_CHANGE 重启窗口、kuscia 未启用时执行失败等，如实列出）
   - 五、浏览器使用指南（如何提交申请、两级审批、查看审批记录、重试/复审、门禁提示）
   - 六、提交记录（develop/zgz 各仓库提交清单）
   - 需要时加"附录"（参照 Z-02 报告，可含 bash 验证代码块）。
4. 同步更新 `claude/CLAUDE.md` 的 Z-03 进展小节与《数据沙箱系统开发文档.md》中涉及的新端点/配置项。
