# Z-06 模型测试执行与 API 发布 · 任务完成报告

> 执行人：zgz ｜ 日期：2026-08-20 ｜ 分支：develop/zgz（secretpad / secretpad-frontend / data-sandbox-package）
> 本报告含：功能完成情况、测试情况、修复情况、浏览器使用指南、已知环境限制。

---

## 一、功能完成情况

Z-06 补齐平台"模型层"空白：模型审批单此前是未绑定实际制品的薄表（V6 `ds_model_approval` 仅自由文本 model_id/model_name，
raw JDBC 在 `DataSandboxMvpService.submitModel/approvalAction`），无模型制品/版本绑定、无测试执行、无评估指标、无受控发布
API。Z-06 将审批单与实际模型制品、版本和项目绑定，加入强制测试门禁 + 指标评估 + 受控 API 发布，6 个阶段全部完成：

| 阶段 | 内容 | 产出 | 状态 |
|---|---|---|---|
| 0 | 计划落盘 + V13 迁移 + 纯类 | `claude/plans/Z-06-plan.md`；`V13__model_test.sql` × center/edge/p2p（三份字节一致）+ package 打包接线；`ModelMetricsEvaluator` / `ModelApprovalStateMachine` / `ModelApiGuard` / `ModelErrors` + 3 测试类 | ✅ |
| 1 | `ModelApprovalService` + `ModelTestService` 核心 | 注册/审批门禁/测试执行/惰性收官/输入输出摘要/评估指标 + `DataModelIT` | ✅ |
| 2 | `DevJobExecutor` 同步 invoke + channel/result_uri 接线 | `runAndAwait`（复用幂等 `pollDevTask`）+ `pollDevTasks` 仅轮询 `channel in ('dev','model')` + `completeSuccess` 对 model/api 通道落盘结果 CSV | ✅ |
| 3 | `ModelApiService` + `LoginInterceptor` invoke 分支 + 3 控制器 | 受控 API（凭证/IP/授权/有效时间/同步推理）+ `ModelControllerTest` | ✅ |
| 4 | 前端 | `modules/model-center`（注册/审批/测试/API 发布 4 Tab）+ `DataModelApi` + edge 菜单 | ✅ |
| 5 | 参考 scorer 模型 + 带标签测试集 + E2E | `devdata/sample-model`（行级 scorer JAR + 构建脚本）+ `devdata/model_test_labeled.csv`（100 行 id/score/pass）；E2E 11 项全过（见下） | ✅ |
| 6 | OpenAPI 契约 + 报告 + 文档同步 | 本报告 + 开发文档接口契约 + CLAUDE.md / 开发文档同步 | ✅ |

**核心行为变化（对用户可见）**：
- 新增「模型中心」页面（4 Tab）：**模型注册 / 模型审批 / 测试记录 / API 发布**。
- **审批单绑定实际制品**：`ds_model_approval` 扩展 `artifact_id` / `artifact_version_id`，新流程行 `model_id = ds_model.id`
  （`dm-`）与旧 legacy 行并存；注册仅允许 JAR/PYTHON 制品（SQL 注册即 `MODEL_PARAM_INVALID` 拒绝），版本自增不可变，
  同项目同制品非终结态重复注册 `MODEL_ALREADY_EXISTS`。
- **强制测试门禁**：RESOURCE_REVIEW 阶段 APPROVE→APPROVED 前必须有 ≥1 次成功测试且保存评估指标，否则
  `MODEL_TEST_REQUIRED`，形成「注册→测试→审批→发布」闭环。
- **测试执行**：审批人选择属于模型项目的数据集 + 参数 JSON + label/prediction 列 + metric_type（auto/分类/回归）
  → RUNNING → SUCCEEDED/FAILED；平台侧纯 Java `ModelMetricsEvaluator` 行级对齐计算指标（分类 accuracy / macro
  precision / recall / F1 + 二分类混淆矩阵计数；回归 MAE / RMSE / R²），保存输入/输出摘要（表头/行数/列数/预览）、
  测试日志（`ds_dev_run_log` 按 attempt）、审批 `test_evidence`。
