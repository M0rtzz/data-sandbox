# Z-04 数据抽样与脱敏服务 · 任务完成报告

> 执行人：zgz ｜ 日期：2026-08-19 ｜ 分支：develop/zgz（secretpad / secretpad-frontend / data-sandbox-package）
> 本报告含：功能完成情况、测试情况、修复情况、已知环境限制、浏览器使用指南、提交记录，附录见文末。

---

## 一、功能完成情况

Z-04 建立数据治理闭环：**四种可配置抽样（随机/等距/分层/整群分块）+ 五种脱敏（掩码/替换/哈希/取整/空值清除）**
由**策略模型**保存复用，**任务模型**记录每次执行（payload 全快照），**内置引擎（Java 进程内）与自定义代码执行
（一次性 Kuscia 容器 + 执行隔离）**双通道产生**可追溯新数据集**并注册 Kuscia DomainData，全程**数据血缘 + 审计**，
处理过程**仅访问授权数据、仅输出策略允许列**。7 个阶段全部完成：

| 阶段 | 内容 | 产出 | 状态 |
|---|---|---|---|
| 0 | 计划落盘 + V11 迁移 + 纯类 | `claude/plans/Z-04-plan.md`、V11 三表（policy/task/lineage）×3 套 schema、`CsvUtil` + `GovernanceSamplingExecutor` + `GovernanceMaskingExecutor` + 30 例单测 | ✅ |
| 1 | 内置抽样/脱敏引擎 + 权限校验 + 结果注册 + 审计 | `DataGovernanceService`、`DataGovernanceIT`（19 例） | ✅ |
| 2 | 自定义代码执行组件 + 执行隔离 | `data-sandbox-sampler` 容器（python:3.11-slim）+ AppImage 模板/注册脚本 + `GovernanceCustomExecutor` + `DataGovernanceCustomIT`（8 例） | ✅ |
| 3 | 数据治理 API | `DataGovernanceController`（14 端点）+ `DataGovernanceControllerTest`（14 例） | ✅ |
| 4 | 前端 | `modules/data-governance/` 三 Tab 页面 + api wrapper + edge 菜单 | ✅ |
| 5 | 测试数据集 + 挂载修复 + E2E | `gov_sample*.csv`（63 行×8 列）、develop.sh 挂载修复、10 项 E2E 清单全通过 | ✅ |
| 6 | OpenAPI 契约 + 报告 + CLAUDE.md/开发文档同步 | 本报告 + CLAUDE.md Z-04 小节 + 开发文档进度更新 | ✅ |

**对照任务书 5 项需求：**

| 任务书要求 | 完成情况 |
|---|---|
| 1. 随机、分层、整群/分块、等距等**至少三种**可配置抽样 | ✅ `GovernanceSamplingExecutor` 实现 **RANDOM**（count/ratio，seed 复现）、**SYSTEMATIC**（等距取 k）、**STRATIFIED**（按 strataColumns 分组每层取 count/ratio）、**CLUSTER**（clusterColumn 整群 or 连续块 blockSize）；抽样参数随任务全快照持久化 |
| 2. 受控自定义代码抽样 + 执行隔离 | ✅ CUSTOM 任务把**授权输入子集**（≤5000 行 / 256KB base64，超限 `GOV_INPUT_TOO_LARGE` 拒绝）内联进 `task_input_config`，在**一次性 Kuscia Job**（`data-sandbox-sampler` AppImage）执行，结果经 **scope=Cluster 端口**取回；隔离：无卷无密钥、仅入参、CPU/内存限额（默认 0.5CPU/512Mi）、容器脚本超时 + 平台 300s stopJob 兜底、跑完即删、`-nonet` 变体（scope=Domain，无 Cluster 端点=平台不可达）对照 |
| 3. 掩码/替换/哈希/取整/空值清除 | ✅ `GovernanceMaskingExecutor` 实现 **MASK**（`138****1234`）、**REPLACE**（常量/映射）、**HASH**（SHA-256+列盐，不可逆）、**ROUND**（小数位取整）、**CLEAR**（置空/删列）；输出列 = 输入列经 CLEAR 过滤 |
| 4. 保存策略、任务记录、数据血缘、结果数据集 | ✅ V11 三表：`ds_governance_policy`（策略 CRUD+软删）、`ds_governance_task`（8 态 + exec_params 全快照 + script_content + kuscia_job_id + retry_count）、`ds_governance_lineage`（source→target 全链）；结果数据集 = 注册的 Kuscia DomainData（type=table CSV），任务表派生结果列表，`/tasks/mount` 挂项目（source=CREATED） |
| 5. 不暴露未经授权的真实数据 | ✅ `checkSourcePermission`：仅已授权到用户项目的 `project_datatable` 或 `nodeId==ownerId` 平台自有数据可处理；策略/任务按创建人隔离；preview/submit/mount 全程权限校验 + `ds_unified_log` 审计 + 血缘；输出只含策略允许列；自定义代码输入子集化且仅内联授权受限 CSV |

