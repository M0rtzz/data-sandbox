# Z-01 真实沙箱运行时 · 任务完成报告

> 执行人：zgz ｜ 日期：2026-08-18 ｜ 分支：develop/zgz（secretpad / secretpad-frontend / data-sandbox-package）
> 本报告含：功能完成情况、测试情况、修复情况、浏览器使用指南、已知环境限制。

---

## 一、功能完成情况

Z-01 把"假运行的沙箱"改造成"真实 Kuscia 沙箱运行时"，6 个阶段全部完成：

| 阶段 | 内容 | 产出 | 状态 |
|---|---|---|---|
| A | 合并 xzh 基线 | merge develop/xzh，MVP 页面可用 | ✅ |
| B | 运行时真实化 + 状态同步 | `SandboxStatusMachine`（纯函数状态机）、START/STOP/DESTROY 落真实 Kuscia Job、`syncKusciaStatuses` 意图保护、失败路径明确报错、V7 迁移 | ✅ |
| C | AppImage 制作与注册 | 3 个模板（Jupyter/JAR/SecretFlow）+ 注册脚本，镜像导入 Kuscia containerd | ✅ |
| D | 开发端点与鉴权跳板 | `POST /sandboxes/dev-token`（一次性 30min token，DB 存 sha256）+ `SandboxProxyController` 双向流式跳板（HTTP + WebSocket），token 校验 + owner 校验 + 防 SSRF（目标仅限 DB endpoint） | ✅ |
| E | 前端入口 UI | "开发环境"按钮、"端点"列、状态颜色增强、启动提示 | ✅ |
| F | 端到端验证 | 个人实例（8099）+ E2E 清单 9 步（见下） | ✅（容器实际启动受环境限制，见"已知限制"） |

**核心行为变化（对用户可见）**：
- 点"启动"不再直接置 RUNNING，而是 `STARTING →（同步 Kuscia Job 真实状态）→ RUNNING`，失败置 ERROR 并给出明确原因（如"Kuscia 运行时未启用"）。
- 沙箱 RUNNING 后可从"端点"列看到 Kuscia 分配的真实访问地址，"开发环境"按钮签发一次性 token 后新标签页打开 Jupyter / SecretFlow / JAR 环境。
- 到期自动真实停止 Kuscia Job 后才置 EXPIRED；销毁真实删除 Job；快照生成真实产物文件 + 校验和。

---

## 二、测试情况

### 2.1 后端单元/集成测试（41 例新增，全绿）

| 测试类 | 覆盖内容 | 结果 |
|---|---|---|
| `SandboxStatusMachineTest`（18 例） | 全状态流转表：各状态能否执行各 action、Kuscia 状态受保护映射、终态判定 | ✅ |
| `DataSandboxKusciaIT`（11 例，真实 Kuscia mock gRPC） | START 成功链路（STARTING→RUNNING+endpoint+intent 清空）、createJob 失败→ERROR 非 RUNNING、kuscia 未启用→ERROR、"RUNNING+job PENDING 不被打回 STARTING"回归、STARTING+FAILED→ERROR、STOP 终态→STOPPED、stopJob 失败→ERROR、到期 stop 成功→EXPIRED/失败→ERROR、销毁→deleted | ✅ |
| `DataSandboxKusciaDisabledIT`（4 例） | kuscia.enabled=false 时各操作行为 | ✅ |
| `DataSandboxControllerTest`（8 例，MockMvc） | dev-token：未登录/非 owner/非 RUNNING 明确错误、签发成功；proxy：无 token/过期/沙箱非 RUNNING/无 endpoint 拒绝、正确转发（本地 HttpServer 模拟容器，断言 body 与路径无 token 泄漏） | ✅ |

全量回归：**356 例，347 绿；9 例失败均为 pre-existing**（`LoginInterceptorTest` 1 例、`ModelManagementControllerTest` 8 例——均为历史遗留文案/错误码断言未同步，经 git 历史核实与本次改动零交集）。

### 2.2 前端构建

`pnpm --filter secretpad build` 4 项目全部通过（阶段 E 改动 + prettier 规范化）。

### 2.3 个人实例端到端（data-sandbox-package · develop.sh 方法）

个人私有实例：后端 `127.0.0.1:8099`，Kuscia 容器 `data-sandbox-dev-zgz-kuscia`，管理员 `devadmin`。

| # | E2E 项 | 结果 | 说明 |
|---|---|---|---|
| 1 | 创建沙箱（Jupyter） | ✅ | 状态 STOPPED，资源/网络策略正确落库 |
| 2 | 启动 | ✅ | STARTING→Kuscia Job `ds-sbx-*` 真实创建（kubectl 可见 phase=Running）→ 30s 同步→RUNNING+endpoint 提取，intent 清空 |
| 3 | 打开开发环境 | ✅ 鉴权全过 / ⚠️ 容器未真正可连 | dev-token 签发 URL+30min；proxy 无 token→`202011602 缺少凭证`、错误 token→`无效或已失效`、过期 token→`无效或已失效`、有效 token→转发（目标不可达时明确 502，非 500/崩溃）；DB 中 token 为 sha256 明文不落库 |
| 4 | 停止 | ✅ | STOPPING→Kuscia Job 终态→STOPPED，intent 清空 |
| 5 | 续期 7 天 | ✅ | expires_at 正确 +7 天 |
| 6 | 快照 | ✅ | 快照 COMPLETED，产物文件 + md5 校验和匹配 |
| 7 | 销毁 | ✅ | DESTROYED + 软删除（deleted=1），列表隐藏，Kuscia Job 删除 |
| 8 | 强制一致性检查 | ✅ | `select id,status,intent,kuscia_job_state,endpoint from ds_sandbox where deleted=0` 无"假 RUNNING" |
| 9 | JAR / SecretFlow 镜像各跑一遍创建+启动+停止+销毁 | ✅ | `kuscia_app_image` 映射正确（data-sandbox-jar / data-sandbox-secretflow），端点端口名正确（`app` / `web`） |

