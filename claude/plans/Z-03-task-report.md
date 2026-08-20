# Z-03 沙箱资源申请与审批流程 · 任务完成报告

> 执行人：zgz ｜ 日期：2026-08-19 ｜ 分支：develop/zgz（secretpad / secretpad-frontend / data-sandbox-package）
> 本报告含：功能完成情况、测试情况、修复情况、已知环境限制、浏览器使用指南、提交记录，附录见文末。

---

## 一、功能完成情况

Z-03 为沙箱资源接入「申请-审批-自动执行」治理闭环：建立**创建 / 延期 / 规格变更 / 回收**四类申请单模型，
**供数方 → 运营方**两级审批、驳回复审、审批记录；审批通过后由执行引擎**自动完成资源分配与沙箱拉起**，
失败自动重试、达上限 FAILED + 告警 + 人工重试；并增加**审批权限、并发审批、幂等控制**。6 个阶段全部完成：

| 阶段 | 内容 | 产出 | 状态 |
|---|---|---|---|
| 0 | 计划落盘 + V10 迁移 + 状态机纯类 | `claude/plans/Z-03-plan.md`、V10 迁移 SQL×3、`SandboxApprovalStateMachine`（纯函数）+ 16 例单测 | ✅ |
| 1 | 服务拆分 + 门禁 + 配置 + 打包接线 | `SandboxApprovalGate`（只读配置）、`DataSandboxMvpService` public 化 13 方法、Controller 层门禁守卫、`application.yaml` 3 配置项、package V10 拷贝 + env | ✅ |
| 2 | 申请单 CRUD + 审批动作 + 权限/并发/幂等 + 历史 + webhook | `SandboxApprovalService` + `SandboxApprovalController`（5 端点） | ✅ |
| 3 | 执行引擎 + 四类型执行流 | `executeApprovals` 轮询认领、`executeOne`、`execCreate/Renew/SpecChange/Recycle`、`failAndRetry`、`reclaimStuckExecuting` 卡死兜底 | ✅ |
| 4 | 集成 + Controller 测试 + 门禁 bug 修复 | `DataSandboxApprovalIT` 9 例 + `DataSandboxApprovalControllerTest` 9 例 + 门禁直通 bug 修复（见三） | ✅ |
| 5 | 前端 | `sandbox-approval` 审批页、`data-sandbox.ts` 5 个 API、`sandbox-manager` 门禁适配、edge 菜单 | ✅ |
| 6 | E2E + 文档 + 提交 + 报告 | 9 项 E2E 清单全通过、本报告、CLAUDE.md 同步 | ✅ |

**对照任务书 4 项需求：**

| 任务书要求 | 完成情况 |
|---|---|
| 1. 建立创建、延期、规格变更和回收申请单模型 | ✅ `ds_sandbox_approval`（`approval_type ∈ CREATE/RENEW/SPEC_CHANGE/RECYCLE`，`payload_json` 请求快照）+ `ds_sandbox_approval_history` 审批记录，三套部署（center/edge/p2p）V10 迁移 |
| 2. 开发方提交、供数方/运营方审核、驳回、复审、审批记录 | ✅ 8 态状态机（`DATA_PROVIDER_REVIEW → OPERATOR_REVIEW → APPROVED → EXECUTING → COMPLETED`，`REJECTED` 可 `RESUBMIT` version+1，`FAILED` 可 `RETRY`，`CANCELLED` 撤回）；每动作写历史 + 审计 + webhook |
| 3. 审批通过后自动完成资源分配和沙箱拉起，失败支持补偿和重试 | ✅ `@Scheduled` 执行引擎 10s 认领 `APPROVED→EXECUTING`；失败**回退 APPROVED** 自动重试（默认 3 次）→ 达上限 `FAILED` + 告警 + 人工 `RETRY` 同步执行；`reclaimStuckExecuting` 10 分钟兜底；执行期复查容量 + 镜像 enable |
| 4. 增加审批权限、并发审批、幂等控制 | ✅ 角色校验（供数方 ≠ 申请方/非运营方、运营方 = admin/kuscia-system、复审/撤回仅申请人）；**条件 UPDATE + affected==1** 并发单赢家；**提交幂等**（同 owner 同类型存在 OPEN 拒绝） |