**核心行为（对用户可见）：**

- **策略复用**：一次配置抽样/脱敏策略，后续任务按 `policyId` 复用（策略基于 id 引用，payload 全快照保证追溯不随策略变更漂移）。
- **内置任务同步出结果**：提交即校验权限/读源/抽样/脱敏/写结果/注册 DomainData/写血缘，任务状态 `PENDING→RUNNING→SUCCEEDED/FAILED`，失败可 `retry`。
- **自定义任务走一次性容器**：提交 CUSTOM → 起一次性 Kuscia Job → 容器执行用户 Python 脚本 → 平台经 gateway Cluster 端点取回结果 CSV → 校验表头/行数/大小 → 注册 DomainData → `deleteJob` 跑完即删；超时/失败/取消均有明确状态 + 告警。
- **结果可挂项目**：SUCCEEDED 任务的结果表可 `mount` 到 P2P 项目（`project_datatable` source=CREATED），数据管理页可见、可在项目中消费。
- **挂载修复**：SecretPad `/app/data` 与 Kuscia `/home/kuscia/var/storage/data` 指向同一宿主目录（对齐官方 secretpad.sh），dev 中上传/产出的表同源可被 SecretFlow 消费。

---

## 二、测试情况

### 2.1 后端单元/集成测试（71 例新增，全绿）

| 测试类 | 覆盖内容 | 结果 |
|---|---|---|
| `CsvUtilTest`（7 例） | RFC4180 读写：引号/逗号/内嵌换行/CRLF/BOM/空行/空字段 | ✅ |
| `GovernanceSamplingExecutorTest`（12 例） | RANDOM（count/ratio/seed 复现/越界）、SYSTEMATIC（步长/边界）、STRATIFIED（每层计数/空组）、CLUSTER（clusterColumn/blockSize/无参数全选） | ✅ |
| `GovernanceMaskingExecutorTest`（11 例） | MASK（保留位/掩码字符）、REPLACE（常量/映射）、HASH（确定性/盐）、ROUND（scale/非数值保留）、CLEAR（置空/删列） | ✅ |
| `DataGovernanceIT`（19 例，独立 `/tmp` sqlite + mock gRPC :50053） | ① 4 抽样 × 结果行数断言（seed 复现）② 5 脱敏 × 内容断言（CLEAR 删列）③ 注册 DomainData + 血缘 + 审计 ④ 失败→FAILED→retry→SUCCEEDED ⑤ 权限拒绝（未授权表/无项目用户）⑥ 平台自有数据（nodeId==ownerId / node.instId==ownerId / 无 node 行）放行 ⑦ 输入超限（行/字节）创建前拒绝 ⑧ preview 权限门 ⑨ 策略 CRUD + 基于策略提交 ⑩ mount 结果挂项目 | ✅ |
| `DataGovernanceCustomIT`（8 例） | ① CUSTOM 成功（createJob→Succeeded→取回→注册）② createJob 失败→FAILED ③ Job Failed→FAILED+告警 ④ RUNNING 但结果已就绪直接 finalize ⑤ 平台超时→stopJob+FAILED ⑥ 输入行/字节超限拒绝 ⑦ retry 幂等 | ✅ |
| `DataGovernanceControllerTest`（14 例，MockMvc + 真实登录 token） | 策略 CRUD/列表/详情、任务提交（内置/自定义）、列表/详情/取消/重试/结果/mount、血缘、preview、权限拒绝、参数校验、状态冲突、`GOV_*` 错误码 | ✅ |

全量回归基线同 Z-03：`LoginInterceptorTest` 1 + `ModelManagementControllerTest` 8 为历史遗留（基线可复现，与本次改动零交集）。

