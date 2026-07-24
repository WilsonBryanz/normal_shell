#!/bin/sh
#=============================================================================
# Gost Forward Manager - 一键卸载脚本
# 版本: v2.3.1
# 适用: OpenWrt / iStoreOS (x86_64)
# 功能: 完整清理 Gost Forward Manager 所有部署文件、cron 任务、
#       sysupgrade 持久化配置及 LuCI 缓存
#=============================================================================

set -e

#=============================================================================
# 颜色输出函数
#=============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

#=============================================================================
# 步骤 1: 权限检查
#=============================================================================
log_info "=========================================="
log_info "  Gost Forward Manager 一键卸载脚本 v2.3.0"
log_info "=========================================="
echo ""

log_info "步骤 1/8: 检查运行权限..."
if [ "$(id -u)" -ne 0 ]; then
    log_error "此脚本需要 root 权限运行，请使用: sudo sh uninstall-gost-forward.sh"
    exit 1
fi
log_success "root 权限检查通过"

#=============================================================================
# 步骤 2: 停止并禁用服务
#=============================================================================
log_info "步骤 2/8: 停止并禁用 gost-forward 服务..."

SERVICE_STOPPED=false
if [ -f /etc/init.d/gost-forward ]; then
    if /etc/init.d/gost-forward status >/dev/null 2>&1; then
        /etc/init.d/gost-forward stop >/dev/null 2>&1 && log_success "gost-forward 服务已停止" || log_warn "停止服务时出现警告（可能服务未在运行）"
        SERVICE_STOPPED=true
    else
        log_info "gost-forward 服务未在运行，跳过停止步骤"
    fi
    /etc/init.d/gost-forward disable >/dev/null 2>&1 && log_success "gost-forward 服务已禁用" || log_warn "禁用服务时出现警告"
else
    log_info "未找到 gost-forward 服务脚本，跳过服务停止步骤"
fi

#=============================================================================
# 步骤 3: 删除部署文件
#=============================================================================
log_info "步骤 3/8: 删除部署文件..."

# 定义所有需要删除的文件和目录
FILES_TO_REMOVE="
/etc/gost-forward
/usr/bin/uu
/usr/sbin/uu
/usr/bin/gost-forward
/usr/bin/gost
/usr/libexec/gost-forward-web
/usr/libexec/gost-forward-tcping
/etc/init.d/gost-forward
/usr/lib/lua/luci/controller/gost_forward_web.lua
/usr/lib/lua/luci/view/gost-forward-web
"

REMOVED_COUNT=0
SKIPPED_COUNT=0

for item in $FILES_TO_REMOVE; do
    if [ -e "$item" ]; then
        rm -rf "$item"
        log_success "已删除: $item"
        REMOVED_COUNT=$((REMOVED_COUNT + 1))
    else
        log_info "不存在，跳过: $item"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    fi
done

echo ""
log_info "文件清理完成: 已删除 ${REMOVED_COUNT} 项, 跳过 ${SKIPPED_COUNT} 项"

#=============================================================================
# 步骤 4: 清理 cron 任务
#=============================================================================
log_info "步骤 4/8: 清理 cron 定时任务..."

CRON_FILE="/etc/crontabs/root"
CRON_MARKERS="gost-forward-expire gost-forward-snapshot uu-expire uu-snapshot"

if [ -f "$CRON_FILE" ]; then
    CRON_CLEANED=0
    for marker in $CRON_MARKERS; do
        if grep -q "# ${marker}" "$CRON_FILE" 2>/dev/null; then
            sed -i "/# ${marker}/d" "$CRON_FILE"
            log_success "已清理 cron 任务: ${marker}"
            CRON_CLEANED=$((CRON_CLEANED + 1))
        else
            log_info "cron 任务不存在: ${marker}"
        fi
    done
    
    if [ $CRON_CLEANED -gt 0 ]; then
        # 重启 cron 服务使变更生效
        /etc/init.d/cron restart >/dev/null 2>&1 && log_success "cron 服务已重启" || log_warn "重启 cron 服务失败，请手动重启"
    fi
