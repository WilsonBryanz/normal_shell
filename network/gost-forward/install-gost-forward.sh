#!/bin/sh
#=============================================================================
# Gost Forward Manager - 一键全自动安装脚本
# 版本: v2.3.3 (加入智能路径探测，兼容任意打包结构)
# 适用: OpenWrt / iStoreOS (x86_64)
#=============================================================================

set -e

#=============================================================================
# 配置变量
#=============================================================================
SCRIPT_NAME="install-gost-forward.sh"
SCRIPT_VERSION="v2.3.3"
DOWNLOAD_URL="https://github.soloplus.xyz/https://github.com/WilsonBryanz/normal_shell/blob/main/network/gost-forward/gost-forward.tar.gz?raw=true"
TARBALL_NAME="gost-forward.tar.gz"
EXTRACT_DIR="/tmp/gost-forward-extract"

# 初始化全局版本变量
GOST_VERSION=""
GOST_DOWNLOAD_URL=""

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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

print_banner() {
    echo ""
    echo "============================================"
    echo "  Gost Forward Manager ${SCRIPT_VERSION}"
    echo "  一键全自动安装脚本"
    echo "  适用: OpenWrt / iStoreOS (x86_64)"
    echo "============================================"
    echo ""
}

rollback() {
    log_error "安装失败，正在执行回滚操作..."
    [ -f "${INIT_SCRIPT}" ] && { ${INIT_SCRIPT} stop 2>/dev/null || true; ${INIT_SCRIPT} disable 2>/dev/null || true; }
    rm -rf "${CONFIG_DIR}" 2>/dev/null || true
    rm -f "${UU_BIN}" "${UU_SBIN}" "${GOST_FORWARD_BIN}" "${GOST_BIN}" "${WEB_BIN}" "${TCPING_BIN}" "${INIT_SCRIPT}" "${LUCI_CONTROLLER}" 2>/dev/null || true
    rm -rf "${LUCI_VIEW_DIR}" 2>/dev/null || true
    if [ -f /etc/crontabs/root ]; then
        sed -i '/# gost-forward-/d' /etc/crontabs/root 2>/dev/null || true
        sed -i '/# uu-/d' /etc/crontabs/root 2>/dev/null || true
    fi
    if [ -f /etc/sysupgrade.conf ]; then
        sed -i '\|/etc/gost-forward|d;\|/etc/init.d/gost-forward|d;\|/usr/bin/uu|d;\|/usr/sbin/uu|d;\|/usr/bin/gost-forward|d;\|/usr/bin/gost|d' /etc/sysupgrade.conf 2>/dev/null || true
    fi
    rm -rf "${EXTRACT_DIR}" "/tmp/${TARBALL_NAME}" 2>/dev/null || true
    log_warn "回滚完成，系统已恢复到安装前状态"
    exit 1
}

check_root() {
    log_info "检测 root 权限..."
    [ "$(id -u)" -ne 0 ] && { log_error "此脚本必须以 root 用户执行"; exit 1; }
    log_success "root 权限检测通过"
}

check_arch() {
    log_info "检测系统架构..."
    ARCH=$(uname -m)
    [ "${ARCH}" != "x86_64" ] && { log_error "不支持的架构: ${ARCH}"; exit 1; }
    log_success "架构检测通过: ${ARCH}"
}

check_openwrt() {
    log_info "检测 OpenWrt 系统..."
    [ ! -f /etc/openwrt_release ] && [ ! -f /etc/os-release ] && log_warn "未检测到 OpenWrt 系统标识，尝试继续安装..." || log_success "OpenWrt 系统检测通过"
}

check_installed() {
    log_info "检测是否已安装 Gost Forward Manager..."
    if [ -f "${INIT_SCRIPT}" ] || [ -f "${UU_BIN}" ]; then
        log_warn "检测到已安装的 Gost Forward Manager"
        printf "是否继续覆盖安装？(y/N): "
        read -r CONFIRM
        [ "${CONFIRM}" != "y" ] && [ "${CONFIRM}" != "Y" ] && { log_info "安装已取消"; exit 0; }
        log_info "将覆盖现有安装..."
    else
        log_success "未检测到已安装版本，执行全新安装"
    fi
}

check_dependencies() {
    log_info "检测系统依赖..."
    MISSING_DEPS=""
    for dep in curl tar grep sed awk find; do
        if ! command -v ${dep} >/dev/null 2>&1; then MISSING_DEPS="${MISSING_DEPS} ${dep}"; fi
    done
    if [ -n "${MISSING_DEPS}" ]; then
        log_warn "缺少依赖:${MISSING_DEPS}"
        if command -v opkg >/dev/null 2>&1; then
            opkg update
            for dep in ${MISSING_DEPS}; do opkg install ${dep}; done
        else
            log_error "无法自动安装依赖，请手动安装:${MISSING_DEPS}"
            exit 1
        fi
    fi
    log_success "系统依赖检测通过"
}