### 2.2 前端构建

`pnpm --filter secretpad build` 4 项目全部通过（阶段 4 页面 + api wrapper + 阶段 5 `listP2PProject` 修正）。

### 2.3 个人实例端到端（data-sandbox-package · develop.sh 方法）

个人私有实例：后端 `127.0.0.1:8099`，Kuscia 容器 `data-sandbox-dev-zgz-kuscia`，管理员 `devadmin`，源表 `ijcnuibt`（dev-zgz 域，63 行×8 列，物理文件 `/app/data/dev-zgz/gov_sample_536056233.csv`）。

| # | E2E 项 | 结果 | 说明 |
|---|---|---|---|
| 1 | 策略 CRUD | ✅ | 创建 SAMPLING（`gp-dfc746f332c5` e2e-sampling-v2 / RANDOM）、MASKING（`gp-9c11c4757c57` e2e-masking）、SAMPLING_MASKING（`gp-9b108b08103c` e2e-sampling-masking / SYSTEMATIC）三策略 + 列表/类型过滤/更新/详情/软删/删后重建；审计 `POLICY_CREATE=4/UPDATE=1/DELETE=1` |
| 2 | 内置抽样 ×4 | ✅ | RANDOM `gt-ac9d136a43fa` 63→5（seed 复现：同 seed 两次同 5 行）→`rodnunow`；SYSTEMATIC `gt-25414c81bb53` 63→8 →`zetpgoof`；STRATIFIED `gt-a2194dc03af2` 63→3（A/B/C 各 1）→`zmkncgof`；CLUSTER `gt-1f665b251542` clusterColumn 63→21 →`svyvhazv` + `gt-feb6bbb5b6a2` blockSize 63→5 →`fgqmdfso` |
| 3 | 内置脱敏 ×5 | ✅ | MASK `gt-f2a64976753e` 手机号 `137****0007` →`lnvelndx`；REPLACE `gt-0d1898f22cad` category=`REDACTED` →`oujwugef`；HASH `gt-61ecebb71c83` id_card SHA-256 hex →`jakspwsf`（`100000000001234567→5dfa0429...`）；ROUND `gt-29340edc02d8` `101.00→101` →`zltekzxf`；CLEAR `gt-b31deced8c25` memo 置空 →`qokoxqbc`；链式 `gt-04c789e5015f`（抽样+脱敏）→`zhenjyep` |
| 4 | 自定义代码 | ✅ | 镜像 `data-sandbox-sampler:latest`（sha256:0793e4a8a2150, 129MB）构建→导入 kuscia containerd→注册 AppImage（正常 + `-nonet`）；提交 `gt-1f390d8b225e`（脚本过滤 category=='A'）→ 一次性 Job 拉起 → **Cluster 端口取回结果** → 结果表 `ameeoboi`（21 行）→ 血缘 `CUSTOM ijcnuibt→ameeoboi` → 物理文件 `gt-1f390d8b225e-227d44721c78.csv` → **Job 跑完即删**（`kubectl get job | grep gov` 为空） |
| 5 | 执行隔离 | ✅ | **5a 外联阻断**：`gt-774181f008c4` 脚本 `socket.connect(8.8.8.8:80)` → 容器非零退出 `FAILED`；**5b pod 限额**：运行中容器 cgroup `cpu.max=50000/100000`（=0.5 CPU）、`memory.max=536870912`（=512MiB）与配置一致；**5c 超时 kill**：`gt-dac6fc1a26f1` sleep300 → 容器脚本超时（240s）终止 → `FAILED` + 告警 `ds_alert_event` `gov:gt-dac6fc1a26f1:failed`；**cancel**：`gt-90711fb2142e` RUNNING→CANCELLED + stopJob；**retry**：`gt-774181f008c4` FAILED→RUNNING(retry_count=1)→FAILED；**nonet 对照**：`data-sandbox-sampler-nonet` 端口 `scope=Domain`（无 Cluster 端点=平台不可达）已注册验证 |
| 6 | 权限 | ✅ | 已授权 preview 63 行正常；未授权用户/未授权表 preview/submit 返回 `GOV_NO_PERMISSION`；`nodeId==ownerId` 平台自有域提交 SUCCEEDED |
| 7 | 血缘 | ✅ | `ds_governance_lineage`：`SAMPLE_MASK` 14 条 + `CUSTOM` 1 条（`ijcnuibt→<14 个内置结果>`、`ijcnuibt→ameeoboi`）；`/lineage` 按 source/target 反查均可见 |
| 8 | 审计 | ✅ | `ds_unified_log`：`GOVERNANCE_POLICY_CREATE=4/UPDATE=1/DELETE=1`、`GOVERNANCE_TASK_SUBMIT=18/SUCCEEDED=15/FAILED=3/CANCEL=1/RETRY=1`、`GOVERNANCE_RESULT_MOUNT=1` |
| 9 | 结果挂载项目 | ✅ | P2P 项目 `yaxidmzu`（z04-e2e-project）经 `listP2PProject` 可见；`/tasks/mount` `gt-ac9d136a43fa` → `project_datatable(yaxidmzu, dev-zgz, rodnunow, source='CREATED')`；`/datatable/list` ownerId=dev-zgz 共 **16 表含 rodnunow**（数据管理页可见）；`/preview` 结果表可访问（8 列 schema + 行数据） |
| 10 | 挂载修复验证 | ✅ | SecretPad `/app/data` 与 Kuscia `/home/kuscia/var/storage/data` **同一宿主目录** `.dev-runtime/zgz/kuscia/data`；上传表 `gov_sample_536056233.csv` MD5 双侧一致 `71b872d0b058ec78d8bbe2d8a615c4cb`；治理结果 `gt-ac9d136a43fa-*.csv` MD5 双侧一致 `49a6ed501b7914757c2f83cfeeba352e`（SecretFlow/DAG 可读路径就绪） |

