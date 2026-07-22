#!/bin/sh
#=============================================================================
# Gost Forward Manager - 一键全自动安装脚本
# 版本: v2.3.1 (修复网络查询卡死 Bug)
# 适用: OpenWrt / iStoreOS (x86_64)
# 描述: 从 GitHub 下载安装包并完成全自动部署，无需任何交互，自动拉取 Gost 最新版
# 用法: sh install-gost-forward.sh
#=============================================================================

set -e

#=============================================================================
# 配置变量
#=============================================================================
SCRIPT_NAME="install-gost-forward.sh"
SCRIPT_VERSION="v2.3.1"
DOWNLOAD_URL="https://github.soloplus.xyz/https://github.com/WilsonBryanz/normal_shell/blob/main/network/gost-forward/gost-forward.tar.gz?raw=true"
TARBALL_NAME="gost-forward.tar.gz"
EXTRACT_DIR="/tmp/gost-forward-extract"
PACKAGE_DIR="${EXTRACT_DIR}/gost-forward"

# 初始化全局版本变量（将在运行中动态获取）
GOST_VERSION=""
GOST_DOWNLOAD_URL=""

# 部署路径
CONFIG_DIR="/etc/gost-forward"
RULES_FILE="${CONFIG_DIR}/rules.json"
GOST_YAML="${CONFIG_DIR}/gost.yaml"
UU_BIN="/usr/bin/uu"
UU_SBIN="/usr/sbin/uu"
GOST_FORWARD_BIN="/usr/bin/gost-forward"
GOST_BIN="/usr/bin/gost"
WEB_BIN="/usr/libexec/gost-forward-web"
TCPING_BIN="/usr/libexec/gost-forward-tcping"
INIT_SCRIPT="/etc/init.d/gost-forward"
LUCI_CONTROLLER="/usr/lib/lua/luci/controller/gost_forward_web.lua"
LUCI_VIEW_DIR="/usr/lib/lua/luci/view/gost-forward-web"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#=============================================================================
# 工具函数
#=============================================================================
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

print_banner() {
    echo ""
    echo "============================================"
    echo "  Gost Forward Manager ${SCRIPT_VERSION}"
    echo "  一键全自动安装脚本"
    echo "  适用: OpenWrt / iStoreOS (x86_64)"
    echo "============================================"
    echo ""
}

#=============================================================================
# 回滚函数
#=============================================================================
rollback() {
    log_error "安装失败，正在执行回滚操作..."
    
    # 停止服务
    if [ -f "${INIT_SCRIPT}" ]; then
        ${INIT_SCRIPT} stop 2>/dev/null || true
        ${INIT_SCRIPT} disable 2>/dev/null || true
    fi
    
    # 删除已部署的文件
    rm -rf "${CONFIG_DIR}" 2>/dev/null || true
    rm -f "${UU_BIN}" 2>/dev/null || true
    rm -f "${UU_SBIN}" 2>/dev/null || true
    rm -f "${GOST_FORWARD_BIN}" 2>/dev/null || true
    rm -f "${GOST_BIN}" 2>/dev/null || true
    rm -f "${WEB_BIN}" 2>/dev/null || true
    rm -f "${TCPING_BIN}" 2>/dev/null || true
    rm -f "${INIT_SCRIPT}" 2>/dev/null || true
    rm -f "${LUCI_CONTROLLER}" 2>/dev/null || true
    rm -rf "${LUCI_VIEW_DIR}" 2>/dev/null || true
    
    # 清理 cron 任务
    if [ -f /etc/crontabs/root ]; then
        sed -i '/# gost-forward-expire/d' /etc/crontabs/root 2>/dev/null || true
        sed -i '/# gost-forward-snapshot/d' /etc/crontabs/root 2>/dev/null || true
        sed -i '/# uu-expire/d' /etc/crontabs/root 2>/dev/null || true
        sed -i '/# uu-snapshot/d' /etc/crontabs/root 2>/dev/null || true
    fi
    
    # 清理 sysupgrade 配置
    if [ -f /etc/sysupgrade.conf ]; then
        sed -i '\|/etc/gost-forward|d' /etc/sysupgrade.conf 2>/dev/null || true
        sed -i '\|/etc/init.d/gost-forward|d' /etc/sysupgrade.conf 2>/dev/null || true
        sed -i '\|/usr/bin/uu|d' /etc/sysupgrade.conf 2>/dev/null || true
        sed -i '\|/usr/sbin/uu|d' /etc/sysupgrade.conf 2>/dev/null || true
        sed -i '\|/usr/bin/gost-forward|d' /etc/sysupgrade.conf 2>/dev/null || true
        sed -i '\|/usr/bin/gost|d' /etc/sysupgrade.conf 2>/dev/null || true
    fi
    
    # 清理临时文件
    rm -rf "${EXTRACT_DIR}" 2>/dev/null || true
    rm -f "/tmp/${TARBALL_NAME}" 2>/dev/null || true
    
    log_warn "回滚完成，系统已恢复到安装前状态"
    exit 1
}

