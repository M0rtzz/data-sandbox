#!/usr/bin/env bash
# =============================================================================
# 数据沙箱开发环境：停止前端 + 后端（zgz 个人实例）
#
#   停止顺序：前端 dev server（9099）→ secretpad 后端容器（8099）
#   Kuscia 容器保留不停止（后端依赖它，重启可快速恢复）
#
# 用法:
#   ./dev-stop.sh [--frontend-only] [--backend-only]
#   ./dev-stop.sh --force            前端进程异常时强制清理（pkill 兜底）
#   ./dev-stop.sh --status           查看当前运行状态（同 dev-start.sh --status）
# =============================================================================
set -uo pipefail

WORKSPACE="${DATA_SANDBOX_WORKSPACE:-/data/zgz/datasandbox}"
FRONTEND_DIR="${WORKSPACE}/secretpad-frontend"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
PID_FILE="${LOG_DIR}/frontend-dev.pid"

DEV_PORT=9099
SECRETPAD_CTR="data-sandbox-dev-zgz-secretpad"
KUSCIA_CTR="data-sandbox-dev-zgz-kuscia"

log()  { echo -e "\033[1;34m[dev]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[dev]\033[0m $*"; }
warn() { echo -e "\033[1;33m[dev]\033[0m $*"; }
err()  { echo -e "\033[1;31m[dev]\033[0m $*" >&2; }

is_running() { docker ps --format '{{.Names}}' | grep -qx "$1" 2>/dev/null; }

port_in_use() { ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":${1}\$"; }

# 递归向进程及其所有子孙发送信号（先子后父），pnpm dev 的 umi/esbuild 子进程
# 不会随 pnpm 收到 SIGTERM 而级联退出，必须逐级清理。
kill_subtree() {
    local root="$1" sig="${2:-TERM}" child
    for child in $(ps -o pid= --ppid "$root" 2>/dev/null); do
        kill_subtree "$child" "$sig"
        kill -"$sig" "$child" 2>/dev/null || true
    done
    kill -"$sig" "$root" 2>/dev/null || true
}

stop_frontend() {
    # 1) pid 文件精准停止（整棵进程树）
    if [ -f "$PID_FILE" ]; then
        local pid
        pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill_subtree "$pid" TERM
            ok "已向前端 dev server 进程树发送停止信号（pid ${pid}）"
        fi
        rm -f "$PID_FILE"
    fi

    # 2) 等待端口释放
    for _ in $(seq 1 15); do
        if ! port_in_use "$DEV_PORT"; then
            ok "前端已停止（端口 ${DEV_PORT} 已释放）"
            return 0
        fi
        sleep 1
    done

    # 3) 超时仍未停止 → 强制终止（按 zgz 工作区路径精确匹配，不影响 xzh 或其他实例）
    if [ "${FORCE:-0}" = 1 ]; then
        warn "前端未正常退出，执行强制清理（${FRONTEND_DIR}）..."
        pkill -f "^${FRONTEND_DIR}" 2>/dev/null || true
        pkill -f '^node .*pnpm dev$' 2>/dev/null || true
        sleep 2
        if ! port_in_use "$DEV_PORT"; then
            ok "前端已强制停止"
        else
            err "端口 ${DEV_PORT} 仍被占用，请手动检查：lsof -i :${DEV_PORT}"
        fi
    else
        warn "前端未在 15s 内停止。可再次执行 ./dev-stop.sh --force 强制清理。"
    fi
}

stop_backend() {
    command -v docker >/dev/null 2>&1 || { err "未找到 docker，跳过后端容器停止。"; return 1; }
    if is_running "$SECRETPAD_CTR"; then
        docker stop "$SECRETPAD_CTR" >/dev/null
        ok "已停止 secretpad 后端容器 ${SECRETPAD_CTR}"
    else
        ok "secretpad 后端容器未在运行"
    fi
    if is_running "$KUSCIA_CTR"; then
        log "Kuscia 容器 ${KUSCIA_CTR} 保持运行（后端依赖，未停止）"
    fi
}

# ----------------------------------------------------------------------------
mode_frontend=1
mode_backend=1
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --frontend-only) mode_backend=0 ;;
        --backend-only)  mode_frontend=0 ;;
        --force)         FORCE=1 ;;
        --status)
            "${SCRIPT_DIR}/dev-start.sh" --status
            exit $?
            ;;
        *) err "未知参数: $arg（支持 --frontend-only / --backend-only / --force / --status）"; exit 1 ;;
    esac
done

if [ "$mode_frontend" = 1 ]; then stop_frontend; fi
if [ "$mode_backend" = 1 ]; then stop_backend; fi

ok "停止完成。启动环境请执行：./dev-start.sh"