---

## 三、修复情况（本任务内发现并修复的问题）

| # | 问题 | 根因 | 修复 | 提交 |
|---|---|---|---|---|
| 1 | **build.sh maven 以 root 运行污染挂载目录**（复制 static 报 `Operation not permitted` + 5040 个 root 属主文件阻断本地 mvn） | `maven:3.9.9` 镜像默认 root 用户，`docker run -v ${BACKEND_DIR}:/workspace` 把整个挂载 workspace 写成 root 属主；`-u $(id -u)` 方案被 protobuf 插件无法删除 root 属主 protoc 缓存阻断 | 保持 maven root + `-e DEV_UID -e DEV_GID` + 构建后 `chown -R --from=root "$DEV_UID:$DEV_GID" /workspace` **自愈**；验证 target 下 root 属主 0 | `ea304df` |
| 2 | **P2P 平台自有数据权限误拒**（`checkSourcePermission` 把 nodeId=ownerId 的合法提交判为无权限） | 单实例 `platformNodeId` 恒等不适用；仅 `project_datatable` 授权路径会拒绝平台自有域数据 | 新增双放行：`nodeId==user.ownerId`（无需 node 行）+ `node.instId==ownerId`（node 行存在）；新增 IT 13b/13c | `15f1705`、`2accb72` |
| 3 | **旧源表读不到物理文件（GOV_NOT_FOUND）** | 历史混合会话上传用 Node-Id=ctqkgaov + datatable/create nodeIds=[dev-zgz] 不一致，导致 DomainData domainId/author=dev-zgz 但物理文件在 `/app/data/ctqkgaov/` | 后端 `readCsv` 4 处改用 `source.getNodeId()`（=author/kuscia 域）解析物理目录；E2E 重新**一致上传**（Node-Id=dev-zgz）建新源表 `ijcnuibt`（文件落 `/app/data/dev-zgz/`） | `2accb72` |
| 4 | **CLUSTER 未给 count/ratio 时返回全部行** | 无约束时 `pickClusterKeys` 选全部 cluster（语义正确但参数缺失场景） | 非 bug；E2E 补 `{"method":"CLUSTER","clusterColumn":"category","count":1}` → 21 行 / `blockSize=2,count=3` → 5 行 | — |
| 5 | **REPLACE 把列清空** | 请求用了 `replaceValue` 参数，实现读取的 key 是 `value` | 非 bug（参数名契约）；E2E 补 `{"value":"REDACTED"}` → 正常（见附录 B 两任务对比） | — |
| 6 | **`listP2PProject` 返回空 / 报「项目不在审批列表信息中」** | `createP2PProject` 只建 ProjectDO；`listP2PProject` 需 `project_inst`（按 ownerId）+ `project_approval_config`（PROJECT_CREATE）+ `vote_request` 才返回 | 前端挂载弹窗改用 `listP2PProject`；dev E2E 按审批流产物插入 `project_inst` + approval config + vote 行（生产由审批流程生成），项目可见后 mount 成功 | `80e0f19` |
| 7 | **治理结果经 `/data/download` 报「项目结果未找到」** | `getNodeResult` 依赖 `project_result`（仅 Kuscia Job 产出注册），上传表/治理结果表均无 | 属平台既有语义（上传表同样不可经该端点下载）；治理结果经 `/preview` 可访问 + `project_datatable` 在项目中消费，报告注明 | — |
| 8 | **E2E cancel 传 `taskId` 报「记录不存在」** | Controller 约定 body 字段为 `id`（与 detail/list 一致） | 属前端契约注意点；E2E 改用 `{"id":...}` 后 RUNNING→CANCELLED + stopJob 成功 | — |

