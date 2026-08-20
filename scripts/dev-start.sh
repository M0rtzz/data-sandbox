#!/usr/bin/env bash
# =============================================================================
# 数据沙箱开发环境：启动前端 + 后端（zgz 个人实例）
#
#   后端 : data-sandbox-dev-zgz-secretpad 容器（提供 8099，连 Kuscia + 私有 SQLite）
#   前端 : secretpad-frontend apps/platform 的 umi dev server（9099，代理 /api → 8099）
#
# 用法:
#   ./dev-start.sh [--frontend-only] [--backend-only]
#   ./dev-start.sh --status           查看当前运行状态
#
# 访问:
#   http://127.0.0.1:9099   前端开发入口（热更新，/api 代理到后端 8099）
#   http://127.0.0.1:8099   后端（含打包的静态资源，可直接访问完整平台）
#
# 停止: 见 dev-stop.sh
# =============================================================================
set -euo pipefail

WORKSPACE="${DATA_SANDBOX_WORKSPACE:-/data/zgz/datasandbox}"
FRONTEND_DIR="${WORKSPACE}/secretpad-frontend"
PLATFORM_DIR="${FRONTEND_DIR}/apps/platform"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
PID_FILE="${LOG_DIR}/frontend-dev.pid"

DEV_PORT=9099
BACKEND_PORT=8099
SECRETPAD_CTR="data-sandbox-dev-zgz-secretpad"
KUSCIA_CTR="data-sandbox-dev-zgz-kuscia"

log()  { echo -e "\033[1;34m[dev]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[dev]\033[0m $*"; }
warn() { echo -e "\033[1;33m[dev]\033[0m $*"; }
err()  { echo -e "\033[1;31m[dev]\033[0m $*" >&2; }

require_docker() {
    command -v docker >/dev/null 2>&1 || { err "未找到 docker，请先安装/进入开发环境。"; exit 1; }
}

is_running() { docker ps --format '{{.Names}}' | grep -qx "$1" 2>/dev/null; }

port_in_use() { ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":${1}\$"; }

# ----------------------------------------------------------------------------
# 后端（容器版 secretpad + 依赖的 Kuscia）
# ----------------------------------------------------------------------------
start_backend() {
    require_docker
    for ctr in "$KUSCIA_CTR" "$SECRETPAD_CTR"; do
        if is_running "$ctr"; then
            ok "后端容器 ${ctr} 已在运行"
        elif docker ps -a --format '{{.Names}}' | grep -qx "$ctr"; then
            warn "${ctr} 处于停止状态，执行 docker start ..."
            docker start "$ctr" >/dev/null
            ok "已启动 ${ctr}"
        else
            err "${ctr} 不存在。请先通过 data-sandbox-package/develop.sh up 初始化个人实例。"
            exit 1
        fi
    done
    # 等待后端健康
    for _ in $(seq 1 60); do
        if curl -sf "http://127.0.0.1:${BACKEND_PORT}/api/v1alpha1/data-sandbox/images" >/dev/null 2>&1; then
            ok "后端就绪：http://127.0.0.1:${BACKEND_PORT}"
            return 0
        fi
        sleep 1
    done
    err "后端 ${BACKEND_PORT} 未在 60s 内就绪，查看容器日志：docker logs ${SECRETPAD_CTR}"
    exit 1
}

# ----------------------------------------------------------------------------
# 前端（umi dev server）
# ----------------------------------------------------------------------------
write_env() {
    local env_file="${PLATFORM_DIR}/.env"
    if [ -f "$env_file" ] && grep -q 'PROXY_URL' "$env_file"; then
        ok "前端代理配置已存在：$(grep PROXY_URL "$env_file")"
    else
        # 保留用户已有配置（若没有 PROXY_URL 则追加）
        { [ -f "$env_file" ] && cat "$env_file"; echo "PROXY_URL=http://127.0.0.1:${BACKEND_PORT}"; } > "${env_file}.new"
        mv "${env_file}.new" "$env_file"
        ok "已写入 ${env_file}（/api 代理 → ${BACKEND_PORT}）"
    fi
}

start_frontend() {
    [ -d "$PLATFORM_DIR" ] || { err "前端目录不存在：${PLATFORM_DIR}"; exit 1; }
    [ -d "$FRONTEND_DIR/node_modules" ] || { err "前端依赖未安装，请先执行：cd ${FRONTEND_DIR} && pnpm install"; exit 1; }

    if port_in_use "$DEV_PORT"; then
        warn "前端端口 ${DEV_PORT} 已被占用，可能已在运行（跳过启动）。"
        return 0
    fi

    mkdir -p "$LOG_DIR"
    write_env

    cd "$PLATFORM_DIR"
    nohup env PORT="$DEV_PORT" pnpm dev >"${LOG_DIR}/frontend-dev.log" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"
    ok "前端 dev server 启动中（pid ${pid}，日志 ${LOG_DIR}/frontend-dev.log）"

    for _ in $(seq 1 90); do
        if port_in_use "$DEV_PORT"; then
            ok "前端就绪：http://127.0.0.1:${DEV_PORT}"
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            err "前端进程异常退出，查看日志：${LOG_DIR}/frontend-dev.log"
            exit 1
        fi
        sleep 1
    done
    err "前端 ${DEV_PORT} 未在 90s 内就绪，查看日志：${LOG_DIR}/frontend-dev.log"
    exit 1
}

status() {
    echo "===== 数据沙箱开发环境状态 ====="
    echo -n "后端 ${BACKEND_PORT} (secretpad 容器): "
    if is_running "$SECRETPAD_CTR"; then echo "运行中"; else echo "停止"; fi
    echo -n "Kuscia 容器: "
    if is_running "$KUSCIA_CTR"; then echo "运行中"; else echo "停止"; fi
    echo -n "前端 ${DEV_PORT} (umi dev): "
    if port_in_use "$DEV_PORT"; then echo "运行中"; else echo "停止"; fi
    echo "前端日志: ${LOG_DIR}/frontend-dev.log"
}

# ----------------------------------------------------------------------------
mode_frontend=1
mode_backend=1
for arg in "$@"; do
    case "$arg" in
        --frontend-only) mode_backend=0 ;;
        --backend-only)  mode_frontend=0 ;;
        --status) status; exit 0 ;;
        *) err "未知参数: $arg（支持 --frontend-only / --backend-only / --status）"; exit 1 ;;
    esac
done

if [ "$mode_backend" = 1 ]; then start_backend; fi
if [ "$mode_frontend" = 1 ]; then start_frontend; fi

echo
ok "完成。开发环境已就绪："
echo "   前端入口 : http://127.0.0.1:${DEV_PORT}   （热更新，/api 自动代理到后端）"
echo "   后端直连 : http://127.0.0.1:${BACKEND_PORT}"
echo "   停止环境 : ./dev-stop.sh"