- **受控 API 发布**：创建 API 一次性返回 `app_id` + `secret`（sha256 常量时间比对，明文只展示一次、列表不回显），
  配置授权用户 / IP 白名单 / 有效时间窗口，ENABLED/DISABLED，密钥可轮换（regenerate-secret，旧失效新生效）。
- **两路调用鉴权**：`X-APP-ID`/`X-APP-SECRET` 凭证调用（经 LoginInterceptor 强制分支）或 User-Token + body.appId
  （须在授权名单）；守卫顺序 = 启用状态 → 有效窗口 → IP 白名单 → 授权用户（凭证调用者跳过，名单仅约束平台调用），
  全部 `MODEL_*` 明确错误码；`call_count` 递增、`last_called_at` 记录。
- **同步推理**：invoke 走新增 `DevJobExecutor.runAndAwait`（`channel='api'`，调度器不轮询，无结果表/血缘），返回
  `{header, rows, resultRows, elapsedMs}`；PYTHON 模型（白名单校验 + runner 守卫）同样支持测试与发布调用。
- 全动作写 `ds_unified_log` 审计（`MODEL_REGISTER/SUBMIT/APPROVE/PUBLISH/MODEL_TEST_*/MODEL_API_*`）+ webhook `model.*`。

---

## 二、测试情况

### 2.1 后端单元/集成测试（64 例新增，全绿）

| 测试类 | 覆盖内容 | 结果 |
|---|---|---|
| `ModelMetricsEvaluatorTest`（15 例） | 分类（二分类混淆矩阵计数、accuracy、macro P/R/F1、多分类）、回归（MAE/RMSE/R²）、auto 阈值判定（去重 >20 → 回归）、行数不一致 → `MODEL_METRIC_ALIGNMENT`、空输入 → `MODEL_PARAM_INVALID` | ✅ |
| `ModelApprovalStateMachineTest`（11 例） | 全状态流转（MODEL_REVIEW/RESOURCE_REVIEW/APPROVED/PUBLISHED/REJECTED）、REJECT/RESUBMIT version+1、非法流转、门禁位 | ✅ |
| `ModelApiGuardTest`（19 例） | 守卫顺序、CIDR/IP 精确匹配、空白名单任意 IP、空授权名单仅凭证调用、停用/过期/IP/用户拒绝 | ✅ |
| `ModelControllerTest`（5 例，MockMvc 真 token） | 模型注册/审批动作/API CRUD 鉴权与状态冲突、错误码 `MODEL_*` | ✅ |
| `DevJobExecutorTest`（5 例） | `runAndAwait` 返回+耗时、`channel='api'` 不被 poll 选中、model/api 结果落盘 | ✅ |
| `DataModelIT`（9 例，MockKusciaGrpcServer + 本地 HttpServer + SQLite） | 注册（JAR/PYTHON 放行、SQL 拒绝、版本自增、重复拒绝）、审批流转、**无测试 → `MODEL_TEST_REQUIRED`**、有测试 → APPROVED、测试 SUCCEEDED + 指标/摘要、发布 + API 守卫、invoke（凭证 + User-Token 两路）、PYTHON 白名单 | ✅ |

### 2.2 前端构建

`pnpm --filter secretpad build` 全部通过（Webpack Compiled successfully，48.02s；模型中心 4 Tab + `DataModelApi`）。

### 2.3 个人实例端到端（data-sandbox-package · develop.sh 方法）

个人私有实例：后端 `127.0.0.1:8099`，Kuscia 容器 `data-sandbox-dev-zgz-kuscia`，管理员 `devadmin`，
测试集 = `devdata/model_test_labeled.csv`（100 行 id/score/pass，pass=1 ⇔ score≥60，51/49 分布），
参考模型 = `devdata/sample-model/model-scorer-sample-1.0.0.jar`（行级 scorer，`featureColumn/weightA/weightB/intercept/mode/threshold`，
`prediction = score≥threshold ? 1 : 0`，输出行与输入 1:1 对齐）。