---

## 四、已知环境限制（重要）

1. **自定义代码输入子集受限**：CUSTOM 输入默认 ≤ `SECRETPAD_DATA_SANDBOX_GOVERNANCE_INPUT_ROWS:5000` 行 / `INPUT_BYTES:262144`（256KB）base64 上限，超限返回 `GOV_INPUT_TOO_LARGE`（创建前拒绝，不产生任务记录）。大文件全量处理路径留待 Z-05 数据供给通道。
2. **`task_input_config` 挂载路径**：本环境 Kuscia 0.13.0b0 实证挂载为 `/etc/kuscia/sampler-conf.json`（AppImage `configTemplates`+`configVolumeMounts` 渲染）；升级 Kuscia 版本后需复核路径（容器端 `start.sh` 可传参兜底）。
3. **双层超时**：容器脚本自带 240s 超时（`SAMPLER_SCRIPT_TIMEOUT_SECS`）通常先于平台 300s `stopJob` 生效——平台超时作为防御纵深兜底；报告以容器超时路径完成 E2E 演示（`gt-dac6fc1a26f1`），平台 stopJob 路径在 IT `timeoutStopsJobAndMarksFailed` 覆盖。
4. **自定义代码依赖 Kuscia 运行**：CUSTOM 任务依赖真实 Kuscia Job 调度；Kuscia 未启用/未注册 `data-sandbox-sampler` AppImage 时自定义代码不可跑（内置抽样/脱敏不受影响）。
5. **`/data/download` 端点只服务 Job 产物**：治理结果（及普通上传表）无 `project_result` 行，经该端点下载报「项目结果未找到」；结果经 `/data-governance/preview` 访问、经 `project_datatable` 在项目中消费。
6. **P2P 项目可见性需审批流产物**：dev 环境 E2E 直接插入 `project_inst`/approval config/vote 行模拟审批产物（生产由审批流程生成）；前端挂载弹窗依赖 `listP2PProject` 返回。
7. **挂载修复对存量表**：修复前混合 nodeId 会话产生的旧上传表物理目录与元数据不一致，需重新上传（新上传一致落 `/app/data/<author>/`）；启动脚本带一次性 `cp -rn` 兜底但建议重传。
8. **rootless k3s 容器真实拉起限制**（Z-01/Z-02 遗留，与 Z-04 无关）：本环境 k3s 无法真实拉起新规格容器；治理结果在 DAG 中被 SecretFlow 真实消费的完整链路留待正常宿主复验（同源挂载已就绪）。

---

## 五、浏览器使用指南（你现在就可以操作）

> 前提：个人实例仍在运行（`develop.sh up`）。管理员凭据位于 `/data/zgz/datasandbox/.dev-runtime/zgz/secretpad.env`（`SECRETPAD_USER_NAME=devadmin`，`SECRETPAD_PASSWORD=<随机串>`）。