#=============================================================================
# 环境检测
#=============================================================================
check_root() {
    log_info "检测 root 权限..."
    if [ "$(id -u)" -ne 0 ]; then
        log_error "此脚本必须以 root 用户执行"
        log_info "请使用: sudo sh ${SCRIPT_NAME}"
        exit 1
    fi
    log_success "root 权限检测通过"
}

check_arch() {
    log_info "检测系统架构..."
    ARCH=$(uname -m)
    if [ "${ARCH}" != "x86_64" ]; then
        log_error "不支持的架构: ${ARCH}"
        log_error "Gost Forward Manager 仅支持 x86_64 架构"
        exit 1
    fi
    log_success "架构检测通过: ${ARCH}"
}

check_openwrt() {
    log_info "检测 OpenWrt 系统..."
    if [ ! -f /etc/openwrt_release ] && [ ! -f /etc/os-release ]; then
        log_warn "未检测到 OpenWrt 系统标识，尝试继续安装..."
    else
        log_success "OpenWrt 系统检测通过"
    fi
}

check_installed() {
    log_info "检测是否已安装 Gost Forward Manager..."
    if [ -f "${INIT_SCRIPT}" ] || [ -f "${UU_BIN}" ]; then
        log_warn "检测到已安装的 Gost Forward Manager"
        log_warn "如需重新安装，请先执行卸载脚本: sh uninstall-gost-forward.sh"
        echo ""
        printf "是否继续覆盖安装？(y/N): "
        read -r CONFIRM
        if [ "${CONFIRM}" != "y" ] && [ "${CONFIRM}" != "Y" ]; then
            log_info "安装已取消"
            exit 0
        fi
        log_info "将覆盖现有安装..."
    else
        log_success "未检测到已安装版本，执行全新安装"
    fi
}

check_dependencies() {
    log_info "检测系统依赖..."
    MISSING_DEPS=""
    
    for dep in curl tar grep sed awk; do
        if ! command -v ${dep} >/dev/null 2>&1; then
            MISSING_DEPS="${MISSING_DEPS} ${dep}"
        fi
    done
    
    if [ -n "${MISSING_DEPS}" ]; then
        log_warn "缺少依赖:${MISSING_DEPS}"
        log_info "正在安装缺失的依赖..."
        if command -v opkg >/dev/null 2>&1; then
            opkg update
            for dep in ${MISSING_DEPS}; do
                opkg install ${dep}
            done
        elif command -v apk >/dev/null 2>&1; then
            apk add ${MISSING_DEPS}
        else
            log_error "无法自动安装依赖，请手动安装:${MISSING_DEPS}"
            exit 1
        fi
    fi
    log_success "系统依赖检测通过"
}