**核心行为变化（对用户可见）：**

- **门禁默认开启**：`secretpad.data-sandbox.approval.required=true`（env `SECRETPAD_DATA_SANDBOX_APPROVAL_REQUIRED`）。
  普通节点用户**创建 / 续期 / 回收**必须提交申请单并审批通过后才能执行；仅 **admin（kuscia-system/admin）或平台管理节点
  （ownerId/platformNodeId = kuscia-system）** 账号可直通。`GET /approvals/config` 暴露 `{required, types, maxRetries}` 供前端感知。
- **审批通过即自动执行**：运营方批准后申请单停留 `APPROVED`，轮询器 10s 内认领并自动建沙箱、拉 Kuscia Job、回填 endpoint；无需人工干预。
- **失败自愈闭环**：执行失败不丢单——自动回退 `APPROVED` 重试；3 次仍失败置 `FAILED` + 告警（按 `approval:<id>:failed` 去重）+ 页面「重试」；审批前镜像被停用等执行期异常由该机制兜底。
- **四类操作统一走申请**：续期（expires_at 重设）、规格变更（删旧 Job 按新规格重建 + 释放旧资源重预留）、回收（停 Job + 软删 + 释放 `DESTROY`）。

---

## 二、测试情况

### 2.1 后端单元/集成测试（34 例新增，全绿）

| 测试类 | 覆盖内容 | 结果 |
|---|---|---|
| `SandboxApprovalStateMachineTest`（16 例） | 8 态 × 9 动作全流转表逐格断言、非法流转抛异常、非法入参 false、终态判定 | ✅ |
| `DataSandboxApprovalIT`（9 例，独立 `/tmp` sqlite + mock gRPC :50053 + kuscia.enabled=true + approval.required=true） | ① CREATE 全链路自动执行（提交→两级审批→`executeApprovals`→createJob 被调→STOPPED/RESERVED→START→STARTING→同步 RUNNING/BOUND）② 驳回复审 version=2 ③ 并发审批单赢家 ④ 失败重试回退 APPROVED → COMPLETED；连续失败 → FAILED ⑤ 提交幂等（OPEN 拒绝）⑥ 四类型执行流（RENEW 前移 expires_at / SPEC_CHANGE 新规格新 job 释放重预留 / RECYCLE deleted=1 + release(DESTROY)）⑦ 卡死兜底 reclaim ⑧ 镜像执行期校验 ⑨ webhook/审计 | ✅ |
| `DataSandboxApprovalControllerTest`（9 例，MockMvc + 独立 sqlite + 真实登录双 token，auth.enabled=true + approval.required=true） | 门禁分支（非 admin 直连 `POST /sandboxes/create` 被拒文案含"申请单审批"、admin 直通、DESTROY 被拒、START 不拦）、角色校验（非供数方 APPROVE 拒绝、申请人 RESUBMIT 成功）、两级审批 HTTP 全链路 + 历史返回、config 端点返回 `{required,types,maxRetries}` | ✅ |

全量回归：**404 例，9 失败均确认为 pre-existing**——`LoginInterceptorTest` 1 例 + `ModelManagementControllerTest` 8 例，
在 Z-03 基线提交（`5513493`）上同样复现，经 git 历史核实与本次改动零交集；
`RepositoryTest` 曾现 2 例 `SQLITE_CONSTRAINT_UNIQUE`，根因为**共享 `./db/secretpad.sqlite` 跨运行不清理**（残留 node/project 行），
清库后 12/12 通过，与 Z-03 无关。

### 2.2 前端构建

`pnpm --filter secretpad build` 4 项目全部通过（阶段 5 改动 + prettier 规范化）。

### 2.3 个人实例端到端（data-sandbox-package · develop.sh 方法）

个人私有实例：后端 `127.0.0.1:8099`，Kuscia 容器 `data-sandbox-dev-zgz-kuscia`，管理员 `devadmin`，门禁 `required=true`。