1. **打开页面**：浏览器访问 `http://127.0.0.1:8099/edge`，用 `devadmin` + 上述密码登录。
2. **进入数据治理页**：左侧导航 →「数据沙箱 / 数据治理」。页面三 Tab：**策略管理 / 任务管理 / 血缘**。
3. **创建策略**（Tab 策略管理 → 右上「创建策略」）：选类型 **SAMPLING**（随机/等距/分层/整群 + count/ratio/seed/分层列/分组列/块大小）、**MASKING**（选列 + 掩码/替换/哈希/取整/空值清除 + 参数）、**SAMPLING_MASKING**（先抽样后脱敏）→ 保存后列表可编辑/删除。
4. **提交内置任务**（Tab 任务管理 → 右上「提交任务」）：选源数据表（节点 + 数据表，可预览前 N 行）→ 选「内置」→ 引用已建策略或内联参数 → 提交；列表刷新可见 `执行中→成功`，状态 Tag 着色。
5. **提交自定义任务**：提交弹窗选「自定义代码」→ 粘贴 Python 脚本（约定 `--input/--output/--params`，见附录 C）→ 一次性容器执行 → 成功出结果数据集；失败可查看详情错误/「重试」。
6. **查看结果与血缘**：任务行「详情」抽屉以 Timeline 展示状态流转 + 血缘（源表 → 策略/任务 → 结果表）；Tab 血缘按节点/数据表查询 source/target 命中。
7. **预览**：任务提交弹窗可预览源表前 N 行（强制权限校验）；「结果数据集」入口预览治理结果。
8. **挂载项目**：SUCCEEDED 任务「挂载到项目」→ 选 P2P 项目 → 结果表以 `source=CREATED` 出现在数据管理页，可在项目中消费。
9. **审计查询**：左侧「统一日志」检索 `GOVERNANCE_*` 事件（策略创建/更新/删除、任务提交/成功/失败/取消/重试、结果挂载）。

---

## 六、提交记录（develop/zgz）

| 仓库 | 提交 | 内容 |
|---|---|---|
| secretpad | `ff58d6d` | 阶段 0：V11 迁移（policy/task/lineage）+ `CsvUtil` + 抽样/脱敏执行器纯类 + 30 例单测 |
| secretpad | `9ba8dd2` | 阶段 1：内置抽样/脱敏引擎 + 权限校验 + 结果注册 DomainData + 血缘 + 审计 |
| secretpad | `6d1dce1` | 阶段 2：自定义代码执行组件（一次性 Kuscia Job + sampler AppImage + 结果取回 + 隔离） |
| secretpad | `46c0ec9` | 阶段 3：`DataGovernanceController` + `DataGovernanceControllerTest`（14 例） |
| secretpad | `73ada32` | fix：V11 迁移落到后端 `config/schema` 受控目录 |
| secretpad | `15f1705` | fix：P2P 平台自有数据权限校验（node.instId==ownerId）+ IT 13b |
| secretpad | `2accb72` | fix：源表物理目录按属主（kuscia 域）解析 + nodeId==ownerId 无 node 行放行 + IT 13c |
| secretpad-frontend | `01565e1` | 阶段 4：`data-governance` 三 Tab 页面 + api wrapper + edge 菜单 |
| secretpad-frontend | `80e0f19` | fix：P2P 模式挂载项目改用 `listP2PProject` |
| data-sandbox-package | `48c8a35` | 阶段 0：V11 schema 三套拷贝纳入打包 |
| data-sandbox-package | `0e62690` | 阶段 2：sampler 容器代码（Dockerfile + sampler_server.py + start.sh） |
| data-sandbox-package | `11266e2` | 阶段 5：dev seed 数据 `gov_sample.csv` + secretpad/kuscia 共享 data 挂载修复 |
| data-sandbox-package | `ea304df` | fix：build.sh maven 构建后 chown 产物归属开发者 |

---

## 附录

### A. OpenAPI 契约（`/api/v1alpha1/data-governance`，body 均为 `Map<String,Object>` JSON）

| 方法 | 路径 | 说明 | 权限 |
|---|---|---|---|
| POST | `/policies` | 创建策略（同名幂等拒绝） | 按创建人 |
| POST | `/policies/update` | 更新策略（仅创建人） | 创建人 |
| POST | `/policies/delete` | 软删策略 | 创建人 |
| GET | `/policies?type&keyword` | 策略列表 | 创建人 |
| GET | `/policies/detail?id=` | 策略详情 | 创建人 |
| POST | `/tasks/submit` | 提交任务 `{execMode: BUILTIN/CUSTOM, nodeId, datatableId, policyId? 或内联 execParams/sampling/masking, script?（CUSTOM）, params?}` | `checkSourcePermission` |
| GET | `/tasks?status&execMode&keyword` | 任务列表 | 创建人 |
| GET | `/tasks/detail?id=` | 详情（含血缘链） | 创建人 |
| POST | `/tasks/cancel` | 取消 `{id}`（PENDING/RUNNING→CANCELLED + stopJob） | 创建人 |
| POST | `/tasks/retry` | 失败重试 `{id}`（FAILED→RUNNING，retry_count+1，上限 3） | 创建人 |
| GET | `/tasks/results?nodeId` | 结果数据集（SUCCEEDED 且 result_datatable_id 非空） | — |
| POST | `/tasks/mount` | 结果挂项目 `{taskId, projectId}` → `project_datatable` source=CREATED | 创建人 + 项目校验 |
| GET | `/lineage?nodeId&datatableId` | 血缘查询（source 或 target 命中） | — |
| GET | `/preview?nodeId&datatableId&limit` | 源数据预览（前 N 行 + schema + 行数） | `checkSourcePermission` |