get_latest_gost_version() {
    log_info "正在通过代理节点获取 Gost 最新正式版版本号..."
    local ver=""
    if command -v curl >/dev/null 2>&1; then
        ver=$(curl -Ls --connect-timeout 5 --max-time 10 -o /dev/null -w %{url_effective} https://github.soloplus.xyz/https://github.com/go-gost/gost/releases/latest | awk -F'/' '{print $NF}' | sed 's/^v//')
    fi
    
    if [ -n "$ver" ] && [ "$ver" != "latest" ]; then
        GOST_VERSION="$ver"
        log_success "成功识别到最新正式版: v${GOST_VERSION}"
    else
        GOST_VERSION="3.2.6"
        log_warn "版本识别超时或失败，自动降级使用默认版本: v${GOST_VERSION}"
    fi
    
    GOST_DOWNLOAD_URL="https://github.soloplus.xyz/https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_amd64.tar.gz"
}

download_package() {
    log_info "正在下载安装包..."
    if command -v curl >/dev/null 2>&1; then
        curl -fSL --connect-timeout 30 --max-time 300 -o "/tmp/${TARBALL_NAME}" "${DOWNLOAD_URL}" || { log_error "下载失败"; rollback; }
    else
        wget --timeout=30 -O "/tmp/${TARBALL_NAME}" "${DOWNLOAD_URL}" || { log_error "下载失败"; rollback; }
    fi
    [ ! -f "/tmp/${TARBALL_NAME}" ] && { log_error "下载文件不存在"; rollback; }
    FILE_SIZE=$(ls -l "/tmp/${TARBALL_NAME}" | awk '{print $5}')
    [ "${FILE_SIZE}" -lt 1024 ] && { log_error "下载文件过小"; rollback; }
    log_success "下载完成 (${FILE_SIZE} bytes)"
}

extract_package() {
    log_info "正在解压安装包..."
    rm -rf "${EXTRACT_DIR}" 2>/dev/null || true
    mkdir -p "${EXTRACT_DIR}"
    tar -xzf "/tmp/${TARBALL_NAME}" -C "${EXTRACT_DIR}" || { log_error "解压失败"; rollback; }
    log_success "解压完成"
}

deploy_files() {
    log_info "正在智能探测与部署文件..."
    mkdir -p "${CONFIG_DIR}"
    
    # 智能探测：无论包外层包了多少个文件夹，直接寻找 usr/bin/uu
    UU_SRC=$(find "${EXTRACT_DIR}" -type f -name "uu" 2>/dev/null | grep "usr/bin/uu" | head -n 1)
    
    if [ -z "${UU_SRC}" ]; then
        log_error "部署失败：压缩包内未找到核心文件 usr/bin/uu"
        rollback
    fi
    
    # 动态反推真实的包根目录 (向上剥离三层: uu -> bin -> usr -> 包根目录)
    PACKAGE_DIR=$(dirname $(dirname $(dirname "${UU_SRC}")))
    log_success "识别到真实包路径: ${PACKAGE_DIR}"
    
    cp -f "${PACKAGE_DIR}/usr/bin/uu" "${UU_BIN}"
    chmod 755 "${UU_BIN}"
    log_success "部署: ${UU_BIN}"
    
    ln -sf "${UU_BIN}" "${UU_SBIN}" 2>/dev/null || true
    ln -sf "${UU_BIN}" "${GOST_FORWARD_BIN}" 2>/dev/null || true
    
    if [ -f "${PACKAGE_DIR}/usr/libexec/gost-forward-web" ]; then
        cp -f "${PACKAGE_DIR}/usr/libexec/gost-forward-web" "${WEB_BIN}"
        chmod 755 "${WEB_BIN}"
    fi
    if [ -f "${PACKAGE_DIR}/usr/libexec/gost-forward-tcping" ]; then
        cp -f "${PACKAGE_DIR}/usr/libexec/gost-forward-tcping" "${TCPING_BIN}"
        chmod 755 "${TCPING_BIN}"
    fi
    if [ -f "${PACKAGE_DIR}/usr/lib/lua/luci/controller/gost_forward_web.lua" ]; then
        mkdir -p "$(dirname ${LUCI_CONTROLLER})"
        cp -f "${PACKAGE_DIR}/usr/lib/lua/luci/controller/gost_forward_web.lua" "${LUCI_CONTROLLER}"
    fi
    if [ -d "${PACKAGE_DIR}/usr/lib/lua/luci/view/gost-forward-web" ]; then
        mkdir -p "${LUCI_VIEW_DIR}"
        cp -rf "${PACKAGE_DIR}/usr/lib/lua/luci/view/gost-forward-web/"* "${LUCI_VIEW_DIR}/"
    fi
    log_success "文件部署完成"
}

init_config() {
    log_info "正在初始化配置..."
    if [ ! -f "${RULES_FILE}" ]; then
        cat > "${RULES_FILE}" << 'RULESEOF'
{
  "rules": [],
  "version": "1.0"
}
RULESEOF
    fi
    if [ ! -f "${GOST_YAML}" ]; then
        cat > "${GOST_YAML}" << 'GOSTEOF'
services: []
GOSTEOF
    fi
    log_success "配置初始化完成"
}

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
    [ ! -f "${PROG}" ] && return 1
    procd_open_instance
    procd_set_param command "${PROG}" -C "${CONFIG_FILE}"
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
stop_service() { service_stop "${PROG}"; }
reload_service() { stop; start; }
INITEOF
    chmod 755 "${INIT_SCRIPT}"
    log_success "procd 服务创建完成"
}

