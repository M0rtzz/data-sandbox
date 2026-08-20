# Z-05 JAR、SQL 与 Python 开发能力 · 任务完成报告

> 执行人：zgz ｜ 日期：2026-08-19 ｜ 分支：develop/zgz（secretpad / secretpad-frontend / data-sandbox-package）
> 本报告含：功能完成情况、测试情况、修复情况、浏览器使用指南、已知环境限制。

---

## 一、功能完成情况

Z-05 补齐平台"计算任务开发能力"为零的空白，6 个阶段全部完成：

| 阶段 | 内容 | 产出 | 状态 |
|---|---|---|---|
| 0 | 计划落盘 + V12 迁移 + 纯类 | `claude/plans/Z-05-plan.md`；`V12__data_dev.sql` × center/edge/p2p + package 打包接线；`DevSqlEngine` / `DevDependencyChecker` / `DevJarValidator` + 3 测试类 | ✅ |
| 1 | `DataDevService` 核心 | 制品/版本/依赖 CRUD + SQL 进程内 DEV/PROD 执行 + 任务闭环 + 权限/审计/血缘/挂载 + `DataDevIT` | ✅ |
| 2 | runner 镜像 + AppImage + 执行器 | `data-sandbox-jar-runner` / `data-sandbox-python-runner` / `runner_common`；4 模板（±`-nonet`）+ 2 注册脚本；`DevJobExecutor` + `DataDevCustomIT` | ✅ |
| 3 | 计算任务 API | `DataDevController`（25 端点）+ JAR 多部分上传 + `DataDevControllerTest` | ✅ |
| 4 | 前端 | `modules/data-dev`（制品/任务/SQL 工作台/依赖白名单 4 Tab）+ `DataDevApi` + edge 菜单 | ✅ |
| 5 | 测试数据集 + E2E | 参考 sample JAR（CLI 过滤/聚合）+ 构建脚本；E2E 8 项全过（见下） | ✅ |
| 6 | OpenAPI 契约 + 报告 + 文档同步 | 本报告 + 开发文档接口契约 + CLAUDE.md / 开发文档同步 | ✅ |

**核心行为变化（对用户可见）**：
- 新增「数据开发」页面，可上传/校验/版本化管理 **JAR 制品**（非法文件拒绝、版本自增不可变、参数 Schema + 默认参数、可下载），并在 DEV/PROD 模式运行。
- 新增 **SQL 工作台**：选择源表 → 编辑 SQL → DEV 调试（内嵌 SQLite 进程内执行，结果预览 + 调试日志）→「保存为制品」→ 以 PROD 模式正式运行（结果注册 + 血缘 + 可挂项目）。
- 新增 **Python 函数开发**：脚本编辑 + 依赖白名单（numpy/pandas）；平台侧顶层 import 校验（白名单 ∪ 标准库），runner 侧 `builtins.__import__` 守卫兜底——`import requests` 等在平台被 `DEV_DEPENDENCY_REJECTED` 拒绝，运行期被守卫阻断并给出明确错误 `ImportError: dependency not allowed: requests`。
- 新增 **任务闭环**：提交（DEV 调试 / PROD 正式）→ 运行（JAR/SQL/PYTHON 三类）→ 停止（RUNNING 取消终止运行中容器）→ 重试（FAILED 重跑，`retry_count`+1，调试日志按 attempt 保留）。
- **调试日志不丢失**：runner 执行失败时容器不再立即退出，改为 `/status=failed` 常驻提供 `/log`，平台取回失败原因写入 `ds_dev_run_log`，任务 `error_message` 带真实错误（如 `执行容器失败: py failed rc=1: ImportError: dependency not allowed: requests`，无 `[py]` 前缀）。

---

## 二、测试情况

### 2.1 后端单元/集成测试（67 例新增，全绿）