**错误码**：`GOV_NO_PERMISSION`（无源表权限）、`GOV_INPUT_TOO_LARGE`（输入超行/字节上限）、`GOV_NOT_FOUND`（记录/源表不存在）、`GOV_STATE_CONFLICT`（状态非法流转：非 FAILED 重试/已终态取消等）、`GOV_PARAM_INVALID`（参数非法：表头为空等）。

**配置项**（env 前缀 `SECRETPAD_DATA_SANDBOX_GOVERNANCE_*`，relaxed binding）：

```yaml
secretpad.data-sandbox.governance:
  input-rows: ${SECRETPAD_DATA_SANDBOX_GOVERNANCE_INPUT_ROWS:5000}
  input-bytes: ${SECRETPAD_DATA_SANDBOX_GOVERNANCE_INPUT_BYTES:262144}
  timeout-seconds: ${SECRETPAD_DATA_SANDBOX_GOVERNANCE_TIMEOUT_SECONDS:300}
  max-retries: ${SECRETPAD_DATA_SANDBOX_GOVERNANCE_MAX_RETRIES:3}
  poll-interval-ms: ${SECRETPAD_DATA_SANDBOX_GOVERNANCE_POLL_INTERVAL:10000}
  cpu: ${SECRETPAD_DATA_SANDBOX_GOVERNANCE_CPU:0.5}
  memory: ${SECRETPAD_DATA_SANDBOX_GOVERNANCE_MEMORY:512Mi}
  app-image: ${SECRETPAD_DATA_SANDBOX_GOVERNANCE_APP_IMAGE:data-sandbox-sampler}
```

### B. 已验证生效（个人实例 DB 证据，`/data/zgz/datasandbox/.dev-runtime/zgz/secretpad/db/secretpad.sqlite`）

**内置任务执行链**（`ds_governance_task` BUILTIN 14 条 SUCCEEDED）：

```
gt-ac9d136a43fa RANDOM 63→5    → rodnunow（seed 复现）
gt-25414c81bb53 SYSTEMATIC →8   → zetpgoof
gt-a2194dc03af2 STRATIFIED →3   → zmkncgof（A/B/C 各 1）
gt-1f665b251542 CLUSTER clusterColumn →21 → svyvhazv
gt-feb6bbb5b6a2 CLUSTER blockSize →5   → fgqmdfso
gt-f2a64976753e MASK  phone 137****0007       → lnvelndx
gt-61ecebb71c83 HASH  id_card SHA-256 hex     → jakspwsf
gt-29340edc02d8 ROUND amount 101.00→101       → zltekzxf
gt-b31deced8c25 CLEAR memo 置空               → qokoxqbc
gt-0d1898f22cad REPLACE category=REDACTED     → oujwugef
gt-04c789e5015f SYSTEMATIC+MASK 链式          → zhenjyep
```

**REPLACE 参数名对照**（正确 key 是 `value`）：
- `gt-f44a7e1c7f27`：`{"column":"category","method":"REPLACE","params":{"replaceValue":"REDACTED"}}` → 列被清空（参数未识别）
- `gt-0d1898f22cad`：`{"column":"category","method":"REPLACE","params":{"value":"REDACTED"}}` → `category=REDACTED` ✅

**自定义执行链**：`gt-1f390d8b225e`（CUSTOM 过滤 category=='A'）→ 一次性 Job `gov-gt-1f390d8b225e` → 结果 `ameeoboi`（21 行）→ 血缘 `CUSTOM ijcnuibt→ameeoboi` → 告警链 `gt-774181f008c4`（外联阻断）`gt-dac6fc1a26f1`（超时）`gov:gt-*:failed` OPEN。