| # | E2E 项 | 结果 | 说明 |
|---|---|---|---|
| 1 | 注册 JAR 模型（制品+版本+项目）→ `ds_model` 行；SQL 制品注册被拒 | ✅ | `da-7eac1c3b5453`(JAR)+`dav-cd7414d18dad` v1 → `dm-da131e08214a` DRAFT；SQL 制品 `da-971af27b80b4` 注册 → `MODEL_PARAM_INVALID: 仅 JAR/PYTHON 制品可作为模型（当前 SQL）` |
| 2 | 提交审批 → MODEL_REVIEW → APPROVE → RESOURCE_REVIEW | ✅ | `apr-261c3858b7d3` 绑定 artifact_id/version_id/project_id；MODEL_REVIEW→RESOURCE_REVIEW（reviewer/comment 落库） |
| 3 | 审批人配置测试（测试表+参数+label/prediction 列+metric_type=auto）→ SUCCEEDED + 指标 + 摘要 + test_evidence + run log | ✅ | `mt-ebaca726911e`（源 fjhqnhcx，params `featureColumn=score,threshold=60`，label=pass，prediction=prediction）→ SUCCEEDED；指标 classification accuracy/precision/recall/F1=1.0，混淆矩阵 tp=51 fp=0 fn=0 tn=49；input_summary `{columnCount:3,rowCount:100,header:[id,score,pass]}`；output_summary `{columnCount:4,rowCount:100,header:[id,score,pass,prediction],previewRows}`；审批 test_evidence `{testId,ranAt,metrics}`；run log `[jar] running: java -jar ... --params {...}` + output bytes；审计 `MODEL_TEST_SUBMIT/SUCCEEDED` |
| 4 | 负向门禁：RESOURCE_REVIEW 下先 APPROVE → `MODEL_TEST_REQUIRED`；有测试后 APPROVE → APPROVED | ✅ | `dm-d71e7123473b`+`apr-e9e24982b893`：无测试 APPROVE → `MODEL_TEST_REQUIRED: 审批通过前需至少一次成功的模型测试并保存评估指标`；测试 `mt-48bcdf9fee16` SUCCEEDED → APPROVE → APPROVED（approved_at 落库） |
| 5 | PUBLISH → PUBLISHED → 创建 API → 一次性 app_id+secret → 授权用户/IP 白名单/有效时间 → ENABLED | ✅ | PUBLISH → 审批 PUBLISHED + 模型 PUBLISHED（published_at）；`mapi-fabaff244d5b` app_id `ai-86c5c363ff7d`，secret 只返回一次（列表 `hasSecret=False` 不回显），authorizedUsers=`[devadmin]`、ipWhitelist、validFrom/validTo → ENABLED |
| 6 | invoke（X-APP-ID/X-APP-SECRET）→ 预测 + elapsedMs；`call_count` 递增 | ✅ | rows `70→1, 30→0, 58→0`（threshold=60），resultRows=3，elapsedMs=4576；call_count 0→1，last_called_at 落库 |
| 7 | 守卫负向：错 secret / 停用 / 超有效期 / IP 不在白名单 / 未授权用户 → 明确 `MODEL_*` 错误 | ✅ | 错 secret → `用户认证失败: invalid model api credential`；停用 → `MODEL_API_DISABLED`；validTo 置过去 → `MODEL_API_EXPIRED`；白名单仅 127.0.0.1 而调用 IP 172.22.0.1 → `MODEL_API_IP_DENIED`；authorizedUsers=`[nobody]` + User-Token 调用 → `MODEL_API_USER_DENIED: 调用用户 devadmin 不在授权名单`；恢复后 User-Token+body.appId 调用成功（授权名单校验路径） |
| 8 | regenerate-secret → 旧失效新生效 | ✅ | 新 secret 一次返回，旧 secret invoke → 认证失败，新 secret invoke → 成功；DB `secret_hash` 变更（4c69769e→4331f9ca） |
| 9 | PYTHON 模型路径：注册 python scorer（白名单校验）→ 测试 + invoke | ✅ | `da-72878cf0ea39`(PYTHON)+`dav-55e54c76bc99`（dependencyNames=`[pandas]` 白名单放行）→ `dm-085d22e4c552`；测试 `mt-7209ddaee7cf` SUCCEEDED（accuracy=1.0）；approve → API `mapi-736fe328a725`；invoke `65→1, 40→0`；run log `[py] running: /usr/local/bin/python /tmp/py/script_guarded.py ...`（runner 守卫） |
| 10 | 审计：`MODEL_*` 全动作写 `ds_unified_log` | ✅ | 52 行：MODEL_REGISTER/SUBMIT/APPROVE/PUBLISH、MODEL_TEST_SUBMIT/SUCCEEDED、MODEL_API_CREATE/UPDATE/INVOKE(含 caller/ip/rows/task/elapsedMs)/AUTH/REGENERATE/ENABLE/DISABLE；守卫拒绝成功=0 且 detail 含 `MODEL_API_*` 原因 |
| 11 | 隔离抽查：invoke pod cpu=500m/memory=512Mi、network_policy=GOVERNANCE、取回后 Job 删除（无残留 dt-*） | ✅ | kubectl 抓取运行中 pod spec：`cpu: 500m / memory: 512Mi`（requests+limits）、restartPolicy=Never、无卷无密钥（仅 task configtemplate）；network_policy=GOVERNANCE 经 `DevJobExecutor` `putCustomFields` 下发（运行配置无 env 覆盖，为默认值）；`completeSuccess` 取回后 `delete(jobId)`，kuscia pod 于 GC 窗口（~1–2 分钟）内全部消失，最终 0 个 `dt-*` pod、0 个 kusciatask CRD 残留 |