| 测试类 | 覆盖内容 | 结果 |
|---|---|---|
| `DevSqlEngineTest`（10 例） | 独立 `:memory:` 连接、列名清洗/类型推断、批量 INSERT、`PRAGMA query_only` 写阻断、语句门禁（仅 SELECT/WITH 单语句、禁 PRAGMA/ATTACH/VACUUM/EXPLAIN）、无 LIMIT 追加、`{{param}}` 字面量插值、超时 | ✅ |
| `DevDependencyCheckerTest`（10 例） | 顶层 import 提取、白名单 ∪ 标准库放行、相对导入/多级 import/`from x import y` 处理 | ✅ |
| `DevJarValidatorTest`（5 例） | ZIP 魔数、`META-INF/MANIFEST.MF`、大小上限 | ✅ |
| `DevJobExecutorTest`（5 例，最终批次新增） | `extractFailureReason`：strip `[py]`/`[jar]` 前缀、ImportError/超时回退、空日志 | ✅ |
| `DataDevIT`（11 例，真实 Kuscia mock gRPC） | SQL DEV（预览+日志，无 DomainData/血缘）、SQL PROD（注册+血缘+挂载）、制品 CRUD + 版本自增、JAR 上传校验、PYTHON 依赖拒绝、权限拒绝、状态冲突（取消已成功/重试非失败/挂载无结果） | ✅ |
| `DataDevCustomIT`（7 例，MockKusciaGrpcServer + 本地 HttpServer） | JAR/PYTHON payload 形状、DEV 只预览、PROD 注册+血缘、RUNNING 就绪取回、超时 kill、createJob 失败、Job Failed、retry 成功 attempt=1 | ✅ |
| `DataDevControllerTest`（19 例，MockMvc 真登录） | 20 端点 CRUD/权限拒绝/参数校验/状态冲突/错误码 `DEV_*`/JAR 大小与类型拒绝/预览/结果/日志/挂载 | ✅ |

### 2.2 前端构建

`pnpm --filter secretpad build` 全部通过（阶段 4 数据开发页 + `DataDevApi` + prettier 规范化）。

### 2.3 个人实例端到端（data-sandbox-package · develop.sh 方法）

个人私有实例：后端 `127.0.0.1:8099`，Kuscia 容器 `data-sandbox-dev-zgz-kuscia`，管理员 `devadmin`，源表 `gov_bank_sample`（qpfcjppm，100 行银行数据）。

| # | E2E 项 | 结果 | 说明 |
|---|---|---|---|
| 1 | JAR 上传+校验+版本+DEV/PROD | ✅ | 非法文件拒绝；版本自增；DEV 调试（日志+结果预览，无结果表）；PROD 运行注册结果 `wuwmmftv` + 血缘 + 挂项目 source=CREATED |
| 2 | SQL 编辑→执行→预览→保存→PROD | ✅ | DEV 预览+日志；「保存为制品」落 SQL 版本；PROD 注册结果 `xvfndvcr` + 血缘 + 挂载 |
| 3 | Python 白名单/拒绝/守卫 | ✅ | numpy/pandas 白名单放行；`import requests` 平台侧 `DEV_DEPENDENCY_REJECTED`；隐藏运行期导入被 runner 守卫阻断 → FAILED + 日志明确（最终复验 `dt-948f15d61017`） |
| 4 | 停止/重试 | ✅ | RUNNING 取消→CANCELLED 且 **运行中 pod 被终止**（kubectl 可见 Terminating→gone，`dt-9d0cda0bf5f2`）；FAILED 重试→`retry_count=1` + `run_log attempt=1`（`dt-e97267e73024`） |
| 5 | 权限 | ✅ | carol 提交未授权表→`DEV_NO_PERMISSION`；非创建人 dev1 删制品/重试→`DEV_NO_PERMISSION`（创建人可删） |
| 6 | 审计 | ✅ | `ds_unified_log` 记录 `DEV_TASK_SUBMIT/FAILED/DEBUG_SUCCEEDED/SUCCEEDED/CANCEL/RETRY/LINEAGE`、`DEV_ARTIFACT_CREATE/DELETE/VERSION_CREATE/VERSION_UPLOAD`、`DEV_RESULT_MOUNT` |
| 7 | 血缘 | ✅ | PROD SQL/JAR/PYTHON 任务详情均返回 source→target 链（qpfcjppm→xvfndvcr/wuwmmftv/hdiaplsf）；挂载 + 重复挂载拒绝 `DEV_STATE_CONFLICT: 结果已挂载到该项目` |
| 8 | 隔离 | ✅ | pod resources cpu=500m/memory=512Mi、hostNetwork=None、hostPID=None、restartPolicy=Never；`-nonet` AppImage `endpoints: []`（无 Cluster 端口=结果不可取回，隔离对照）；取回后 Job 删除（无残留 `dt-*` job/pod） |