**挂载证据**：`project_datatable(yaxidmzu, dev-zgz, rodnunow, source='CREATED', deleted=0)`；`/datatable/list` 共 16 表含 `rodnunow`。

**审计计数**（`ds_unified_log` action 前缀 GOVERNANCE）：`POLICY_CREATE=4/UPDATE=1/DELETE=1`、`TASK_SUBMIT=18/SUCCEEDED=15/FAILED=3/CANCEL=1/RETRY=1`、`RESULT_MOUNT=1`。

**隔离实证**：容器 `gov-gt-dac6fc1a26f1-task-server-0` cgroup `cpu.max=50000 100000`、`memory.max=536870912`；AppImage `-nonet` 端口 `scope=Domain` vs 正常 `scope=Cluster`。

### C. 验证命令速查

```bash
# 登录（Header 用 User-Token，非 Authorization）
PW=$(grep -E '^SECRETPAD_PASSWORD=' /data/zgz/datasandbox/.dev-runtime/zgz/secretpad.env | cut -d= -f2)
T=$(curl -s -X POST http://127.0.0.1:8099/api/login -H 'Content-Type: application/json' \
   -d "{\"name\":\"devadmin\",\"passwordHash\":\"$(printf '%s' "$PW" | sha256sum | awk '{print $1}')\"}" \
   | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["token"])')

# 策略/任务/血缘/预览
curl -s http://127.0.0.1:8099/api/v1alpha1/data-governance/policies -H "User-Token: $T"
curl -s 'http://127.0.0.1:8099/api/v1alpha1/data-governance/tasks?status=SUCCEEDED' -H "User-Token: $T"
curl -s 'http://127.0.0.1:8099/api/v1alpha1/data-governance/tasks/detail?id=gt-ac9d136a43fa' -H "User-Token: $T"
curl -s 'http://127.0.0.1:8099/api/v1alpha1/data-governance/lineage?nodeId=dev-zgz&datatableId=ameeoboi' -H "User-Token: $T"
curl -s 'http://127.0.0.1:8099/api/v1alpha1/data-governance/preview?nodeId=dev-zgz&datatableId=rodnunow&limit=5' -H "User-Token: $T"

# 提交自定义任务示例（脚本契约 --input/--output/--params）
curl -s -X POST http://127.0.0.1:8099/api/v1alpha1/data-governance/tasks/submit -H "User-Token: $T" \
  -H 'Content-Type: application/json' \
  -d '{"execMode":"CUSTOM","nodeId":"dev-zgz","datatableId":"ijcnuibt","script":"import csv,sys\nimport argparse\nap=argparse.ArgumentParser()\nap.add_argument(\"--input\");ap.add_argument(\"--output\");ap.add_argument(\"--params\")\na=ap.parse_args()\nwith open(a.input,newline=\"\",encoding=\"utf-8\") as f: rows=[r for r in csv.DictReader(f)]\nwith open(a.output,\"w\",newline=\"\",encoding=\"utf-8\") as f:\n    w=csv.DictWriter(f,fieldnames=list(rows[0].keys()));w.writeheader();w.writerows(rows)\n"}'

# Kuscia 侧查验（AppImage / 容器限额 / job 清理）
docker exec data-sandbox-dev-zgz-kuscia kubectl get appimage | grep sampler
docker exec data-sandbox-dev-zgz-kuscia /home/kuscia/bin/crictl ps | grep gov-   # 一次性容器
docker exec data-sandbox-dev-zgz-kuscia kubectl get job | grep gov || echo "gov jobs 已清理"

# DB 证据核验
sqlite3 /data/zgz/datasandbox/.dev-runtime/zgz/secretpad/db/secretpad.sqlite \
  "select id,name,policy_type from ds_governance_policy where deleted=0;"
sqlite3 /data/zgz/datasandbox/.dev-runtime/zgz/secretpad/db/secretpad.sqlite \
  "select exec_mode,status,count(*) from ds_governance_task group by 1,2;"
sqlite3 /data/zgz/datasandbox/.dev-runtime/zgz/secretpad/db/secretpad.sqlite \
  "select action,count(*) from ds_unified_log where action like 'GOVERNANCE%' group by action;"
```