---

## 三、修复情况（本任务内发现并修复的问题）

| # | 问题 | 根因 | 修复 | 提交 |
|---|---|---|---|---|
| 1 | **invoke 与调度轮询并发收官（双收官风险）** | 若 `runAndAwait` 与 `@Scheduled pollDevTasks` 同时对同一任务取结果/删 Job，将产生重复血缘/Webhook | **设计规避**（Stage 2）：`ds_dev_task.channel` 列隔离——`pollDevTasks` 仅轮询 `channel in ('dev','model')`，`channel='api'` 绝不被调度器收官；`runAndAwait` 复用幂等 `pollDevTask` + 条件 UPDATE 单写者 | secretpad `9b92820` |
| 2 | **DEV 无结果文件 → 无法计算模型指标** | Z-05 DEV 模式仅存结果预览不落盘结果 CSV，模型测试/API 调用取数无源 | `completeSuccess` 对 `channel in ('model','api')` 或 `runMode=PROD` 写结果 CSV 到 `result_uri`（纯 Z-05 dev 行为不变） | secretpad `9b92820` |
| 3 | **指标行对齐不可控** | 预测列（结果 CSV）× 真实列（输入 CSV）若行数不一致，指标将失真 | `ModelMetricsEvaluator` 硬校验 `labels.size()==predictions.size()`，不一致抛 `MODEL_METRIC_ALIGNMENT`；参考 scorer 明示"行级 1:1 对齐契约" | secretpad `0e819ec` |
| 4 | **审批无测试即通过（门禁缺失）** | 原状态机 APPROVE→APPROVED 无测试约束 | RESOURCE_REVIEW APPROVE→APPROVED 前强制 `finalizeAllForApproval` + ≥1 次成功测试且 metrics 非空，否则 `MODEL_TEST_REQUIRED` | secretpad `9b92820` |
| 5 | **运行时后端为 Z-05 旧构建（部署层面，非代码缺陷）** | 容器内 jar 为 Z-05（镜像 cc818fe），V13 未迁移，`/models` 静态 404 | 本地构建 Z-06 jar + `docker cp` + `docker restart`，V13 三份 SQL 接入运行时 config 挂载，Flyway 重启应用 | 无代码提交（部署操作） |
| 6 | **API 契约澄清：管理端点字段 `id`；`createVersion` 的 paramsSchema/defaultParams 须为 JSON 字符串** | `approvalAction/update/enable/...` 控制器读 `request.get("id")`；`DataDevService.jsonOr` 用 `String.valueOf`，解析后的 JSON 数组会被转成 Java `List.toString` 非法 JSON | 前端已对齐（`{ id: item.id }`；表单传字符串 `'[]'`/`'{}'`）；接口文档注明（见下） | 无代码缺陷（前端已正确） |