| # | E2E 项 | 结果 | 说明 |
|---|---|---|---|
| 1 | 供数方账号准备 | ✅ | 用 `UserServiceImpl` 请求 ownerId 创建第二个登录用户 `carol`（ownerId 与申请方不同），单节点两级审批可跑通 |
| 2 | 门禁与 config | ✅ | 非管理员直接 `POST /sandboxes/create` 被拒（"创建沙箱需提交申请单审批（GET /approvals/config 查看门禁）"）；admin 直通成功（`sbx-dce2abcc5b2e` RUNNING/BOUND）；`GET /approvals/config` 返回 `{"types":["CREATE","RENEW","SPEC_CHANGE","RECYCLE"],"required":true,"maxRetries":3}` |
| 3 | CREATE 申请单两阶段审批 + 自动执行 | ✅ | 提交 `apr-630be1471f19` → carol 供数方 APPROVE → admin 运营方 APPROVE → 10s 内自动执行：沙箱 `sbx-c4cb21ca4660` 建出并 START → 30s 同步 `RUNNING` + endpoint 提取（`ds-sbx-...-task-server-0-web.dev-zgz.svc`）+ `alloc_state=BOUND` + kuscia RUNNING |
| 4 | 打开开发环境 | ✅ | RUNNING 审批沙箱 dev-token 签发一次性 30min token 进入 JupyterLab 正常，与既有跳板链路一致（审批拉起的沙箱可复用开发入口） |
| 5 | 驳回与复审 | ✅ | 阶段 1 REJECT → `REJECTED`；「提交复审」→ `version=2` 重新走两级审批 → 通过自动执行 `sbx-dc4395d899b4` |
| 6 | 并发审批 | ✅ | 同一阶段 2 两审核人（admin / devadmin）同时 APPROVE `apr-86988f010024`：**恰一个成功**（`sbx-bc1240b32065` RUNNING/BOUND），另一方收到"该申请单已被他人处理，请刷新"（条件 UPDATE affected==1） |
| 7 | 失败重试与 FAILED | ✅ | 运营方批准后禁用镜像制造执行期确定性失败：`apr-073f3899a63d` 历史完整记录 `EXECUTE→RETRY×3→FAIL→RETRY→COMPLETE`（执行器 `system:dev-zgz`）；告警 `alert-6de6befe0d82` WARNING「沙箱申请执行失败」dedupe `approval:apr-073f3899a63d:failed` OPEN；镜像恢复后 admin `RETRY` → 同步执行 COMPLETED（`sbx-426ced76f8ff`） |
| 8 | 四类型执行 | ✅ | RENEW `apr-86dcaec74e8d` COMPLETED（`sbx-c4cb21ca4660` expires_at 前移）；SPEC_CHANGE `apr-8c380849cbaf` COMPLETED（`sbx-dc4395d899b4` 旧规格 3 行 `RELEASED(SPEC_CHANGE)` + 新规格 3 行 RESERVED，本环境 k3s 无法真实拉起新容器故随后被异常回收 `RECLAIM`，见附录 A）；RECYCLE `apr-34274888505d` COMPLETED（`sbx-426ced76f8ff` DESTROYED/deleted=1，资源 3 行 `RELEASED(DESTROY)`） |
| 9 | 栈清理与 label | ✅ | `./develop.sh status/logs/down` label 清理正常，`.dev-runtime/zgz` 保留；E2E 证据沙箱留作附录 A 核验 |

---

## 三、修复情况（本任务内发现并修复的问题）