最终批次重建后复验两项修复：**error_message 无 `[py]` 前缀**（`执行容器失败: py failed rc=1: ImportError: dependency not allowed: requests`）＋ **取消终止运行中 pod**（deleteJob 后 pod Terminating→空）。

---

## 三、修复情况（本任务内发现并修复的问题）

| # | 问题 | 根因 | 修复 | 提交 |
|---|---|---|---|---|
| 1 | **runner 执行失败即退出 → 调试日志丢失** | 容器非零退出后 Job 直接 FAILED，`/log` 不可取回，`ds_dev_run_log` 为空 | runner 失败不退出，`/status` 返回 `"failed"` 常驻提供 `/log`；executor `finalizeIfReady` 检查 `/status`，取回失败原因写 run_log、以明确原因标记 FAILED | secretpad `c861e86` + package `7d48eff` |
| 2 | **error_message 带 `[py] `/`[jar] ` 前缀** | `extractFailureReason` 正则 `^\\[[a-z]{3}\\]` 只匹配 3 字符前缀 | 改 `^\\[[^]]*\\]`；并将方法提为 package-private static 便于单测 | secretpad `c861e86` |
| 3 | **cancel 后运行中 pod 泄漏** | cancelTask 只 `stop()`（不终止运行中容器），未 `delete()` | `stop` 后调用 `delete(jobId)`（kuscia deleteJob 才终止 pod） | secretpad `c861e86` |
| 4 | **jar 镜像缺 Python** | `eclipse-temurin` 基础镜像无 python，AppImage 命令为 `python jar_runner.py` | Dockerfile `apt install python3` + `python` symlink | package `7d48eff` |
| 5 | **run_subprocess 错误信息不明确** | 只报 `failed rc=N`，无真实错误 | 异常带 stdout 最后一行（如 `ImportError: dependency not allowed: xxx`） | package `7d48eff` |
| 6 | **参数传递用文件路径** | `--params`/`DS_PARAMS_JSON` 传路径而非内容 | 改内联 `json.dumps(params)` | package `7d48eff` |
| 7 | **import 守卫误伤白名单传递依赖** | pandas 依赖 dateutil/pytz/tzdata/six 等不在 allowed_imports | guard 放行 `pkgutil.iter_modules()` 已安装包集（硬边界=镜像预装集，未装包如 requests 仍被拒） | package `7d48eff` |
| 8 | **构建失败：`finalizeIfReady` 缺 `taskId` 局部变量** | 引用不存在的局部变量 | 方法顶部补 `String taskId = string(task.get("id"))` | secretpad `e699432` |
| 9 | **E2E 断言/客户端缺陷** | dsdev.py 登录 `_call` 引用未赋值 token；脚本用 camelCase 字段（API 返回 snake_case）；carol/dev1 密码经 docker sqlite3 重置失效 | `getattr(self,"token",None)`；E2E 脚本字段对齐；host python sqlite3 直改 DB | E2E 脚本（不入库） |

**E2E 未发现新的后端代码逻辑缺陷**（制品/版本状态机、任务状态机、权限校验、SQL 进程内执行、血缘、挂载等全部符合预期）。

---

## 四、已知环境限制（重要）

1. **JAR 传递走 `task_input_config` base64**：默认上限 `DEV_JAR_BYTES:48MB`（base64≈64MB），超限 `DEV_INPUT_TOO_LARGE`；上限可配。E2E 用约 1MB 级 sample jar 验证，Kuscia config 对大体积 base64 的实际可承载上限未在个人环境实测——大体积 JAR 需调配置并在正常环境验证。
2. **JAR 运行契约**：CLI 程序把结果 CSV 写 `--output` 或 stdout（兜底）；长驻服务超时会 kill → FAILED。契约已写入前端 tooltip 与参考 sample jar 演示。
3. **SQL 引擎 = 平台内嵌 SQLite（进程内）**：只读（`PRAGMA query_only` + 语句门禁仅 SELECT/WITH 单语句 + LIMIT + `setQueryTimeout` 多层防护），SQL 方言为 SQLite，非生产 SQL 引擎。
4. **Python 依赖白名单与镜像预装包耦合**：新增白名单条目须重建 `data-sandbox-python-runner` 镜像并重新导入 Kuscia containerd（镜像无网络、禁 pip）。
5. **`-nonet` AppImage 变体无 Cluster 端点**：结果不可被平台取回（隔离对照用途）；正常任务用 `network_policy=GOVERNANCE`。
6. **DEV 结果预览面向创建人本人调试**：输入已授权、代码自有；`viewResult` 仍限创建人 + SUCCEEDED。
7. **结果挂载到 P2P 项目依赖审批流产物**（`project_inst`+approval config+vote 行，dev 模拟）——同 Z-04 限制。