#=============================================================================
# 获取 Gost 最新版本号 (增加超时处理)
#=============================================================================
get_latest_gost_version() {
    log_info "正在从 GitHub 获取 Gost 最新正式版版本号..."
    local ver=""
    
    if command -v curl >/dev/null 2>&1; then
        # 加入 --connect-timeout 5 和 --max-time 10，防止网络不通导致无限卡死
        ver=$(curl -Ls --connect-timeout 5 --max-time 10 -o /dev/null -w %{url_effective} https://github.com/go-gost/gost/releases/latest | awk -F'/' '{print $NF}' | sed 's/^v//')
    fi
    
    if [ -n "$ver" ]; then
        GOST_VERSION="$ver"
        log_success "识别到最新正式版: v${GOST_VERSION}"
    else
        GOST_VERSION="3.2.6"
        log_warn "版本识别失败，将使用默认后备版本: v${GOST_VERSION}"
    fi
    
    # 动态拼接下载链接
    GOST_DOWNLOAD_URL="https://github.soloplus.xyz/https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_amd64.tar.gz"
}

#=============================================================================
# 下载与解压
#=============================================================================
download_package() {
    log_info "正在下载安装包..."
    log_info "下载地址: ${DOWNLOAD_URL}"
    
    if command -v curl >/dev/null 2>&1; then
        if ! curl -fSL --connect-timeout 30 --max-time 300 -o "/tmp/${TARBALL_NAME}" "${DOWNLOAD_URL}"; then
            log_error "下载失败，请检查网络连接"
            rollback
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget --timeout=30 -O "/tmp/${TARBALL_NAME}" "${DOWNLOAD_URL}"; then
            log_error "下载失败，请检查网络连接"
            rollback
        fi
    else
        log_error "未找到 curl 或 wget，无法下载"
        exit 1
    fi
    
    # 验证下载文件
    if [ ! -f "/tmp/${TARBALL_NAME}" ]; then
        log_error "下载文件不存在"
        rollback
    fi
    
    FILE_SIZE=$(ls -l "/tmp/${TARBALL_NAME}" | awk '{print $5}')
    if [ "${FILE_SIZE}" -lt 1024 ]; then
        log_error "下载文件过小 (${FILE_SIZE} bytes)，可能下载失败"
        rollback
    fi
    
    log_success "下载完成 (${FILE_SIZE} bytes)"
}

extract_package() {
    log_info "正在解压安装包..."
    
    rm -rf "${EXTRACT_DIR}" 2>/dev/null || true
    mkdir -p "${EXTRACT_DIR}"
    
    if ! tar -xzf "/tmp/${TARBALL_NAME}" -C "${EXTRACT_DIR}"; then
        log_error "解压失败"
        rollback
    fi
    
    if [ ! -d "${PACKAGE_DIR}" ]; then
        log_error "解压后未找到 gost-forward 目录"
        rollback
    fi
    
    log_success "解压完成"
}

#=============================================================================
# 部署文件
#=============================================================================
deploy_files() {
    log_info "正在部署文件..."
    
    # 创建配置目录
    mkdir -p "${CONFIG_DIR}"
    
    # 部署二进制文件
    if [ -f "${PACKAGE_DIR}/usr/bin/uu" ]; then
        cp -f "${PACKAGE_DIR}/usr/bin/uu" "${UU_BIN}"
        chmod 755 "${UU_BIN}"
        log_success "部署: ${UU_BIN}"
    else
        log_error "未找到 uu 二进制文件"
        rollback
    fi
    
    # 创建软链接
    ln -sf "${UU_BIN}" "${UU_SBIN}" 2>/dev/null || true
    ln -sf "${UU_BIN}" "${GOST_FORWARD_BIN}" 2>/dev/null || true
    
    # 部署 web 和 tcping
    if [ -f "${PACKAGE_DIR}/usr/libexec/gost-forward-web" ]; then
        cp -f "${PACKAGE_DIR}/usr/libexec/gost-forward-web" "${WEB_BIN}"
        chmod 755 "${WEB_BIN}"
        log_success "部署: ${WEB_BIN}"
    fi
    
    if [ -f "${PACKAGE_DIR}/usr/libexec/gost-forward-tcping" ]; then
        cp -f "${PACKAGE_DIR}/usr/libexec/gost-forward-tcping" "${TCPING_BIN}"
        chmod 755 "${TCPING_BIN}"
        log_success "部署: ${TCPING_BIN}"
    fi
    
    # 部署 LuCI 文件
    if [ -f "${PACKAGE_DIR}/usr/lib/lua/luci/controller/gost_forward_web.lua" ]; then
        mkdir -p "$(dirname ${LUCI_CONTROLLER})"
        cp -f "${PACKAGE_DIR}/usr/lib/lua/luci/controller/gost_forward_web.lua" "${LUCI_CONTROLLER}"
        log_success "部署: ${LUCI_CONTROLLER}"
    fi
    
    if [ -d "${PACKAGE_DIR}/usr/lib/lua/luci/view/gost-forward-web" ]; then
        mkdir -p "${LUCI_VIEW_DIR}"
        cp -rf "${PACKAGE_DIR}/usr/lib/lua/luci/view/gost-forward-web/"* "${LUCI_VIEW_DIR}/"
        log_success "部署: ${LUCI_VIEW_DIR}"
    fi
    
    log_success "文件部署完成"
}

#=============================================================================
# 初始化配置
#=============================================================================
init_config() {
    log_info "正在初始化配置..."
    
    # 初始化空规则库
    if [ ! -f "${RULES_FILE}" ]; then
        cat > "${RULES_FILE}" << 'RULESEOF'
{
  "rules": [],
  "version": "1.0"
}
RULESEOF
        log_success "初始化规则库: ${RULES_FILE}"
    fi
    
    # 初始化 gost.yaml
    if [ ! -f "${GOST_YAML}" ]; then
        cat > "${GOST_YAML}" << 'GOSTEOF'
# Gost v3 配置文件
# 由 Gost Forward Manager 自动生成
# API: 127.0.0.1:9988
# Metrics: 127.0.0.1:9989

services: []
GOSTEOF
        log_success "初始化 Gost 配置: ${GOST_YAML}"
    fi
    
    log_success "配置初始化完成"
}

#=============================================================================
# 创建 procd 服务
#=============================================================================
create_procd_service() {
    log_info "正在创建 procd 服务..."
    
    cat > "${INIT_SCRIPT}" << 'INITEOF'
#!/bin/sh /etc/rc.common

START=90
STOP=10
USE_PROCD=1

PROG=/usr/bin/gost
CONFIG_FILE=/etc/gost-forward/gost.yaml

start_service() {
    if [ ! -f "${PROG}" ]; then
        echo "Gost binary not found: ${PROG}"
        return 1
    fi
    
    procd_open_instance
    procd_set_param command "${PROG}" -C "${CONFIG_FILE}"
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    service_stop "${PROG}"
}

reload_service() {
    stop
    start
}
INITEOF
    
    chmod 755 "${INIT_SCRIPT}"
    log_success "procd 服务创建完成: ${INIT_SCRIPT}"
}

#=============================================================================
# 下载 Gost v3 二进制
#=============================================================================
install_gost() {
    get_latest_gost_version
    
    log_info "正在下载 Gost v3 (${GOST_VERSION})..."
    
    if [ -f "${GOST_BIN}" ]; then
        log_warn "Gost 已存在，跳过下载"
        chmod 755 "${GOST_BIN}"
        return 0
    fi
    
    GOST_TMP="/tmp/gost.tar.gz"
    
    if command -v curl >/dev/null 2>&1; then
        if ! curl -fSL --connect-timeout 30 --max-time 300 -o "${GOST_TMP}" "${GOST_DOWNLOAD_URL}"; then
            log_error "Gost 下载失败"
            log_info "请检查网络连接或手动下载 Gost v${GOST_VERSION}"
            log_info "下载地址: ${GOST_DOWNLOAD_URL}"
            rollback
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget --timeout=30 -O "${GOST_TMP}" "${GOST_DOWNLOAD_URL}"; then
            log_error "Gost 下载失败"
            rollback
        fi
    fi
    
    # 解压 Gost
    mkdir -p /tmp/gost-extract
    if ! tar -xzf "${GOST_TMP}" -C /tmp/gost-extract; then
        log_error "Gost 解压失败"
        rollback
    fi
    
    # 查找并安装 gost 二进制
    GOST_EXTRACTED=$(find /tmp/gost-extract -name "gost" -type f 2>/dev/null | head -1)
    if [ -z "${GOST_EXTRACTED}" ]; then
        log_error "未在压缩包中找到 gost 二进制文件"
        rollback
    fi
    
    cp -f "${GOST_EXTRACTED}" "${GOST_BIN}"
    chmod 755 "${GOST_BIN}"
    
    # 清理临时文件
    rm -rf /tmp/gost-extract "${GOST_TMP}"
    
    log_success "Gost v${GOST_VERSION} 安装完成: ${GOST_BIN}"
}

#=============================================================================
# 配置 cron 任务
#=============================================================================
configure_cron() {
    log_info "正在配置 cron 定时任务..."
    
    CRON_FILE="/etc/crontabs/root"
    
    # 确保 crontabs 目录存在
    mkdir -p /etc/crontabs
    if [ ! -f "${CRON_FILE}" ]; then
        touch "${CRON_FILE}"
    fi
    
    # 移除旧的 cron 标记
    sed -i '/# gost-forward-expire/d' "${CRON_FILE}" 2>/dev/null || true
    sed -i '/# gost-forward-snapshot/d' "${CRON_FILE}" 2>/dev/null || true
    sed -i '/# uu-expire/d' "${CRON_FILE}" 2>/dev/null || true
    sed -i '/# uu-snapshot/d' "${CRON_FILE}" 2>/dev/null || true
    
    # 添加新的 cron 任务
    cat >> "${CRON_FILE}" << 'CRONEOF'
# gost-forward-expire - 每小时检查规则过期
0 * * * * /usr/bin/uu expire >/dev/null 2>&1
# gost-forward-snapshot - 每天凌晨备份规则快照
0 2 * * * /usr/bin/uu snapshot >/dev/null 2>&1
# uu-expire - 备用过期检查
30 * * * * /usr/bin/uu expire >/dev/null 2>&1
# uu-snapshot - 备用快照备份
30 2 * * * /usr/bin/uu snapshot >/dev/null 2>&1
CRONEOF
    
    # 重启 cron 服务
    if [ -f /etc/init.d/cron ]; then
        /etc/init.d/cron restart 2>/dev/null || true
    fi
    
    log_success "cron 定时任务配置完成"
}

#=============================================================================
# 配置 sysupgrade 持久化
#=============================================================================
configure_sysupgrade() {
    log_info "正在配置 sysupgrade 持久化..."
    
    SYS_CONF="/etc/sysupgrade.conf"
    
    if [ ! -f "${SYS_CONF}" ]; then
        touch "${SYS_CONF}"
    fi
    
    # 移除旧的持久化配置
    sed -i '\|/etc/gost-forward|d' "${SYS_CONF}" 2>/dev/null || true
    sed -i '\|/etc/init.d/gost-forward|d' "${SYS_CONF}" 2>/dev/null || true
    sed -i '\|/usr/bin/uu|d' "${SYS_CONF}" 2>/dev/null || true
    sed -i '\|/usr/sbin/uu|d' "${SYS_CONF}" 2>/dev/null || true
    sed -i '\|/usr/bin/gost-forward|d' "${SYS_CONF}" 2>/dev/null || true
    sed -i '\|/usr/bin/gost|d' "${SYS_CONF}" 2>/dev/null || true
    
    # 添加持久化路径
    cat >> "${SYS_CONF}" << 'SYSEOF'
/etc/gost-forward
/etc/init.d/gost-forward
/usr/bin/uu
/usr/sbin/uu
/usr/bin/gost-forward
/usr/bin/gost
SYSEOF
    
    log_success "sysupgrade 持久化配置完成"
}

#=============================================================================
# 启动服务
#=============================================================================
start_service() {
    log_info "正在启动 Gost Forward 服务..."
    
    # 启用服务
    if [ -f "${INIT_SCRIPT}" ]; then
        ${INIT_SCRIPT} enable 2>/dev/null || true
        ${INIT_SCRIPT} start 2>/dev/null || true
        
        # 等待服务启动
        sleep 2
        
        if ${INIT_SCRIPT} status 2>/dev/null | grep -q "running"; then
            log_success "Gost Forward 服务启动成功"
        else
            log_warn "服务状态检查不确定，请手动验证"
        fi
    else
        log_error "未找到 init 脚本"
        rollback
    fi
}

#=============================================================================
# 刷新 LuCI 缓存
#=============================================================================
refresh_luci() {
    log_info "正在刷新 LuCI 缓存..."
    
    # 清除 LuCI 缓存
    rm -f /tmp/luci-indexcache 2>/dev/null || true
    rm -f /tmp/luci-modulecache/* 2>/dev/null || true
    
    # 重启 uhttpd/nginx 使 LuCI 生效
    if [ -f /etc/init.d/uhttpd ]; then
        /etc/init.d/uhttpd restart 2>/dev/null || true
    fi
    if [ -f /etc/init.d/nginx ]; then
        /etc/init.d/nginx restart 2>/dev/null || true
    fi
    
    log_success "LuCI 缓存刷新完成"
}

#=============================================================================
# 安装完成总结
#=============================================================================
print_summary() {
    echo ""
    echo "============================================"
    echo -e "  ${GREEN}Gost Forward Manager 安装完成！${NC}"
    echo "============================================"
    echo ""
    echo -e "  ${BLUE}版本信息:${NC}"
    echo "  - 管理脚本: ${SCRIPT_VERSION}"
    echo "  - Gost 版本: ${GOST_VERSION}"
    echo ""
    echo -e "  ${BLUE}部署路径:${NC}"
    echo "  - 配置目录: ${CONFIG_DIR}"
    echo "  - 管理命令: uu"
    echo "  - Gost 二进制: ${GOST_BIN}"
    echo "  - 服务脚本: ${INIT_SCRIPT}"
    echo ""
    echo -e "  ${BLUE}服务信息:${NC}"
    echo "  - API 地址: http://127.0.0.1:9988"
    echo "  - Metrics: http://127.0.0.1:9989"
    echo ""
    echo -e "  ${BLUE}常用命令:${NC}"
    echo "  - 查看状态: /etc/init.d/gost-forward status"
    echo "  - 启动服务: /etc/init.d/gost-forward start"
    echo "  - 停止服务: /etc/init.d/gost-forward stop"
    echo "  - 重启服务: /etc/init.d/gost-forward restart"
    echo "  - 管理面板: uu"
    echo ""
    echo -e "  ${BLUE}LuCI 界面:${NC}"
    echo "  - 登录路由器管理界面即可看到「Gost 转发」菜单"
    echo ""
    echo -e "  ${YELLOW}提示: 如需卸载，请执行 sh uninstall-gost-forward.sh${NC}"
    echo ""
    echo "============================================"
}

#=============================================================================
# 主流程
#=============================================================================
main() {
    print_banner
    
    # 环境检测
    check_root
    check_arch
    check_openwrt
    check_installed
    check_dependencies
    
    # 下载与解压
    download_package
    extract_package
    
    # 部署
    deploy_files
    init_config
    create_procd_service
    
    # 安装 Gost
    install_gost
    
    # 配置
    configure_cron
    configure_sysupgrade
    
    # 启动
    start_service
    refresh_luci
    
    # 完成
    print_summary
    
    # 清理临时文件
    rm -rf "${EXTRACT_DIR}" 2>/dev/null || true
    rm -f "/tmp/${TARBALL_NAME}" 2>/dev/null || true
}

# 执行主流程
main "$@"