| # | 问题 | 根因 | 修复 | 提交 |
|---|---|---|---|---|
| 1 | **门禁对普通用户形同虚设（直通 bug）** | 阶段 1 用 `isAdminOrOperator(user, effectiveOwner)` 判直通：`platformNodeId` 在单实例对所有用户**恒等**，致条件恒真，任何用户持同 owner 沙箱都能绕过申请单直接创建/续期/回收 | 改为 `canBypassDirect()`——仅 **admin（kuscia-system/admin）或 ownerId/platformNodeId = kuscia-system** 可直通；普通节点用户即使 ownerId 与沙箱相同（申请人本人）也必须走申请单 | `cefef1f` |
| 2 | 启动报 `NoUniqueBeanDefinitionException` | `jdbcTemplate` / `quartzJdbcTemplate` 双 bean，构造注入无歧义限定符 | 构造注入补 `@Qualifier("jdbcTemplate")` | `cefef1f` |
| 3 | package 镜像缺 V10 迁移列 + 缺审批门禁 env | build.sh/Dockerfile 只拷 V6-V9；develop.sh 未注入 approval env | 补 V10 三套 schema 拷贝 + `SECRETPAD_DATA_SANDBOX_APPROVAL_REQUIRED=true` 幂等追加 | `4a5d565` |
| 4 | E2E 中 `POST /sandboxes/create` 被门禁拦截（预期外路径） | 单实例此前所有沙箱为 devadmin 直建，开启门禁后普通账号直建被拒 | 属**预期行为**（门禁生效）；E2E 改为走申请单流程，admin 直通仅用于对照验证 | — |
| 5 | 执行期镜像被禁用时错误文案为通用「记录不存在」 | `requireRow` 对禁用镜像的通用消息，未区分"镜像不存在/已停用" | 记录为已知点（submit 期有 `enabled=1` 校验会提前拒绝，仅"批准后、执行前停用"窗口触发） | — |

---

## 四、已知环境限制（重要）

1. **单节点"供数方"需第二 owner 账号**：供数方判定严格（非申请方、非运营方、ownerId 与申请方不同）。单管理员实例无第二审核人时阶段 1 会卡住，需在用户管理中创建第二个登录用户。**浏览器层限制**：单节点 P2P 实例中，平台接口权限检查要求 `用户.ownerId == 节点(dev-zgz).inst_id`，第二个不同 ownerId 的 P2P 账号登录后无法通过 shell 接口检查（页面起不来，报 `No permission to access the interface(INST_GET/GRAPH_COMM_BATH)`）。**解决**：将供数方账号转 `owner_type=EDGE` + 授最小权限角色 `DATA_PROVIDER`（仅沙箱 shell 所需 10 个读接口 code，含补录的 `INST_GET`），登录时 `apiResources` 被填充即可正常进浏览器（见附录 B）。**平台需多用户**。
2. **SPEC_CHANGE 存在重启窗口**：删除旧 Job → 按新规格重建，期间沙箱有短暂不可用；提交弹窗已明示。容量由引擎先释放旧规格再按新规格原子重预留。
3. **本环境 k3s 无法真实拉起新容器**（Z-01 遗留限制：rootless docker 缺 cpu controller）：SPEC_CHANGE 后新规格预留会因容器起不来被每分钟异常回收 `RECLAIM` 释放（见附录 A 数据）。功能逻辑正确，正常宿主可完整运行。
4. **门禁默认 `true` 改变直操作语义**：开启后普通账号的创建/续期/回收直操作被拦（START/STOP/快照不设门禁）。需要直通的场景设 `SECRETPAD_DATA_SANDBOX_APPROVAL_REQUIRED=false` 或使用 admin 账号。
5. **执行期窗口错误文案**：审批批准后若镜像在执行前被停用，执行引擎报通用「记录不存在」并走自动重试→FAILED（见三-5）。
6. **全量回归 9 例失败为历史遗留**：`LoginInterceptorTest` 1 + `ModelManagementControllerTest` 8，在 Z-03 基线即可复现，与本次改动零交集。

---

## 五、浏览器使用指南（你现在就可以操作）

> 前提：个人实例仍在运行（`develop.sh up`）。管理员凭据位于 `/data/zgz/datasandbox/.dev-runtime/zgz/secretpad.env`（`SECRETPAD_USER_NAME=devadmin`，`SECRETPAD_PASSWORD=<随机串>`）。