**E2E 未发现新的后端/前端代码逻辑缺陷**（注册/审批状态机、测试执行/惰性收官、指标计算、API 守卫顺序、两路鉴权、
channel 隔离、取回即删等全部符合预期）。

---

## 四、已知环境限制（重要）

1. **模型测试权限放宽（与 Z-05 owner-only 不同）**：测试执行人 = 模型创建人 **或** 当前审批 reviewer；测试数据集仅要求
   ∈ `project_datatable where project_id=模型.project_id and node_id=? and datatable_id=? and is_deleted=0`
   （数据集属于模型项目即可，审批人**不必**是项目成员）；测试仅限审批处于 MODEL_REVIEW/RESOURCE_REVIEW/APPROVED 时。
   这是对"审批人配置测试"的刻意支持，报告中注明此偏差。
2. **invoke 执行任意模型代码的固有属性**：调用方经凭证/授权后触发 JAR/PYTHON 一次性容器执行。隔离复用 Z-05 全套机制
   （network_policy=GOVERNANCE、无卷无密钥、仅 task_input_config 入参、CPU 0.5/512Mi、超时 kill、取回即删）——平台对
   "被发布模型代码本身"不做语义审查，模型安全边界 = 发布者信任 + 容器隔离。
3. **指标行对齐契约**：真实列与预测列按行序 1:1 对齐，不一致即 `MODEL_METRIC_ALIGNMENT`。参考 scorer 明示该契约；
   如需按 id 联接（不同行序）对齐，可后续扩展 idColumn 联接键（留待后续）。
4. **legacy/新审批单并存**：V6 `ds_model_approval` 兼容扩展（仅 ADD COLUMN）；旧 `DataSandboxMvpService.submitModel/
   approvalAction/assertModelApproved`（legacy ML-serving 路径）保持原样，与新 `ModelApprovalService` 流程行并存互不干扰。
5. **Kuscia pod 取回删除后 GC 有 ~1–2 分钟窗口**：`delete(jobId)` 删除 Kuscia Job 即时，但 Pod 对象以 NotReady 状态短暂
   存留（容器已终止）至 GC 完成，之后全部消失（无长期残留 `dt-*` pod / kusciatask CRD）。判定"无残留"以 GC 完成后为准。
6. **IP 白名单需含实际调用方出口 IP**：个人实例后端经 docker bridge 调用（调用方 IP `172.22.0.1` 而非 127.0.0.1），
   白名单过窄会误拒（`MODEL_API_IP_DENIED` 为正确守卫行为）。
7. **JAR 传递走 `task_input_config` base64**：同 Z-05，默认上限 `DEV_JAR_BYTES:48MB`；大体积 JAR 需调配置并在正常环境实测。
8. **`createVersion` 的 paramsSchema/defaultParams 须为 JSON 字符串**（body 内传解析后的数组/对象会被 `String.valueOf`
   转成 Java 列表文本而拒绝 `DEV_PARAM_INVALID`）；前端表单天然传字符串，API 直接调用方需按字符串传。
9. **测试门禁与指标由调度轮询驱动收官**：`channel='model'` 测试任务由 `@Scheduled pollDevTasks` 收官，`finalizeTestIfNeeded`
   读时惰性计算指标；实时性受 `dev.poll-interval-ms`（默认 10s）影响。