else
    log_info "未找到 crontab 文件，跳过 cron 清理"
fi

#=============================================================================
# 步骤 5: 清理 sysupgrade 持久化配置
#=============================================================================
log_info "步骤 5/8: 清理 sysupgrade 持久化配置..."

SYSUPGRADE_CONF="/etc/sysupgrade.conf"
SYSUPGRADE_PATHS="
/etc/gost-forward
/etc/init.d/gost-forward
/usr/bin/uu
/usr/sbin/uu
/usr/bin/gost-forward
/usr/bin/gost
"

if [ -f "$SYSUPGRADE_CONF" ]; then
    SYSUPGRADE_CLEANED=0
    for path in $SYSUPGRADE_PATHS; do
        if grep -qF "$path" "$SYSUPGRADE_CONF" 2>/dev/null; then
            sed -i "\|^${path}$|d" "$SYSUPGRADE_CONF"
            log_success "已从 sysupgrade.conf 移除: $path"
            SYSUPGRADE_CLEANED=$((SYSUPGRADE_CLEANED + 1))
        fi
    done
    
    if [ $SYSUPGRADE_CLEANED -eq 0 ]; then
        log_info "sysupgrade.conf 中未找到相关配置，跳过"
    fi
else
    log_info "未找到 sysupgrade.conf 文件，跳过"
fi

#=============================================================================
# 步骤 6: 清理可能的残留文件
#=============================================================================
log_info "步骤 6/8: 检查并清理可能的残留文件..."

# 检查是否有 gost 相关进程残留
GOST_PIDS=$(ps | grep -E '[g]ost|[u]u ' | awk '{print $1}' 2>/dev/null || true)
if [ -n "$GOST_PIDS" ]; then
    log_warn "发现残留进程，正在终止..."
    for pid in $GOST_PIDS; do
        kill "$pid" 2>/dev/null && log_success "已终止进程 PID: $pid" || log_warn "无法终止进程 PID: $pid"
    done
else
    log_info "未发现残留进程"
fi

# 清理可能的临时文件
TEMP_FILES="/tmp/gost-forward.tar.gz /tmp/gost-forward-extract"
for item in $TEMP_FILES; do
    if [ -e "$item" ]; then
        rm -rf "$item"
        log_success "已清理临时文件: $item"
    fi
done

#=============================================================================
# 步骤 7: 刷新 LuCI 缓存
#=============================================================================
log_info "步骤 7/8: 刷新 LuCI 缓存..."

LUCI_CACHE_FILES="
/tmp/luci-indexcache
/tmp/luci-modulecache
/var/luci-indexcache
/var/luci-modulecache
"

LUCI_CLEANED=0
for cache_file in $LUCI_CACHE_FILES; do
    if [ -f "$cache_file" ]; then
        rm -f "$cache_file"
        log_success "已删除 LuCI 缓存: $cache_file"
        LUCI_CLEANED=$((LUCI_CLEANED + 1))
    fi
done

if [ $LUCI_CLEANED -eq 0 ]; then
    log_info "未找到 LuCI 缓存文件，跳过"
fi

# 尝试通过 ubus 刷新 LuCI（如果可用）
if command -v ubus >/dev/null 2>&1; then
    ubus call luci reload >/dev/null 2>&1 && log_success "LuCI 已通过 ubus 刷新" || log_info "ubus 刷新 LuCI 失败（可能 LuCI 未运行）"
fi

#=============================================================================
# 步骤 8: 完成
#=============================================================================
log_info "步骤 8/8: 卸载完成"
echo ""
log_success "=========================================="
log_success "  Gost Forward Manager 卸载完成！"
log_success "=========================================="
echo ""
log_info "已清理的内容:"
log_info "  - gost-forward 服务（已停止并禁用）"
log_info "  - 所有部署文件和目录"
log_info "  - cron 定时任务（4 项标记）"
log_info "  - sysupgrade 持久化配置"
log_info "  - LuCI 界面文件和缓存"
log_info "  - 残留进程和临时文件"
echo ""
log_warn "注意: 如果您需要重新安装，请运行 install-gost-forward.sh"
echo ""

exit 0