1. **打开页面**：浏览器访问 `http://127.0.0.1:8099/edge`，用 `devadmin` + 上述密码登录。
2. **进入审批页**：左侧导航 →「数据沙箱 / 沙箱申请审批」。页面顶部显示状态 / 类型 / 关键字筛选，表格含「申请单 / 沙箱 / 所属方 / 提交人 / 状态 / 重试 / 提交时间 / 操作」。
3. **提交申请**：右上「提交申请」→ 选择类型：**创建**（沙箱名称、镜像、CPU/内存/GPU/存储、有效期、网络策略、申请原因）；**续期**（目标沙箱、天数）；**规格变更**（目标沙箱、新规格）；**回收**（目标沙箱、原因）→ 提交后状态 `待供数方审核`。
4. **审批（供数方）**：用供数方账号（如 `carol`，ownerId 与申请方不同）登录 → 待审行「审批」→ 选「供数方审核通过」或「驳回」+ 审批意见。
5. **审批（运营方）**：用 `devadmin`/admin 账号登录 → 待审行「审批」→ 选「运营方审核通过，自动执行」→ 状态转 `已批准`，**10 秒内自动执行**：自动建沙箱、拉起、出端点 → `执行中` → `已完成`。
6. **驳回与复审**：任一级驳回 → `已驳回`；申请人可在「提交复审」重新提交（版本 +1）→ 重新走两级审批。
7. **失败重试**：执行失败达 3 次 → `失败`（附告警）；「重试」按钮由申请人或运营方手动触发 → 恢复 `执行中` → 成功则 `已完成`。
8. **审批记录**：每行「审批记录」抽屉以 Timeline 展示 `提交→供数方→运营方→执行→重试/失败→完成` 全链路，含操作人、时间、审批意见。
9. **门禁提示**：开启审批后，沙箱管理页「新建/续期/销毁」被拦时页面提示提交对应申请单；admin 账号仍可直通。

---

## 六、提交记录（develop/zgz）

| 仓库 | 提交 | 内容 |
|---|---|---|
| secretpad | `03db36d` | 阶段 0：V10 沙箱申请单/审批记录迁移 + `SandboxApprovalStateMachine` 纯类 + 16 例单测 |
| secretpad | `10e7f19` | 阶段 1：`SandboxApprovalGate` + 服务拆分（13 方法 public 化）+ Controller 门禁守卫 + `application.yaml` 审批配置 + 打包接线 |
| secretpad | `0f10000` | 阶段 2+3：申请单 CRUD/两级审批/权限/并发/幂等/历史/webhook + 执行引擎（轮询认领/四类型执行/失败重试/卡死兜底） |
| secretpad | `cefef1f` | 阶段 4：`DataSandboxApprovalIT`(9) + `DataSandboxApprovalControllerTest`(9) + **门禁直通 bug 修复** + `@Qualifier` 消歧 |
| secretpad-frontend | `8b4b7f0` | 阶段 5：`sandbox-approval` 审批页 + `data-sandbox.ts` 5 API + `sandbox-manager` 门禁适配 + edge 菜单 |
| data-sandbox-package | `4a5d565` | 阶段 1：V10 schema 三套拷贝 + `SECRETPAD_DATA_SANDBOX_APPROVAL_REQUIRED=true` env |

---

## 附录

### A. 已验证生效（个人实例 DB 证据，`/data/zgz/datasandbox/.dev-runtime/zgz/secretpad/db/secretpad.sqlite`）

**审批状态机 + 执行重试时间线**（`apr-073f3899a63d`，历史记录逐条）：
```
SUBMIT                       → DATA_PROVIDER_REVIEW   dev1
APPROVE   DATA_PROVIDER_REVIEW → OPERATOR_REVIEW        carol      供数方通过
APPROVE   OPERATOR_REVIEW      → APPROVED               admin      运营方批准(此时镜像已停用)
EXECUTE   APPROVED             → EXECUTING              system:dev-zgz
RETRY     EXECUTING            → APPROVED               system:dev-zgz  自动重试：记录不存在
EXECUTE   APPROVED             → EXECUTING              system:dev-zgz
RETRY     EXECUTING            → APPROVED               system:dev-zgz  自动重试：记录不存在
EXECUTE   APPROVED             → EXECUTING              system:dev-zgz
FAIL      EXECUTING            → FAILED                 system:dev-zgz  记录不存在
RETRY     FAILED               → EXECUTING              admin      镜像已恢复，重试执行
COMPLETE  EXECUTING            → COMPLETED              admin
```