install_gost() {
    get_latest_gost_version
    log_info "正在通过代理下载 Gost v3 (${GOST_VERSION})..."
    
    if [ -f "${GOST_BIN}" ]; then
        log_warn "Gost 已存在，跳过下载"
        chmod 755 "${GOST_BIN}"
        return 0
    fi
    
    GOST_TMP="/tmp/gost.tar.gz"
    if command -v curl >/dev/null 2>&1; then
        curl -fSL --connect-timeout 30 --max-time 300 -o "${GOST_TMP}" "${GOST_DOWNLOAD_URL}" || { log_error "Gost 下载失败"; rollback; }
    else
        wget --timeout=30 -O "${GOST_TMP}" "${GOST_DOWNLOAD_URL}" || rollback
    fi
    
    mkdir -p /tmp/gost-extract
    tar -xzf "${GOST_TMP}" -C /tmp/gost-extract || rollback
    GOST_EXTRACTED=$(find /tmp/gost-extract -name "gost" -type f 2>/dev/null | head -1)
    [ -z "${GOST_EXTRACTED}" ] && rollback
    
    cp -f "${GOST_EXTRACTED}" "${GOST_BIN}"
    chmod 755 "${GOST_BIN}"
    rm -rf /tmp/gost-extract "${GOST_TMP}"
    log_success "Gost v${GOST_VERSION} 安装完成"
}

configure_cron() {
    log_info "正在配置 cron 定时任务..."
    CRON_FILE="/etc/crontabs/root"
    mkdir -p /etc/crontabs
    touch "${CRON_FILE}"
    sed -i '/# gost-forward-/d; /# uu-/d' "${CRON_FILE}" 2>/dev/null || true
    cat >> "${CRON_FILE}" << 'CRONEOF'
0 * * * * /usr/bin/uu expire >/dev/null 2>&1
0 2 * * * /usr/bin/uu snapshot >/dev/null 2>&1
CRONEOF
    [ -f /etc/init.d/cron ] && /etc/init.d/cron restart 2>/dev/null || true
    log_success "cron 配置完成"
}

configure_sysupgrade() {
    log_info "正在配置 sysupgrade 持久化..."
    SYS_CONF="/etc/sysupgrade.conf"
    touch "${SYS_CONF}"
    sed -i '\|/etc/gost-forward|d; \|/etc/init.d/gost-forward|d; \|/usr/bin/uu|d; \|/usr/sbin/uu|d; \|/usr/bin/gost|d' "${SYS_CONF}" 2>/dev/null || true
    cat >> "${SYS_CONF}" << 'SYSEOF'
/etc/gost-forward
/etc/init.d/gost-forward
/usr/bin/uu
/usr/sbin/uu
/usr/bin/gost
SYSEOF
    log_success "持久化配置完成"
}

start_service() {
    log_info "正在启动服务..."
    if [ -f "${INIT_SCRIPT}" ]; then
        ${INIT_SCRIPT} enable 2>/dev/null || true
        ${INIT_SCRIPT} start 2>/dev/null || true
        sleep 2
        ${INIT_SCRIPT} status 2>/dev/null | grep -q "running" && log_success "服务启动成功" || log_warn "服务可能未完全启动"
    fi
}

refresh_luci() {
    log_info "正在刷新 LuCI..."
    rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true
    [ -f /etc/init.d/uhttpd ] && /etc/init.d/uhttpd restart 2>/dev/null || true
    log_success "刷新完成"
}

print_summary() {
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  Gost Forward Manager v2.3.3 安装完成！${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo "  输入 uu 进入终端面板，或登录 Web 界面查看。"
    echo ""
}

main() {
    print_banner
    check_root; check_arch; check_openwrt; check_installed; check_dependencies
    download_package; extract_package
    deploy_files; init_config; create_procd_service
    install_gost
    configure_cron; configure_sysupgrade
    start_service; refresh_luci
    print_summary
}

main "$@"