3 个 AppImage 注册成功，3 个镜像（scipy-notebook、eclipse-temurin、secretflow-anolis8）全部导入 Kuscia containerd。

---

## 三、修复情况（本任务内发现并修复的问题）

| # | 问题 | 根因 | 修复 | 提交 |
|---|---|---|---|---|
| 1 | Kuscia 容器 host IP 探测失败循环重启 | rootless docker 自动探测宿主 IP 失败 | develop.sh 探测私有网桥网关注入 `KUSCIA_HOST_IP` | `64e8874` |
| 2 | AppImage 注册校验失败（`image.id must be string`、`workingDir Required`） | 模板 `image.id: 0` 整数、jar 模板缺 workingDir | 模板字符串化 + 补 workingDir | `863a42f` |
| 3 | 注册脚本 TTY 报错 | `docker exec -it` 在非 TTY 环境报错 | 去除 `-it` | `863a42f` |
| 4 | package 镜像缺 V7 迁移列 | build.sh/Dockerfile 只带 V6 | 补 V7 复制 | `a460496` |
| 5 | E2E 中发现：SecretPad 容器无法解析 Kuscia Cluster 端点（svc 名） | 0.13.0b0 `scope=Cluster` 回填 `*.svc` 名，SecretPad 在 docker 网桥侧不可达 | 属部署网络配置项，跳板已返回明确 502；正常部署需配置路由或 Domain scope（见"已知限制"） | — |

**E2E 未发现新的后端代码逻辑缺陷**（状态机、鉴权、跳板、软删除、快照等全部符合预期）。

---

## 四、已知环境限制（重要）

当前开发宿主为 **rootless docker（用户 996）**，cgroup 仅 delegate `memory+pids`（缺 `cpu` 控制器），且本用户无 root/sudo、不在 docker 组、无法访问 rootful dockerd。影响：

1. **Kuscia 的 k3s 无法创建任何容器**（连 sandbox pause 容器都失败，错误 `runc ... cpu.weight: no such file or directory` / `can't get final child's PID from pipe: EOF`）。因此沙箱 Job 能真实创建、状态同步正确、endpoint 能提取，但**容器进程未实际启动**。已确认该限制为环境级（非代码缺陷）：手动 runc 无 CPU 配置可成功，缺的就是 cpu controller。
   - **解决路径**：在 rootful docker 或具备 cpu controller 的宿主上运行同一 develop.sh 实例，即可完成容器真实拉起。

2. **endpoint 可路由性**：Kuscia 0.13.0b0 `scope=Cluster` 端口回填 `*.dev-zgz.svc` 名，SecretPad 容器（docker 网桥）默认无法解析/路由到 k3s 集群网络。正常部署需二选一：① SecretPad 容器所在网络可路由到 Kuscia 集群网段；② AppImage 端口改用 `Domain` scope 让 Kuscia 回填可路由地址（需在正常环境实测回填格式后再固化模板）。
   - 跳板在目标不可达时返回明确 `502`（错误在 SecretPad 层可观测），不会泄露内部错误。

---

## 五、浏览器使用指南（你现在就可以操作）

> 前提：个人实例仍在运行。管理员凭据位于 `/data/zgz/datasandbox/.dev-runtime/zgz/secretpad.env`（`SECRETPAD_USER_NAME=devadmin`，`SECRETPAD_PASSWORD=<随机串>`）。

1. **打开页面**：浏览器访问 `http://127.0.0.1:8099/edge`，右上角用 `devadmin` + 上述密码登录。
2. **进入沙箱管理**：左侧导航 →「数据沙箱 / Sandbox 管理」。
3. **创建沙箱**：点「新建沙箱」→ 填名称、选镜像（Jupyter SciPy / SecretFlow Runtime / Java Runtime (JAR)）、选核数/内存/有效期/网络策略 → 提交。列表出现新记录，状态 `STOPPED`。
4. **启动**：点「启动」。状态先 `STARTING`（约 30 秒内，后台同步 Kuscia Job），随后转 `RUNNING`。「端点」列出现 Kuscia 分配的访问地址。
5. **进入开发环境**：状态 `RUNNING` 且端点非空时，「操作」列出现「开发环境」按钮 → 点击后新标签页签发一次性 token 打开 Jupyter / SecretFlow / JAR 环境。（当前环境因上述限制容器未真正起，按钮会打开但跳板返回 502——这是已知环境限制；在正常环境即可直接进入。）
6. **停止 / 续期 / 快照 / 销毁**：对应「操作」列按钮。停止走真实 Job 终止；续期延长有效期；快照生成可下载产物；销毁需确认后软删除并回收配额。

---

## 六、提交记录（develop/zgz）

| 仓库 | 提交 | 内容 |
|---|---|---|
| secretpad | `7a5f248` | 阶段 B/C/D 后端核心（状态机/Job 同步/跳板/dev-token/V7 迁移/4 测试类） |
| secretpad-frontend | `efe2dc4` | 阶段 E 前端（开发环境按钮/端点列/状态增强） |
| secretpad | `863a42f` | AppImage 模板与注册脚本修复 |
| data-sandbox-package | `a460496` | V7 迁移打包修复 |
| data-sandbox-package | `64e8874` | develop.sh KUSCIA_HOST_IP 注入 |