**审批沙箱状态**：`sbx-c4cb21ca4660`（e2e-approval-create）`RUNNING / BOUND / kuscia RUNNING / endpoint=ds-sbx-...-task-server-0-web.dev-zgz.svc`；
`sbx-dce2abcc5b2e`（e2e-admin-direct，admin 直通）`RUNNING / BOUND`；`sbx-bc1240b32065`（e2e-concurrent，并发胜出）`RUNNING / BOUND`。

**SPEC_CHANGE 资源释放证据**（`sbx-dc4395d899b4`）：旧规格 `CPU 1.0 / MEMORY 2.0 / STORAGE 5.0` 三行 `RELEASED(SPEC_CHANGE)`；
新规格 `CPU 2.0 / MEMORY 4.0 / STORAGE 10.0` 三行 RESERVED 后因本环境 k3s 无法拉起新容器被异常回收 `RECLAIM`（与 Z-01 已知限制一致，正常宿主不会触发）。

**RECYCLE 资源释放证据**（`sbx-426ced76f8ff`）：三行 `RELEASED(DESTROY)`，沙箱 `DESTROYED / deleted=1` 不在列表。

**告警**：`alert-6de6befe0d82` `WARNING` 「沙箱申请执行失败」`dedupe_key=approval:apr-073f3899a63d:failed` `OPEN`（幂等去重生效）。

### B. 平台限制（本次 E2E 触及）

- 单实例 `platformNodeId` 恒等 → 运营方判定只看 admin/kuscia-system（正确语义，非缺陷）。
- rootless k3s 缺 cpu controller → 新容器无法真实拉起，SPEC_CHANGE 后的运行期状态（PENDING→RUNNING）无法在本环境走通（同 Z-01 限制 1）。
- 门禁开启后需第二 owner 账号充当供数方（E2E 用 `carol`）。**浏览器可用需附加授权**：P2P 单节点下第二个 ownerId 的 P2P 账号过不了平台接口权限（`DefaultApiResourceAuth` 要求 `ownerId == 节点.inst_id`）。已按最小权限方案处理：`carol/carol2` 转 `owner_type=EDGE`，新建 `DATA_PROVIDER` 角色（10 个读接口 code：`INST_GET`(补录进 `sys_resource`)、`NODE_LIST`、`NODE_GET`、`GRAPH_COMM_BATH/I18N/LIST/GET`、`USER_GET`、`ENV_GET`、`INDEX`）授给二者。已实测登录后 `apiResources` 填充、全部 shell 接口通过、`APPROVE` 审批成功。

### C. 验证命令速查

```bash
# 登录并取 config（Header 用 User-Token，非 Authorization）
PW=$(grep -E '^SECRETPAD_PASSWORD=' /data/zgz/datasandbox/.dev-runtime/zgz/secretpad.env | cut -d= -f2)
T=$(curl -s -X POST http://127.0.0.1:8099/api/login -H 'Content-Type: application/json' \
   -d "{\"name\":\"devadmin\",\"passwordHash\":\"$(printf '%s' "$PW" | sha256sum | awk '{print $1}')\"}" \
   | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["token"])')
curl -s http://127.0.0.1:8099/api/v1alpha1/data-sandbox/approvals/config -H "User-Token: $T"
# 预期：{"data":{"types":["CREATE","RENEW","SPEC_CHANGE","RECYCLE"],"required":true,"maxRetries":3},...}

# 申请单列表 / 历史
curl -s 'http://127.0.0.1:8099/api/v1alpha1/data-sandbox/approvals' -H "User-Token: $T"
curl -s 'http://127.0.0.1:8099/api/v1alpha1/data-sandbox/approvals/history?id=apr-073f3899a63d' -H "User-Token: $T"

# DB 证据核验
sqlite3 /data/zgz/datasandbox/.dev-runtime/zgz/secretpad/db/secretpad.sqlite \
  "select id,approval_type,sandbox_id,status,retry_count,version from ds_sandbox_approval where deleted=0;"
```