---

## 五、浏览器使用指南（你现在就可以操作）

> 前提：个人实例仍在运行。管理员凭据位于 `/data/zgz/datasandbox/.dev-runtime/zgz/secretpad.env`（`SECRETPAD_USER_NAME=devadmin`，`SECRETPAD_PASSWORD=<随机串>`）。

1. **打开页面**：浏览器访问 `http://127.0.0.1:9099`，用 `devadmin` + 上述密码登录，左侧导航出现「数据开发」。
2. **制品管理（Tab 1）**：点「新建制品」→ 选类型（JAR/SQL/PYTHON）。JAR：上传 `.jar` 文件 + 参数 Schema/默认参数 JSON；SQL/PYTHON：脚本编辑器保存。版本自增不可变，「版本」列可查看/下载 JAR、回看脚本。
3. **SQL 工作台（Tab 3）**：选源节点+源表 → 输入 SQL → 点「执行」→ 结果预览 + 调试日志；可「保存为制品」供 PROD 复用。
4. **任务管理（Tab 2）**：点「提交任务」→ 选运行模式 DEV/PROD + 类型 + 制品/内联脚本 + 源表 + 参数 → 提交。
   - DEV 成功 →「调试日志」抽屉（runLog + 结果预览表，仅调试用）；
   - PROD 成功 →「结果」抽屉（结果数据前 100 行）+「挂载项目」；
   - RUNNING →「取消」；FAILED →「重试」（`retry_count` 递增，日志按 attempt 保留）；「详情」看血缘 Timeline + 脚本快照 + 错误。
5. **依赖白名单（Tab 4）**：管理 numpy/pandas 白名单（新增条目须重建 runner 镜像，见"已知限制"）。

---

## 六、提交记录（develop/zgz）

| 仓库 | 提交 | 内容 |
|---|---|---|
| secretpad | `0b7c142` | Stage 0：V12 迁移 + 纯类 DevSqlEngine/DevDependencyChecker/DevJarValidator + 3 单测类 |
| secretpad | `e699432` | Stage 1：DataDevService 制品/版本/依赖/任务闭环 + DevJobExecutor + DataDevIT |
| secretpad | `f3b8e1d` | Stage 2：jar/python runner AppImage 模板（±`-nonet`）+ 注册脚本 + DataDevCustomIT |
| secretpad | `8e0fba9` | Stage 3：计算任务 API DataDevController + 多部分上传 + DataDevControllerTest |
| secretpad | `cc818fe` | Stage 5：V12 迁移落位根 config/schema（补齐 develop.sh 镜像构建所需迁移源） |
| secretpad | `c861e86` | 最终修复：取消终止运行中 pod（deleteJob）+ 失败原因 strip `[py]`/`[jar]` 前缀 + DevJobExecutorTest |
| secretpad-frontend | `c610bb9` | Stage 4：数据开发页面（制品/任务/SQL 工作台/依赖白名单）+ DataDevApi + edge 菜单 |
| data-sandbox-package | `2fa7e31` | Stage 0：V12__data_dev.sql 迁移纳入打包 |
| data-sandbox-package | `3c0c00a` | Stage 2：计算任务 runner 容器（jar/python + runner_common）+ 构建脚本 |
| data-sandbox-package | `be0231b` | Stage 5：参考 sample JAR（CLI 过滤/聚合）与构建脚本 |
| data-sandbox-package | `7d48eff` | 最终修复：runner 失败常驻提供 /log（/status=failed）+ 错误行透传 + 参数内联 JSON + jar 镜像补 python3 |