---

## 五、浏览器使用指南（你现在就可以操作）

> 前提：个人实例仍在运行。管理员凭据位于 `/data/zgz/datasandbox/.dev-runtime/zgz/secretpad.env`（`SECRETPAD_USER_NAME=devadmin`，`SECRETPAD_PASSWORD=<随机串>`）。

1. **打开页面**：浏览器访问 `http://127.0.0.1:9099`，用 `devadmin` + 上述密码登录，左侧导航出现「模型中心」。
2. **模型注册（Tab 1）**：点「注册模型」→ 选项目 + JAR/PYTHON 制品 + 版本 + 名称/描述 → 提交；列表展示状态（DRAFT/
   APPROVING/APPROVED/REJECTED/PUBLISHED/OFFLINE）、版本、测试数、API 数；「详情」看当前审批/测试/API 关联。
3. **模型审批（Tab 2）**：对 DRAFT 模型「提交审批」→ APPROVE（MODEL_REVIEW→RESOURCE_REVIEW）→ 在审批抽屉中「测试执行」
   面板选择测试表（模型项目内）→ 填参数 JSON + label/prediction 列 + metric_type → 执行 → 展示指标卡片（accuracy/
   precision/recall/F1/混淆矩阵计数）+ 输入/输出摘要 + 测试日志；**通过前需至少一次成功测试**（无测试 APPROVE 会被
   `MODEL_TEST_REQUIRED` 拒绝）→ 再 APPROVE → PUBLISH。
4. **测试记录（Tab 3）**：测试表（状态/runMode/行数/指标摘要）+ 详情（指标、摘要、日志按 attempt）、FAILED 可「重试」。
5. **API 发布（Tab 4）**：对已审批模型「发布 API」→ 展示一次性 `app_id` + `secret`（**只显示一次，请立即保存**）→ 配置
   授权用户/IP 白名单/有效时间 → ENABLED；「调用测试」控制台输入 headers + rows 调 `invoke` 看预测结果；可 enable/disable/
   regenerate-secret。
6. **端到端演示数据**：`data-sandbox-package/devdata/sample-model`（scorer JAR，`build.sh` 可重编）+ `devdata/model_test_labeled.csv`
   （100 行），配合参数 `{"featureColumn":"score","threshold":"60"}` 可得分类指标 accuracy/F1=1.0（数据本身可分）。

---

## 六、提交记录（develop/zgz）

| 仓库 | 提交 | 内容 |
|---|---|---|
| secretpad | `0e819ec` | Stage 0：V13 迁移（审批单绑定制品/版本 + ds_dev_task channel/result_uri + ds_model/ds_model_test/ds_model_api）+ 纯类 ModelMetricsEvaluator/ModelApprovalStateMachine/ModelApiGuard/ModelErrors + 3 单测类 |
| secretpad | `9b92820` | Stage 1+2：ModelApprovalService（注册/审批门禁）+ ModelTestService（测试执行/惰性收官/摘要/指标）+ DevJobExecutor channel/api 同步调用 + DataModelIT |
| secretpad | `d57d811` | Stage 3：受控模型 API（凭证/IP/授权/有效时间/同步推理）+ ModelController/ModelTestController/ModelApiController + LoginInterceptor invoke 分支 + ModelControllerTest |
| secretpad-frontend | `5c93b6c` | Stage 4：模型中心前端（注册/审批/测试/API 发布 4 Tab）+ DataModelApi + edge 菜单 |
| data-sandbox-package | `60c0169` | Stage 0：V13 迁移打包接线（build.sh/Dockerfile 追加 V13__model_test.sql 三份 COPY） |
| data-sandbox-package | `a10094f` | Stage 5：参考 scorer 模型（sample-model）+ 构建脚本 + 带标签测试集 model_test_labeled.csv |

三仓库均已推送 `develop/zgz`。
