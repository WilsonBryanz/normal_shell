#!/usr/bin/env bash
# =============================================================================
#  UU + mihomo(WARP) 融合架构 · 一键部署脚本  v12.8（预检去 FATAL 化 + EOL 自动安装放行 + fw3 去依赖 + 守护自锁修复 + 首次运行三态判定）
#  幂等 / 覆盖前自动备份 / 保护已修复文件 / 依赖与权限与系统兼容性兜底 / 中文日志 / 失败即中止
#  修改日期：2026-09-23
#
#  用法：  bash /root/install_uu.sh [选项]
#    --help            显示帮助
#    --check           只做自检（前置检查 + 语法 + 内嵌内容校验），不修改系统
#    --offline         离线模式：不下载任何东西（需自备 /tmp/mihomo.gz、/tmp/mxd.tgz）
#    --no-container    只部署文件与依赖，不创建/启动容器
#    --base-dir DIR    指定部署根目录（默认 /opt/uuplugin，也可用环境变量 UU_BASE_DIR）
#    --mode MODE       直接指定安装模式，跳过交互菜单（自动化场景用）
#                      取值: full | standard | minimal | custom | check
#    -y, --yes         非交互确认：配合 --mode 使用，跳过菜单与二次确认
#
#  默认行为（v12.1 起）：交互式
#    在终端中直接运行时，脚本会先展示「安装模式菜单」，等待你输入序号，
#    校验通过后二次确认，才开始执行对应步骤，过程中显示 步骤 n/10 与百分比进度。
#    以下情况自动跳过菜单、沿用旧的一键行为（不影响自动化/定时任务）：
#      1) 指定了 --mode / UU_MODE 环境变量
#      2) 指定了 --check / --no-container / --with-mihomo 等既有选项
#      3) 标准输入不是终端（如 bash install_uu.sh < /dev/null、CI、cron）
#
#  可用环境变量：
#    UU_MODE           安装模式（等价 --mode），取值同上
#    UU_INTERACTIVE    强制开启/关闭交互菜单：1=强制显示 0=强制跳过
#    UU_BASE_DIR        部署根目录
#    UU_IMAGE           镜像名（默认 dianqk/uuplugin）
#    UU_IMAGE_TAG       镜像标签（默认 latest）
#    UU_ENABLE_SIMS     是否一并部署 PS4/PS5 模拟容器 1=是（默认 0）
#    UU_LAN_IP          指定容器 LAN IP（默认自动探测同网段 .248）
#    MIHOMO_VERSION     mihomo 版本（默认 v1.19.31）
#    UU_RETAIN_BACKUPS  部署级备份目录保留份数（默认 10，作用域 $BASE_DIR/backups/<时间戳>/）
#    KEEP_CONFIG_BACKUPS  config.yaml 备份保留份数（默认 3，作用域 $BASE_DIR/mihomo/config.yaml.bak.<ts>）
#    BACKUP_KEEP_MARKER  config.yaml 备份豁免标记（默认 .keep，含此标记的备份永不删除）
# =============================================================================
set -Eeuo pipefail

# ---------------------------------------------------------------- 参数解析
CHECK_ONLY=0; OFFLINE=0; NO_CONTAINER=0; WITH_MIHOMO=0
BASE_DIR="${UU_BASE_DIR:-/opt/uuplugin}"
INSTALL_MODE="${UU_MODE:-}"
ASSUME_YES=0
PREFLIGHT_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --help)         sed -n '2,37p' "$0"; exit 0 ;;
        --preflight|--preflight-only) PREFLIGHT_ONLY=1; shift ;;
        --check)        CHECK_ONLY=1; shift ;;
        --offline)      OFFLINE=1; shift ;;
        --no-container) NO_CONTAINER=1; shift ;;
            --with-mihomo)   WITH_MIHOMO=1; shift ;;
        --base-dir)     BASE_DIR="${2:-/opt/uuplugin}"; shift 2 ;;
        --mode)         INSTALL_MODE="${2:-}"; shift 2 ;;
        --mode=*)       INSTALL_MODE="${1#--mode=}"; shift ;;
        -y|--yes)       ASSUME_YES=1; shift ;;
        *) echo "未知参数: $1（用 --help 查看用法）"; exit 2 ;;
    esac
done

LOG_FILE="$BASE_DIR/log/deploy.log"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="$BASE_DIR/backups/$RUN_TS"
MARKER_FILE="$BASE_DIR/.deploy_version"
UU_IMAGE="${UU_IMAGE:-dianqk/uuplugin}"
UU_IMAGE_TAG="${UU_IMAGE_TAG:-latest}"
UU_ENABLE_SIMS="${UU_ENABLE_SIMS:-0}"
MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.31}"
UU_RETAIN_BACKUPS="${UU_RETAIN_BACKUPS:-10}"

# ---- 备份保留策略（config.yaml 专项）----
# 保留数量：仅保留最新 N 份 config.yaml 备份，超出时按时间戳滚动删除最旧的
KEEP_CONFIG_BACKUPS="${KEEP_CONFIG_BACKUPS:-3}"
# 豁免标记：文件名含该标记的 config.yaml 备份永不删除，且不占用保留名额
BACKUP_KEEP_MARKER="${BACKUP_KEEP_MARKER:-.keep}"

# 受保护文件：命中修复标记时不覆盖，避免冲掉现场修复
PROTECT_MANAGER_MARKER='CAP_DEV="mihomo0"'
PROTECT_PROXY_MARKER='CAP_DEV="mihomo0"'
PROTECT_RESTART_MARKER='restart_mihomo'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}  [OK]${NC} $*"; }
warn() { echo -e "${YELLOW}  [警告]${NC} $*"; }
info() { echo -e "${BLUE}  [信息]${NC} $*"; }
die()  { echo -e "${RED}[致命错误] $*${NC}"; echo -e "${RED}部署已中止，请修正后重新执行（本脚本可安全重复运行）。${NC}"; exit 1; }
# 进度提示：标题形如「步骤 7/10：容器编排」时自动补 [70%]，便于一眼看到整体进度
step() {
    local _pct="" _n
    case "$*" in
        *"步骤 "[0-9]*"/10"*)
            _n="${*#*步骤 }"; _n="${_n%%/10*}"
            case "$_n" in ''|*[!0-9]*) ;; *) _pct=" [${_n}0%]" ;; esac ;;
    esac
    echo -e "\n${GREEN}===== $*${_pct} =====${NC}"
}

trap 'die "第 ${STEP_NO:-?} 步执行失败（退出码 $?）。上方已给出错误原因；脚本是幂等的，修正后可直接重跑。"' ERR
STEP_NO="初始化"

mkdir -p "$BASE_DIR/log"

# ============================================================================
#  交互式安装模式选择（v12.1）
# ----------------------------------------------------------------------------
#  位置要求：必须在下面的 exec tee 之前。
#  原因：tee 对管道是块缓冲的，无换行结尾的 prompt（如 "请输入序号 [默认 1]: "）
#  可能被暂留在缓冲区，用户看不到提示却卡在等待输入。
#  因此菜单交互走原生 stdout，交互结束后再接管输出到日志文件。
#  交互终端下先让用户选模式，校验 + 二次确认后才执行对应步骤。
#  非交互场景（--mode / UU_MODE / 旧选项 / 标准输入非 tty / UU_INTERACTIVE=0）
#  自动跳过菜单，保持与旧版本完全一致的一键行为。
#
#  模式 -> 内部开关映射（不改动后续任何既有分支逻辑，只是给既有变量赋值）：
#    full      完整安装  LEGACY_FULL=1                    步骤 1~10
#    standard  标准安装  LEGACY_FULL=0                    步骤 1~6
#    minimal   最小安装  LEGACY_FULL=1 NO_CONTAINER=1     步骤 1~6 + 10
#    custom    自定义    逐项勾选组件后按需组合
#    check     仅自检    CHECK_ONLY=1                     不修改系统
# ============================================================================
UU_INSTALL_MIHOMO="${UU_INSTALL_MIHOMO:-1}"
UU_INSTALL_UI="${UU_INSTALL_UI:-1}"
UU_ENABLE_SIMS="${UU_ENABLE_SIMS:-0}"
MODE_LABEL=""; MODE_STEPS=""; REPLY_ANS=""; PICKED=0

mode_valid()   { case "$1" in full|standard|minimal|custom|check) return 0 ;; *) return 1 ;; esac; }
read_answer()  { local _l; if ! IFS= read -r _l; then _l=""; fi; echo ""; [ -n "$_l" ] || _l="$1"; REPLY_ANS="$_l"; }

apply_mode() {
    case "$1" in
        full)     LEGACY_FULL=1; UU_INSTALL_MIHOMO=1; UU_INSTALL_UI=1
                  MODE_LABEL="完整安装（含 mihomo 内核 / Web 面板 / 容器 / 服务 / 验证）"
                  MODE_STEPS="步骤 1~10" ;;
        standard) LEGACY_FULL=0
                  MODE_LABEL="标准安装（环境与核心脚本，容器与 mihomo 留给 uu 面板）"
                  MODE_STEPS="步骤 1~6" ;;
        minimal)  LEGACY_FULL=1; NO_CONTAINER=1
                  MODE_LABEL="最小安装（仅文件与依赖，不创建/启动容器）"
                  MODE_STEPS="步骤 1~6 + 10" ;;
        custom)   LEGACY_FULL=1
                  MODE_LABEL="自定义安装"; MODE_STEPS="按勾选结果执行" ;;
        check)    CHECK_ONLY=1
                  MODE_LABEL="仅自检（不修改系统）"; MODE_STEPS="不写入任何文件" ;;
    esac
    INSTALL_MODE="$1"
}

menu_header() {
    echo -e "${GREEN}"
    echo "=============================================================="
    echo "  安装模式选择"
    echo "==============================================================${NC}"
    echo ""
    echo -e "  ${CYAN}[1]${NC} 完整安装 ${GREEN}（推荐）${NC}"
    echo "      依赖 + 核心脚本 + mihomo 内核 + Web 面板 + 容器编排"
    echo "      + 启动容器 + 开机自启服务 + 部署验证       → 步骤 1~10"
    echo -e "  ${CYAN}[2]${NC} 标准安装"
    echo "      依赖 + 核心脚本 + 配置模板 + uu 面板入口"
    echo "      容器与 mihomo 稍后在 uu 面板按需部署       → 步骤 1~6"
    echo -e "  ${CYAN}[3]${NC} 最小安装"
    echo "      仅部署文件与依赖，不创建、不启动容器       → 步骤 1~6 + 10"
    echo -e "  ${CYAN}[4]${NC} 自定义安装（逐项勾选组件）"
    echo -e "  ${CYAN}[5]${NC} 仅自检（等价 --check，不修改系统）"
    echo -e "  ${CYAN}[0]${NC} 退出（不做任何修改）"
    echo ""
    echo -e "  ${CYAN}部署目录${NC}: ${YELLOW}$BASE_DIR${NC}"
    echo ""
}

# 结果写入全局 PICKED(1/0)，不要用命令替换取返回值：
# 否则校验失败分支里 warn 的输出会被一并捕获进返回值，导致判断失真。
pick_yes_no() {
    local _d="$2" _a
    printf "      %s" "$1"
    read_answer "$_d"; _a="$REPLY_ANS"
    case "$_a" in
        Y|y) PICKED=1 ;;
        N|n) PICKED=0 ;;
        *)   warn "输入 '$_a' 无效，按默认值 $_d 处理"; [ "$_d" = "Y" ] && PICKED=1 || PICKED=0 ;;
    esac
}

custom_components() {
    local _picked=""
    echo ""
    echo -e "  ${CYAN}--- 自定义组件（直接回车采用方括号内默认值）---${NC}"
    pick_yes_no "部署 mihomo 内核？             [Y/n] " Y; UU_INSTALL_MIHOMO="$PICKED"
    pick_yes_no "部署 Web 控制面板（:9090/ui）？ [Y/n] " Y; UU_INSTALL_UI="$PICKED"
    pick_yes_no "部署 PS4/PS5 模拟容器？        [y/N] " N; UU_ENABLE_SIMS="$PICKED"
    pick_yes_no "创建并启动 uuplugin 容器？     [Y/n] " Y
    if [ "$PICKED" = 1 ]; then NO_CONTAINER=0; else NO_CONTAINER=1; fi
    [ "$UU_INSTALL_MIHOMO" = 1 ] && _picked="$_picked mihomo内核"
    [ "$UU_INSTALL_UI" = 1 ]      && _picked="$_picked Web面板"
    [ "$UU_ENABLE_SIMS" = 1 ]     && _picked="$_picked PS4/PS5模拟"
    [ "$NO_CONTAINER" = 0 ]       && _picked="$_picked 容器编排+启动" || _picked="$_picked 不起容器"
    [ -n "$_picked" ] || _picked=" （仅依赖与脚本）"
    MODE_STEPS="组件:${_picked}"
}

choose_install_mode() {
    # 1) 已显式指定模式（--mode / UU_MODE）：不再提问，但要校验合法性
    if [ -n "$INSTALL_MODE" ]; then
        mode_valid "$INSTALL_MODE" \
            || die "未知安装模式: $INSTALL_MODE（可选 full|standard|minimal|custom|check）"
        apply_mode "$INSTALL_MODE"
        [ "$INSTALL_MODE" = custom ] && [ "${ASSUME_YES:-0}" = 1 ] && custom_components_defaults
        echo -e "  ${CYAN}安装模式${NC}: ${YELLOW}$MODE_LABEL${NC}  （--mode=$INSTALL_MODE）"
        echo -e "  ${CYAN}执行范围${NC}: $MODE_STEPS"
        return 0
    fi

    # 2) 判定是否交互：UU_INTERACTIVE 显式优先，否则看标准输入是否为终端
    local _inter=0
    case "${UU_INTERACTIVE:-auto}" in
        1|yes|on)  _inter=1 ;;
        0|no|off)  _inter=0 ;;
        auto)      [ -t 0 ] && _inter=1 ;;
    esac
    # --preflight-only 是"只体检不改系统"的旁路，不应弹安装菜单
    [ "$PREFLIGHT_ONLY" = "1" ] && return 0
    # 已显式传旧版选项 / 非交互 → 沿用旧的一键行为
    if [ "$_inter" != 1 ] || [ "$CHECK_ONLY" = 1 ] || [ "$NO_CONTAINER" = 1 ] \
       || [ -n "${LEGACY_FULL:-}" ] || [ "$WITH_MIHOMO" = 1 ]; then
        MODE_LABEL="${MODE_LABEL:-一键部署（命令行参数/环境变量指定）}"
        MODE_STEPS="${MODE_STEPS:-按现有参数执行}"
        return 0
    fi

    # 3) 展示菜单：最多 3 次输入机会，支持序号、默认值回车、非法输入提示重填
    local _try=0 _sel="" _ans
    while [ "$_try" -lt 3 ]; do
        _try=$((_try + 1))
        menu_header
        printf "  请输入序号 [默认 1]: "
        read_answer "1"; _ans="$REPLY_ANS"
        case "$_ans" in
            1) _sel=full;     break ;;
            2) _sel=standard; break ;;
            3) _sel=minimal;  break ;;
            4) _sel=custom;   break ;;
            5) _sel=check;    break ;;
            0) echo ""; echo "  已取消，未做任何修改。"; exit 0 ;;
            *) warn "无效输入 '$_ans'：请输入 0~5 的数字（还剩 $((3 - _try)) 次机会）" ;;
        esac
        if [ "$_try" -ge 3 ]; then
            warn "连续 3 次无效输入，自动采用默认模式：完整安装"
            _sel=full
        fi
    done

    apply_mode "$_sel"
    [ "$_sel" = custom ] && custom_components

    # 4) 二次确认后才真正开始
    echo ""
    echo -e "  ${CYAN}即将执行${NC}: ${YELLOW}$MODE_LABEL${NC}"
    echo -e "  ${CYAN}执行范围${NC}: $MODE_STEPS"
    local _c
    printf "  确认开始安装？[Y/n] "
    read_answer "Y"; _c="$REPLY_ANS"
    case "$_c" in
        N|n) echo ""; echo "  已取消，未做任何修改。"; exit 0 ;;
    esac
    echo ""
    return 0
}

custom_components_defaults() { MODE_STEPS="组件: 默认值(mihomo内核 + Web面板)"; }

choose_install_mode

# 菜单交互结束，此后所有输出同时写入部署日志
exec > >(tee -a "$LOG_FILE") 2>&1
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 安装模式: $MODE_LABEL （$MODE_STEPS）" >> "$LOG_FILE"

echo -e "${GREEN}"
echo "=============================================================="
echo "  UU + mihomo(WARP) 一键部署  v12.8"
# 注意：不要写成 $( ... || '' )，否则 shell 会把空串当命令执行 -> 退出码 127 -> 误触发 ERR 陷阱
MODE_TXT="${MODE_LABEL:-完整部署}"
[ "$CHECK_ONLY" = 1 ]   && MODE_TXT="仅自检"
[ "$OFFLINE" = 1 ]      && MODE_TXT="$MODE_TXT / 离线"
[ "$NO_CONTAINER" = 1 ] && MODE_TXT="$MODE_TXT / 不启容器"
echo "  模式: $MODE_TXT"
echo "  开始: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="
echo -e "${NC}"

# ============================================================================
#  EOL 发行版适配 + Docker 多级兜底安装（v12.2）
# ----------------------------------------------------------------------------
#  背景：Debian 10(buster) 等已停止维护的发行版，deb.debian.org / security.debian.org
#  已不再提供 Release 文件，get.docker.com 脚本必然失败。实测报错：
#    DEPRECATION WARNING / E: 仓库 "... buster Release" 不再含有 Release 文件
#  适配策略：
#    apt 源：检测到 EOL 后切到 archive.debian.org（备份原文件 + check-valid-until=no）
#    Docker：①官方脚本(仅非 EOL) → ②官方静态二进制(推荐) → ③归档源 docker.io
#    Compose：①apt 插件 → ②GitHub 固定版本二进制 + cli-plugins 软链
#  说明：本段自带下载逻辑，不调用后面的 download_with_mirrors（其定义在文件更后，
#        在本步骤执行时尚未加载，调用会 command not found）。
# ============================================================================
EOL_DISTRO=0; EOL_FIXED=0

detect_eol_distro() {
    local _id="${ID:-unknown}" _ver="${VERSION_ID:-0}" _major
    _major="${_ver%%.*}"; case "$_major" in ''|*[!0-9]*) _major=0 ;; esac
    case "$_id" in
        debian) [ "$_major" -le 11 ] && EOL_DISTRO=1 ;;          # 10/11 均已过维护期
        ubuntu) case "$_ver" in 16.04|18.04|20.04|20.10|21.04|21.10|22.10|23.04|23.10) EOL_DISTRO=1 ;; esac ;;
        centos) [ "$_major" -le 8 ] && EOL_DISTRO=1 ;;
        rhel)   [ "$_major" -le 7 ] && EOL_DISTRO=1 ;;
    esac
    return 0
}

repair_eol_sources() {
    [ "$(id -u)" = 0 ] || { warn "非 root，跳过源修复"; return 1; }
    local _sl=/etc/apt/sources.list _ts
    _ts="$(date +%Y%m%d%H%M%S)"
    if [ -f "$_sl" ]; then
        cp -a "$_sl" "${_sl}.bak.eol.${_ts}" && ok "已备份原源文件 -> ${_sl}.bak.eol.${_ts}"
    fi
    # 归档源的 Release 里 Valid-Until 早已过期，必须关掉有效期校验
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99-uu-no-check-valid-until
    case "${ID:-}" in
        debian)
            cat > "$_sl" <<EOF_APT
deb [check-valid-until=no] http://archive.debian.org/debian ${VERSION_CODENAME:-buster} main contrib non-free
deb [check-valid-until=no] http://archive.debian.org/debian-security ${VERSION_CODENAME:-buster}/updates main contrib non-free
EOF_APT
            ;;
        ubuntu)
            cat > "$_sl" <<EOF_APT
deb http://old-releases.ubuntu.com/ubuntu ${VERSION_CODENAME:-focal} main restricted universe multiverse
deb http://old-releases.ubuntu.com/ubuntu ${VERSION_CODENAME:-focal}-updates main restricted universe multiverse
deb http://old-releases.ubuntu.com/ubuntu ${VERSION_CODENAME:-focal}-security main restricted universe multiverse
EOF_APT
            ;;
        *) warn "未知发行版 ${ID:-unknown}，不自动改源"; return 1 ;;
    esac
    ok "已切换到归档源（${ID} ${VERSION_CODENAME:-}）"
    info "第三方源（如 nginx.org）若仍失效，请自行处理 /etc/apt/sources.list.d/ 下对应文件"
    EOL_FIXED=1
    apt-get -o Acquire::Check-Valid-Until=false update >/dev/null 2>&1 \
        || warn "apt update 仍有个别源失败，继续尝试安装"
    return 0
}

ensure_usable_apt_sources() {
    detect_eol_distro
    [ "$EOL_DISTRO" = 1 ] || return 0
    warn "检测到已停止维护的发行版：${PRETTY_NAME:-${ID:-unknown} ${VERSION_ID:-}}"
    warn "官方仓库已下线（Release 文件不再提供），Docker 与部分依赖将无法安装"
    local _do=1
    if [ -n "${UU_FIX_EOL:-}" ]; then
        _do="$UU_FIX_EOL"
    elif [ -t 0 ] || [ "${UU_INTERACTIVE:-0}" = 1 ]; then
        pick_yes_no "是否自动切换到归档源？[Y/n] " Y; _do="$PICKED"
    fi
    if [ "$_do" = 1 ]; then
        repair_eol_sources || true
    else
        warn "已跳过源修复；若后续失败，请手动切换归档源后重跑（脚本可安全重复执行）"
    fi
    return 0
}

install_docker_static() {
    local _arch _ver _url _tmp=/tmp/docker-static.tgz
    case "$(uname -m)" in
        x86_64|amd64) _arch=x86_64 ;; aarch64|arm64) _arch=aarch64 ;;
        armv7l|armhf) _arch=armhf ;; *) warn "不支持的架构 $(uname -m)"; return 1 ;;
    esac
    _ver="${DOCKER_STATIC_VERSION:-24.0.7}"
    _url="https://download.docker.com/linux/static/stable/${_arch}/docker-${_ver}.tgz"
    info "下载 Docker 静态二进制 ${_ver} (${_arch})..."
    rm -rf /tmp/docker
    if ! curl -fsSL --connect-timeout 15 --max-time 600 "$_url" -o "$_tmp" 2>/dev/null; then
        warn "静态包下载失败"; return 1
    fi
    tar -xzf "$_tmp" -C /tmp >/dev/null 2>&1 || { warn "静态包解压失败"; return 1; }
    [ -x /tmp/docker/dockerd ] || { warn "静态包内容异常（缺 dockerd）"; return 1; }
    install -m 0755 /tmp/docker/docker /tmp/docker/dockerd /tmp/docker/containerd \
                    /tmp/docker/containerd-shim-runc-v2 /tmp/docker/ctr /tmp/docker/runc \
                    /tmp/docker/docker-init /tmp/docker/docker-proxy /usr/local/bin/ 2>/dev/null \
        || { warn "复制 Docker 二进制失败"; return 1; }
    if command -v systemctl >/dev/null 2>&1; then
        cat > /etc/systemd/system/docker.service <<'EOF_DOCKER_SVC'
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/dockerd
ExecReload=/bin/kill -s HUP $MAINPID
Restart=always
RestartSec=2
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
Delegate=yes
KillMode=process

[Install]
WantedBy=multi-user.target
EOF_DOCKER_SVC
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable docker  >/dev/null 2>&1 || true
        systemctl start  docker  >/dev/null 2>&1 || { ( /usr/local/bin/dockerd >/dev/null 2>&1 & ); sleep 3; }
    else
        ( /usr/local/bin/dockerd >/dev/null 2>&1 & ); sleep 3
    fi
    rm -rf /tmp/docker "$_tmp"
    ok "Docker 安装完成（静态二进制 ${_ver}，不依赖发行版仓库）"
    return 0
}

install_docker() {
    info "尝试安装 Docker..."
    # ① 官方脚本：EOL 发行版已被明确拒绝，直接跳过（省去脚本内 20 秒等待）
    if [ "$EOL_DISTRO" != 1 ]; then
        if curl -fsSL --connect-timeout 15 --max-time 300 https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null; then
            sh /tmp/get-docker.sh && { rm -f /tmp/get-docker.sh; ok "Docker 安装完成（官方脚本）"; return 0; }
        fi
        rm -f /tmp/get-docker.sh
        warn "官方脚本安装失败，尝试其他方式"
    else
        info "发行版已停止维护，跳过官方脚本"
    fi
    # ② 静态二进制（版本新、与发行版解耦，EOL 场景首选）
    install_docker_static && return 0
    # ③ 归档源里的 docker.io（兜底，版本较旧）
    if command -v apt-get >/dev/null 2>&1; then
        info "尝试从归档源安装 docker.io ..."
        if DEBIAN_FRONTEND=noninteractive apt-get -y -o Acquire::Check-Valid-Until=false \
             install docker.io >/dev/null 2>&1; then
            ok "Docker 安装完成（归档源 docker.io，版本较旧）"; return 0
        fi
        warn "归档源 docker.io 安装失败"
    fi
    return 1
}

install_compose() {
    docker compose version >/dev/null 2>&1 && { ok "docker compose 已就绪"; return 0; }
    command -v docker-compose >/dev/null 2>&1 && { ok "docker-compose 已就绪"; return 0; }
    info "安装 docker compose ..."
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get -y -o Acquire::Check-Valid-Until=false \
            install docker-compose-plugin >/dev/null 2>&1 \
            && docker compose version >/dev/null 2>&1 \
            && { ok "docker compose 安装完成（apt 插件）"; return 0; }
    fi
    local _v="${DOCKER_COMPOSE_VERSION:-v2.24.5}"
    if curl -fsSL --connect-timeout 15 --max-time 300 \
        "https://github.com/docker/compose/releases/download/${_v}/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose 2>/dev/null; then
        chmod +x /usr/local/bin/docker-compose
        ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
        mkdir -p /usr/local/lib/docker/cli-plugins
        ln -sf /usr/local/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
        ok "docker compose 安装完成（${_v} 二进制）"; return 0
    fi
    warn "docker compose 安装失败（缺失会导致后续容器编排失败）"
    return 1
}

# =============================================================================
#  步骤 0/10：环境预检（fail-fast）
#  目的：在【任何写操作之前】一次性查清"这台机器能不能装"。
#    FATAL -> 打印明确原因并安全退出，绝不留下半成品
#    WARN  -> 记录并在结尾汇总，不阻断（多为可绕过 / 可后处理 / 可由后续步骤自动修复）
#  关键原则：凡【后续步骤 2 能自动安装/修复】的项（Docker、docker-compose、基础命令、
#            乃至 EOL 发行版的归档源），一律只判 WARN 并放行，绝不在自动安装逻辑运行前
#            就一刀 FATAL 把部署拦死（这是 v12.7 在全新 Debian 10 buster 上踩的坑）。
#  --preflight-only：只输出这份报告随即退出，便于先把环境信息交给他人排查。
# =============================================================================
PF_FATAL=0
PF_WARN_LIST=""
pf_fatal(){ echo -e "${RED}  [FATAL]${NC} $*"; PF_FATAL=1; }
pf_warn(){  echo -e "${YELLOW}  [WARN]${NC} $*";  PF_WARN_LIST="${PF_WARN_LIST}    - $*\n"; }
pf_ok(){    echo -e "${GREEN}  [OK]${NC} $*"; }
pf_info(){  echo -e "${BLUE}  [信息]${NC} $*"; }
pf_need(){ command -v "$1" >/dev/null 2>&1; }

# 预检专用：提前加载发行版标识（步骤 1 会再次加载；此处先加载，使 preflight 内的
#           detect_eol_distro 能读到 ID/VERSION_ID，从而正确判断 EOL 归档源可修复性）。
[ -r /etc/os-release ] && { . /etc/os-release 2>/dev/null || true; }

# 预检专用：本机是否存在受支持的包管理器（决定"缺失命令能否由步骤 2 自动安装"）
_pf_pkgmgr_available() {
    for _pm in apt-get dnf yum apk pacman zypper; do
        command -v "$_pm" >/dev/null 2>&1 && return 0
    done
    return 1
}

# 预检专用：Docker 缺失时，判断步骤 2 是否"有能力"自动安装（只做可行性探测，不改动任何东西）
#   满足任一即可判定为可安装：
#     a) 能下载官方静态二进制（直连 download.docker.com 或 github，完全不依赖发行版仓库）
#        —— 这是 EOL 发行版的首选路径，连 apt 源坏掉也能装
#     b) apt 可用（非 EOL 源可更新成功），或 EOL 发行版且可切归档源
#        （脚本步骤 2 的 ensure_usable_apt_sources 会自动切 archive.debian.org 并关效期校验）
_pf_docker_installable() {
    # a) 静态二进制路径：只要能联网下载即可
    if command -v curl >/dev/null 2>&1; then
        if curl -sS --connect-timeout 8 --max-time 15 -o /dev/null \
              "https://download.docker.com/linux/static/stable/$(uname -m)/" 2>/dev/null \
           || curl -sS --connect-timeout 8 --max-time 15 -o /dev/null https://github.com 2>/dev/null; then
            return 0
        fi
    fi
    # b) apt 路径：update 成功即可走 apt；否则 EOL 且可切归档源也行
    if command -v apt-get >/dev/null 2>&1; then
        local _rc=1
        if command -v timeout >/dev/null 2>&1; then
            timeout 60 apt-get update -qq >/dev/null 2>&1; _rc=$?
        else
            apt-get update -qq >/dev/null 2>&1; _rc=$?
        fi
        [ "$_rc" = 0 ] && return 0
        # EOL 且可切归档源：步骤 2 会自动修复（需 root 且存在 sources.list）
        if [ "$(id -u)" = 0 ] && [ -r /etc/apt/sources.list ] \
           && { detect_eol_distro; [ "$EOL_DISTRO" = 1 ]; }; then
            return 0
        fi
    fi
    return 1
}

step "步骤 0/10：环境预检（不满足即中止，不产生半截安装）"

echo "  ---- 系统与身份 ----"
pf_info "操作系统: $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" || cat /etc/issue 2>/dev/null | head -1 || true)"
pf_info "内核: $(uname -r)    架构: $(uname -m)"
pf_info "主机名: $(hostname)    时间: $(date '+%F %T %Z')"
if [ "$(id -u)" -eq 0 ]; then pf_ok "root 权限（uid=0）"; else pf_fatal "必须以 root 运行（当前 uid=$(id -u)）。请先 sudo -i。"; fi

echo "  ---- 解释器（缺则脚本根本无法运行，必须 FATAL） ----"
pf_need bash && pf_ok "命令存在: bash" || pf_fatal "缺少 bash（脚本解释器，无法自动安装，请先安装 bash 后再运行）"

echo "  ---- 基础命令（缺失时由步骤 2 自动安装，仅当无法自动安装才 FATAL） ----"
if _pf_pkgmgr_available; then
    pf_ok "检测到包管理器，缺失命令可由步骤 2 自动补装"
else
    pf_warn "未检测到常见包管理器（apt/dnf/yum/apk/pacman/zypper）；缺失命令将无法自动安装"
fi
for c in sed awk grep ip iptables; do
    if pf_need "$c"; then
        pf_ok "命令存在: $c"
    elif _pf_pkgmgr_available; then
        pf_warn "缺少命令: $c（步骤 2 将自动安装，预检不阻断）"
    else
        pf_fatal "缺少必需命令: $c，且本机无受支持包管理器、无法自动安装（请先安装 $c 或对应包管理器）"
    fi
done
for c in curl wget tar gzip; do
    if pf_need "$c"; then pf_ok "命令存在: $c"; else pf_warn "缺少命令: $c（下载/解压可能受限，脚本有多级兜底但不保证）"; fi
done

echo "  ---- Docker（缺失时由步骤 2 自动安装，仅在无法自动安装时才 FATAL） ----"
if pf_need docker; then
    pf_info "Docker 版本: $(docker --version 2>/dev/null || echo '未知')"
    if docker info >/dev/null 2>&1; then
        pf_ok "Docker 守护进程可访问"
    else
        pf_fatal "Docker 已安装但守护进程不可访问（请先 systemctl start docker，或重跑本脚本由步骤 2 尝试启动）"
    fi
    if docker compose version >/dev/null 2>&1 || docker-compose version >/dev/null 2>&1; then
        pf_ok "docker compose 可用: $(docker compose version --short 2>/dev/null || docker-compose version --short 2>/dev/null || true)"
    else
        pf_warn "docker compose 不可用（步骤 2 会尝试自动安装；失败将无法编排容器）"
    fi
else
    # 缺失：只要步骤 2 有能力自动安装（含 EOL 归档源 / 静态二进制兜底）就放行，否则 FATAL
    if _pf_docker_installable; then
        pf_warn "Docker 未安装 —— 步骤 2 将自动安装（含 EOL 归档源 / 官方静态二进制兜底），预检不阻断"
    else
        pf_fatal "Docker 未安装且无法自动安装（无可用软件源/网络，也无法下载静态二进制）。请先联网或手动安装 Docker 后重跑。"
    fi
fi

echo "  ---- 内核模块 ----"
for m in macvlan bridge; do
    if lsmod 2>/dev/null | grep -q "^$m" || modprobe -n "$m" >/dev/null 2>&1; then
        pf_ok "内核模块可用: $m"
    else
        pf_warn "内核模块异常: $m（macvlan 容器将无法联网，常见于 OpenVZ/LXC 虚拟化）"
    fi
done

echo "  ---- 目录与磁盘 ----"
if [ -d "$BASE_DIR" ] && [ ! -w "$BASE_DIR" ]; then
    pf_fatal "部署目录存在但不可写: $BASE_DIR（检查权限或改用 --base-dir）"
else
    pf_ok "部署目录可写/可创建: $BASE_DIR"
fi
_df_avail="$(df -Pk /opt 2>/dev/null | awk 'NR==2{print $4}' || true)"
if [ -n "${_df_avail:-}" ] && [ "$_df_avail" -lt 524288 ]; then
    pf_warn "/opt 可用空间不足 512MB（当前约 $((_df_avail/1024))MB），镜像与内核下载可能失败"
else
    pf_ok "磁盘空间充足（可用约 $((${_df_avail:-0}/1024))MB）"
fi

echo "  ---- 网络与软件源 ----"
if pf_need curl; then
    if curl -sS --max-time 8 -o /dev/null https://github.com 2>/dev/null; then
        pf_ok "可访问 github.com（mihomo 内核下载）"
    else
        pf_warn "无法访问 github.com —— 步骤 5 下载 mihomo 可能失败（脚本有多镜像兜底）"
    fi
fi
if pf_need apt-get; then
    _pf_apt_ok=1
    if command -v timeout >/dev/null 2>&1; then
        timeout 60 apt-get update -qq >/dev/null 2>&1 || _pf_apt_ok=0
    else
        apt-get update -qq >/dev/null 2>&1 || _pf_apt_ok=0
    fi
    if [ "$_pf_apt_ok" = 1 ]; then
        pf_ok "apt 软件源可用"
    else
        pf_warn "apt-get update 失败 —— 软件源不可用（EOL 系统请让脚本自动切归档源，或先手工修复 /etc/apt/sources.list）"
    fi
fi

echo "  ---- 残留与冲突 ----"
if [ -f "$BASE_DIR/docker-compose.yaml" ]; then
    pf_warn "已存在 $BASE_DIR/docker-compose.yaml —— 脚本会幂等保留它；若要换容器 IP 必须先备份并删除该文件再重跑"
fi
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx uuplugin; then
    pf_info "已存在容器 uuplugin（状态: $(docker inspect -f '{{.State.Status}}' uuplugin 2>/dev/null || true)），本次将复用/重建"
else
    pf_info "未发现既有 uuplugin 容器（全新安装路径）"
fi
if [ -d "$BASE_DIR/config" ] && [ -z "$(ls -A "$BASE_DIR/config" 2>/dev/null)" ]; then
    pf_info "$BASE_DIR/config 为空：步骤 8 会自动从镜像补齐（这正是此前 UCI 加载失败的坑）"
fi

echo "  ---- 容器工具链（影响脚本内部写法，仅提示） ----"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx uuplugin; then
    for t in nohup timeout flock uci ip; do
        if docker exec uuplugin sh -c "command -v $t >/dev/null 2>&1" 2>/dev/null; then
            pf_ok "容器内可用: $t"
        else
            pf_info "容器内【没有】: $t —— 脚本已针对性规避（实测该容器缺 nohup/timeout/getent/dig/curl/base64）"
        fi
    done
fi

echo "  ---- IP 冲突（最高优先级的隐性故障源） ----"
_HOSTIP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1 || true)"
pf_info "宿主主 IP: ${_HOSTIP:-未知}"
pf_info "若下方出现「容器 IP 已被占用」，务必用 arping 复核；macvlan 撞 IP 会导致网络时通时断"

if [ "$PF_FATAL" -ne 0 ]; then
    echo ""
    die "环境预检未通过（见上方 [FATAL]）。修正后重新执行即可，本脚本可安全重复运行。"
fi
if [ -n "$PF_WARN_LIST" ]; then
    echo -e "${YELLOW}  预检告警汇总（不阻断，但请留意）：${NC}"
    printf "%b" "$PF_WARN_LIST"
fi

if [ "$PREFLIGHT_ONLY" = "1" ]; then
    echo ""
    echo -e "${GREEN}预检完成（--preflight-only）：以上即排查所需的完整环境快照，可原样提供给他人分析。${NC}"
    exit 0
fi

# ---------------------------------------------------------------- 步骤 1
STEP_NO="1/10 前置检查"
step "步骤 1/10：前置检查"
[ "$(id -u)" -eq 0 ] || die "必须以 root 身份运行（当前 uid=$(id -u)）。请 sudo -i 后再执行。"
ok "root 权限确认"

OS_ID="unknown"; PKG_MGR="none"
if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    info "操作系统: ${PRETTY_NAME:-$OS_ID}"
else
    warn "缺少 /etc/os-release，无法识别发行版；将按通用方式处理"
fi
for pm in apt-get dnf yum apk pacman zypper; do
    if command -v "$pm" >/dev/null 2>&1; then PKG_MGR="$pm"; break; fi
done
info "包管理器: $PKG_MGR"
[ "$PKG_MGR" = "none" ] && warn "未发现已知包管理器，依赖缺失时只能靠手工安装"

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64) MIHOMO_ARCH="amd64" ;;
    aarch64|arm64) MIHOMO_ARCH="arm64" ;;
    armv7l|armhf)  MIHOMO_ARCH="armv7" ;;
    *) die "不支持的 CPU 架构: $ARCH（支持 x86_64 / aarch64 / armv7）" ;;
esac
info "CPU 架构: $ARCH -> mihomo 使用 $MIHOMO_ARCH"
ok "平台识别完成"

# EOL 发行版（Debian 10 等）：官方源已下线，必须先切归档源才能继续安装依赖与 Docker
ensure_usable_apt_sources

# 内核模块（仅提示，不阻断——某些云主机模块编译进内核，lsmod 看不到）
if [ -r /proc/modules ]; then
    if ! grep -qE '^macvlan|^bridge' /proc/modules 2>/dev/null; then
        info "未在 /proc/modules 看到 macvlan/bridge（可能已编译进内核）；若容器网络创建失败请检查内核配置"
    else
        ok "内核已加载 macvlan/bridge 模块"
    fi
fi

# 磁盘空间（至少需要 2GB，mihomo 二进制约 36MB + 镜像较大）
AVAIL_KB="$(df -Pk "$BASE_DIR" 2>/dev/null | awk 'NR==2{print $4}' || true)"
AVAIL_KB="${AVAIL_KB:-0}"
if [ "$AVAIL_KB" -gt 0 ] && [ "$AVAIL_KB" -lt 2097152 ]; then
    warn "部署目录可用空间不足 2GB（约 $((AVAIL_KB/1024))MB），镜像拉取可能失败"
else
    ok "磁盘空间检查通过（可用约 $((AVAIL_KB/1024))MB）"
fi

# ---------------------------------------------------------------- 步骤 2
STEP_NO="2/10 依赖检查与安装"
step "步骤 2/10：依赖检查与安装"
# 命令名 -> 包名映射（关键：不同发行版包名不同，直接拿命令名去装必然失败）
pkg_name() {
    local c="$1"
    case "$c" in
        ip)       case "$PKG_MGR" in dnf|yum) echo iproute ;; *) echo iproute2 ;; esac ;;
        iptables) echo iptables ;;
        ping)     case "$PKG_MGR" in apt-get) echo iputils-ping ;; *) echo iputils ;; esac ;;
        ps)       case "$PKG_MGR" in apt-get|zypper|apk) echo procps ;; *) echo procps-ng ;; esac ;;
        getent)   case "$PKG_MGR" in apt-get) echo libc-bin ;; dnf|yum) echo glibc-common ;; apk) echo musl-utils ;; *) echo glibc ;; esac ;;
        awk)      echo gawk ;;
        find|xargs) echo findutils ;;
        mktemp|cmp|stat|timeout|tr|sort|cut|wc|head|tail|od|base64) echo coreutils ;;
        *) echo "$c" ;;
    esac
}

install_pkg() {
    local miss=("$@")
    [ ${#miss[@]} -eq 0 ] && return 0
    info "准备安装缺失依赖包: ${miss[*]}"
    case "$PKG_MGR" in
        apt-get) export DEBIAN_FRONTEND=noninteractive
                 apt-get update -y >/dev/null 2>&1 || warn "apt-get update 失败，继续尝试安装"
                 apt-get install -y "${miss[@]}" || die "依赖安装失败: ${miss[*]}" ;;
        dnf)     dnf install -y "${miss[@]}"     || die "依赖安装失败: ${miss[*]}" ;;
        yum)     yum install -y "${miss[@]}"     || die "依赖安装失败: ${miss[*]}" ;;
        apk)     apk add --no-cache "${miss[@]}" || die "依赖安装失败: ${miss[*]}" ;;
        pacman)  pacman -Sy --noconfirm "${miss[@]}" || die "依赖安装失败: ${miss[*]}" ;;
        zypper)  zypper -n install "${miss[@]}"  || die "依赖安装失败: ${miss[*]}" ;;
        *)       die "未找到受支持的包管理器，请手动安装: ${miss[*]}" ;;
    esac
}
MISSING=(); MISSING_PKGS=()
for cmd in curl wget ip iptables awk grep sed tar gzip stat timeout find xargs ps ping mktemp cmp; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING+=("$cmd"); MISSING_PKGS+=("$(pkg_name "$cmd")")
    fi
done
if [ ${#MISSING[@]} -gt 0 ]; then
    # 包名去重（纯字符串实现，不依赖 sort/awk，避免依赖未装时的鸡生蛋问题）
    UNIQ=""
    for _p in "${MISSING_PKGS[@]}"; do
        case " $UNIQ " in *" $_p "*) ;; *) UNIQ="$UNIQ $_p" ;; esac
    done
    MISSING_PKGS=($UNIQ)
    info "缺失命令: ${MISSING[*]}"
    install_pkg "${MISSING_PKGS[@]}"
    ok "基础依赖安装完成"
else
    ok "基础依赖均已就绪"
fi

if ! command -v docker >/dev/null 2>&1; then
    [ "$CHECK_ONLY" = 1 ] && { warn "自检模式：未检测到 Docker（正式运行会自动安装）"; }
    if [ "$CHECK_ONLY" = 0 ]; then
        warn "未检测到 Docker，开始安装..."
        install_docker || die "Docker 安装失败（已尝试：官方脚本 / 静态二进制 / 归档源 docker.io）。
             离线环境请手动安装 Docker 后重跑；仓库失效时可先按提示切换归档源再重跑。"
    fi
else
    # 注意：管道 + head 会让上游收到 SIGPIPE(141)，在 set -e/-o pipefail 下会误触发 ERR 中止，
    # 因此所有「取首行」的命令替换都要加 || true。
    ok "Docker 已就绪: $(docker --version 2>/dev/null | head -1 || true)"
fi

if [ "$CHECK_ONLY" = 0 ]; then
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable docker >/dev/null 2>&1 || true
        systemctl start  docker >/dev/null 2>&1 || true
    else
        ( dockerd >/dev/null 2>&1 & ) || true
    fi
    docker info >/dev/null 2>&1 || die "Docker 守护进程未运行。请执行 systemctl start docker（或手动启动 dockerd）后重跑。"
    ok "Docker 守护进程运行中"
    install_compose || die "docker-compose 安装失败，请手动安装后重跑（后续容器编排依赖它）。"
fi

# ---------------------------------------------------------------- 步骤 3
STEP_NO="3/10 目录结构"
step "步骤 3/10：目录结构与备份保留策略"
mkdir -p "$BASE_DIR"/{conf,scripts,mihomo/rules,log,config,core} "$BACKUP_DIR"
ok "目录结构就绪"

# 备份保留：只保留最近 N 份，避免无限膨胀占满磁盘
if [ -d "$BASE_DIR/backups" ]; then
    TOTAL=$(ls -1 "$BASE_DIR/backups" 2>/dev/null | wc -l | tr -d ' ' || true)
    if [ "${TOTAL:-0}" -gt "$UU_RETAIN_BACKUPS" ]; then
        DEL=$((TOTAL - UU_RETAIN_BACKUPS))
        ls -1 "$BASE_DIR/backups" | sort | head -n "$DEL" | while read -r old; do
            rm -rf "$BASE_DIR/backups/$old"
        done
        info "已清理旧备份 $DEL 份（保留最近 $UU_RETAIN_BACKUPS 份）"
    fi
fi

# ---------------------------------------------------------------- 工具函数
deploy_file() {
    local dest="$1" delim="$2" mode="$3" protect_marker="$4" content="$5"
    local name; name="$(basename "$dest")"
    mkdir -p "$(dirname "$dest")"
    if [ "$CHECK_ONLY" = 1 ]; then
        [ -n "$content" ] && ok "$name 内嵌内容校验通过（${#content} 字符）" || warn "$name 内嵌内容为空"
        return 0
    fi
    if [ -f "$dest" ] && [ -n "$protect_marker" ] && grep -qF "$protect_marker" "$dest" 2>/dev/null; then
        chmod "$mode" "$dest" 2>/dev/null || true
        ok "$name 已含修复标记，跳过覆盖（保护现场修复）"
        return 0
    fi
    if [ -f "$dest" ]; then
        local tmp_new; tmp_new="$(mktemp)"
        printf '%s\n' "$content" > "$tmp_new"
        if cmp -s "$tmp_new" "$dest"; then
            rm -f "$tmp_new"; chmod "$mode" "$dest" 2>/dev/null || true
            ok "$name 内容一致，无需变更"; return 0
        fi
        rm -f "$tmp_new"
        cp -p "$dest" "$BACKUP_DIR/${name}.bak" 2>/dev/null || warn "$name 备份失败（继续覆盖）"
        info "$name 已备份至 $BACKUP_DIR/${name}.bak"
    fi
    printf '%s\n' "$content" > "$dest" || die "写入 $dest 失败。"
    chmod "$mode" "$dest" || die "设置权限 $mode 于 $dest 失败。"
    chown root:root "$dest" 2>/dev/null || true
    ok "$name 已部署（权限 $mode）"
}

# 大文件（mihomo 内核约 23MB）在慢链路（实测低至 ~85KB/s，全量约 270s）上耗时可达数分钟。
# 原写死 300s 会卡在临界值表现为“假死”；改为可配置，默认放宽到 900s，仍是有界超时。
# 可用环境变量覆盖：DL_MAX_TIME=300 bash install_uu.sh
DL_MAX_TIME="${DL_MAX_TIME:-900}"

# =============================================================================
#  mihomo 下载优化模块（新增）
# -----------------------------------------------------------------------------
#  能力：架构/版本自动探测 → 多源测速择优 → 断点续传 + 失败重试 → 完整性校验 → 失败自动换源
#  可配置变量（全部支持环境变量覆盖）：
#    MIHOMO_VERSION_SPEC      指定版本；留空则自动探测最新正式版（如 v1.19.31）
#    MIHOMO_INSTALL_DIR       mihomo 安装目录（默认 $BASE_DIR/mihomo）
#    MIHOMO_CONNECT_TIMEOUT   连接超时秒数          （默认 10）
#    MIHOMO_MAX_TIME          单次下载总时限秒数      （默认 900，慢链路可调大）
#    MIHOMO_RETRY             每个源的重试次数        （默认 2）
#    MIHOMO_RESUME            是否断点续传 1/0        （默认 1，使用 curl -C -）
#    MIHOMO_MIN_SIZE          最小可接受字节数        （默认 1048576，即 1MB）
#    MIHOMO_SPEEDTEST         是否多源测速后择优 1/0  （默认 1）
#    MIHOMO_VERIFY_SHA        是否尝试 sha256 校验 1/0（默认 1，取不到摘要则自动跳过）
#    MIHOMO_SOURCES_EXTRA     额外镜像前缀，空格分隔  （默认 "ghproxy.com gh-proxy.com ghp.ci"）
# =============================================================================

MIHOMO_VERSION_SPEC="${MIHOMO_VERSION_SPEC:-}"
MIHOMO_CONNECT_TIMEOUT="${MIHOMO_CONNECT_TIMEOUT:-10}"
MIHOMO_MAX_TIME="${MIHOMO_MAX_TIME:-900}"
MIHOMO_RETRY="${MIHOMO_RETRY:-2}"
MIHOMO_RESUME="${MIHOMO_RESUME:-1}"
MIHOMO_MIN_SIZE="${MIHOMO_MIN_SIZE:-1048576}"
MIHOMO_SPEEDTEST="${MIHOMO_SPEEDTEST:-1}"
MIHOMO_VERIFY_SHA="${MIHOMO_VERIFY_SHA:-1}"
MIHOMO_SOURCES_EXTRA="${MIHOMO_SOURCES_EXTRA:-ghproxy.com gh-proxy.com ghp.ci}"

# --- 架构识别：输出候选变体（空格分隔，按优先级） ---
mihomo_detect_arch() {
    local a; a="$(uname -m)"
    case "$a" in
        x86_64|amd64)  printf '%s' "amd64-compatible amd64" ;;   # 老 CPU 无 AVX2，优先 compatible
        aarch64|arm64) printf '%s' "arm64" ;;
        armv7l|armv6l) printf '%s' "armv7" ;;
        armv5*)        printf '%s' "armv5" ;;
        mips*)         printf '%s' "mipsle-softfloat" ;;
        *)             printf '%s' "amd64-compatible amd64" ;;
    esac
}

# --- 版本探测：优先 API（含镜像），回退 releases/latest 的 302 Location ---
mihomo_resolve_version() {
    local v="" j="" loc="" api m
    api="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
    for m in "$api" "https://ghproxy.com/${api}" "https://gh-proxy.com/${api}"; do
        j="$(curl -fsSL --connect-timeout 8 --max-time 20 "$m" 2>/dev/null || true)"
        [ -n "$j" ] || continue
        # 排除预发布
        case "$j" in *'"prerelease":true'*|*'"prerelease": true'*) continue ;; esac
        v="$(printf '%s' "$j" | grep -oE '"tag_name"[^,]*' | head -n1 | cut -d'"' -f4)"
        case "$v" in *[Aa]lpha*|*[Bb]eta*|*-rc*|*rc[0-9]*) v=""; continue ;; esac
        [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    done
    # 回退：解析 302 Location（规避 API 限流）
    loc="$(curl -sSI --connect-timeout 8 --max-time 20 \
           "https://github.com/MetaCubeX/mihomo/releases/latest" 2>/dev/null \
           | grep -i '^location:' | tail -n1 | tr -d '\r')"
    v="${loc##*/tag/}"
    case "$v" in
        http*|*location*) v="" ;;
        *[Aa]lpha*|*[Bb]eta*|*-rc*) v="" ;;
    esac
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    return 1
}

# --- 组装候选源：原站 + 各镜像前缀 ---
mihomo_build_sources() {
    local url="$1" p
    printf '%s' "$url"
    for p in $MIHOMO_SOURCES_EXTRA; do
        printf ' https://%s/%s' "$p" "$url"
    done
}

# --- 多源测速：返回耗时最小的源 ---
mihomo_pick_fastest() {
    local url="$1" s t best="" bestt=""
    for s in $(mihomo_build_sources "$url"); do
        t="$(curl -fsSL -o /dev/null -w '%{time_total}' \
               --connect-timeout 6 --max-time 25 -r 0-65535 "$s" 2>/dev/null || true)"
        [ -n "$t" ] || continue
        if [ -z "$best" ]; then
            best="$s"; bestt="$t"
        elif awk -v a="$t" -v b="$bestt" 'BEGIN{exit !(a<b)}'; then
            best="$s"; bestt="$t"
        fi
    done
    [ -n "$best" ] && printf '%s' "$best"
}

# --- 完整性校验：大小 → gzip 头 → （可选）sha256 ---
mihomo_verify_file() {
    local f="$1" want_sha="$2" size
    [ -s "$f" ] || { warn "下载文件为空"; return 1; }
    size="$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)"
    if [ "${size:-0}" -lt "$MIHOMO_MIN_SIZE" ]; then
        warn "文件过小(${size} 字节 < ${MIHOMO_MIN_SIZE})，判定不完整"
        return 1
    fi
    # gzip 头校验（1f 8b）
    if ! gzip -t "$f" >/dev/null 2>&1; then
        warn "压缩包头校验失败（非 gzip 文件）"
        return 1
    fi
    # sha256（可选）
    if [ "$MIHOMO_VERIFY_SHA" = 1 ] && [ -n "$want_sha" ]; then
        local got
        got="$(sha256sum "$f" 2>/dev/null | awk '{print $1}')"
        if [ -n "$got" ] && [ "$got" != "$want_sha" ]; then
            warn "sha256 校验不匹配（期望 ${want_sha:0:12}… 实际 ${got:0:12}…）"
            return 1
        fi
        [ -n "$got" ] && info "sha256 校验通过"
    fi
    info "完整性校验通过（大小 ${size} 字节）"
    return 0
}

# --- 单文件拉取：断点续传 + 重试，返回 0 成功 ---
mihomo_fetch_resume() {
    local url="$1" out="$2" i rc
    for i in $(seq 1 "$MIHOMO_RETRY"); do
        if [ "$MIHOMO_RESUME" = 1 ] && [ -s "$out" ]; then
            info "断点续传（已有 $(stat -c%s "$out" 2>/dev/null || echo 0) 字节）"
            curl -fsSL -C - --connect-timeout "$MIHOMO_CONNECT_TIMEOUT" \
                 --max-time "$MIHOMO_MAX_TIME" "$url" -o "$out" 2>/dev/null
            rc=$?
        else
            rm -f "$out"
            curl -fsSL --connect-timeout "$MIHOMO_CONNECT_TIMEOUT" \
                 --max-time "$MIHOMO_MAX_TIME" "$url" -o "$out" 2>/dev/null
            rc=$?
        fi
        [ $rc -eq 0 ] && [ -s "$out" ] && return 0
        warn "第 ${i}/${MIHOMO_RETRY} 次拉取失败（curl rc=${rc}）"
        sleep 2
    done
    return 1
}

# --- 主流程：自动探测 → 测速 → 拉核 → 校验 → 失败换源 ---
install_mihomo_optimized() {
    local dir="${MIHOMO_INSTALL_DIR:-$BASE_DIR/mihomo}"
    local bin="$dir/mihomo" tmp="${dir}/mihomo.new.$$" bak="${bin}.bak.$(date +%Y%m%d%H%M%S)"
    local variants ver v base_url sources s fast ok=0 sha=""

    echo ""
    step "mihomo 下载优化：架构/版本探测"
    variants="$(mihomo_detect_arch)"
    info "检测到架构候选: ${variants}"

    if [ -n "$MIHOMO_VERSION_SPEC" ]; then
        ver="$MIHOMO_VERSION_SPEC"; info "使用指定版本: ${ver}"
    else
        ver="$(mihomo_resolve_version 2>/dev/null || true)"
        if [ -n "$ver" ]; then info "自动探测到最新正式版: ${ver}"
        else
            warn "版本探测失败，回退脚本内置版本: ${MIHOMO_VERSION}"
            ver="$MIHOMO_VERSION"
        fi
    fi
    echo -e "  ${CYAN}实际使用版本: ${YELLOW}${ver}${NC}"
    mkdir -p "$dir"
    [ -f "$bin" ] && cp -p "$bin" "$bak" && info "已备份原内核: $(basename "$bak")"

    for v in $variants; do
        base_url="https://github.com/MetaCubeX/mihomo/releases/download/${ver}/mihomo-linux-${v}-${ver}.gz"
        sources="$(mihomo_build_sources "$base_url")"

        # 测速择优：把最快的源排到最前
        if [ "$MIHOMO_SPEEDTEST" = 1 ]; then
            fast="$(mihomo_pick_fastest "$base_url")"
            if [ -n "$fast" ]; then
                info "测速择优命中: ${fast}"
                sources="$fast $(printf '%s' "$sources" | tr ' ' '\n' | grep -v "^${fast}$" | tr '\n' ' ')"
            fi
        fi

        echo -e "\n  ${CYAN}>>> 尝试内核变体: ${v}${NC}"
        for s in $sources; do
            [ -n "$s" ] || continue
            info "拉取源: ${s}"
            rm -f /tmp/mihomo_dl.gz
            if ! mihomo_fetch_resume "$s" /tmp/mihomo_dl.gz; then
                warn "该源拉取失败，切换下一源"; continue
            fi
            # 可选 sha256：尝试取官方摘要文件
            sha=""
            if [ "$MIHOMO_VERIFY_SHA" = 1 ]; then
                sha="$(curl -fsSL --connect-timeout 8 --max-time 20 "${base_url}.sha256" 2>/dev/null | awk '{print $1}' || true)"
            fi
            if ! mihomo_verify_file /tmp/mihomo_dl.gz "$sha"; then
                warn "校验未通过，丢弃该文件并切换下一源"
                rm -f /tmp/mihomo_dl.gz
                continue
            fi
            # 解压到临时文件，实机校验通过后才原子替换
            if gzip -d -c /tmp/mihomo_dl.gz > "$tmp" 2>/dev/null && chmod +x "$tmp" 2>/dev/null \
               && "$tmp" -v >/dev/null 2>&1; then
                mv -f "$tmp" "$bin"
                rm -f /tmp/mihomo_dl.gz
                ok=1
                ok "mihomo 内核部署完成（变体 ${v}）"
                info "版本信息: $("$bin" -v 2>/dev/null | head -n1 || true)"
                break
            else
                warn "解压或实机校验失败，回滚本次安装（原内核未被破坏）"
                rm -f "$tmp" /tmp/mihomo_dl.gz
                continue
            fi
        done
        [ "$ok" = 1 ] && break
    done

    if [ "$ok" != 1 ]; then
        echo ""
        warn "mihomo 内核安装失败：所有架构变体与镜像源均未成功"
        info "可手动指定版本重试：MIHOMO_VERSION_SPEC=vX.Y.Z $0 --with-mihomo"
        info "或指定完整地址：把包放到 /tmp/mihomo.gz 后重跑（脚本会优先使用离线包）"
        [ -f "$bak" ] && info "原内核保持可用: ${bin}"
        return 1
    fi
    return 0
}


download_with_mirrors() {
    # $1=url  $2=输出文件  ; 多镜像 + 重试，全部失败返回 1
    local url="$1" out="$2" m
    local mirrors=(
        "$url"
        "https://ghproxy.com/${url}"
        "https://gh-proxy.com/${url}"
        "https://ghp.ci/${url}"
    )
    for m in "${mirrors[@]}"; do
        if curl -fsSL --connect-timeout 12 --max-time "$DL_MAX_TIME" --retry 2 --retry-delay 2 "$m" -o "$out" 2>/dev/null && [ -s "$out" ]; then
            return 0
        fi
    done
    return 1
}

gen_mac() {
    local m="02" i b
    for i in 1 2 3 4 5; do
        b="$(od -An -N1 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
        [ -n "$b" ] || b="$(printf '%02x' $((RANDOM % 256)))"
        m="$m:$b"
    done
    echo "$m"
}

# ---------------------------------------------------------------- 步骤 4
STEP_NO="4/10 部署脚本与配置"
step "步骤 4/10：部署脚本与配置（幂等 + 覆盖前自动备份）"
info "本次备份目录: $BACKUP_DIR"

deploy_file "$BASE_DIR/manager.sh" "EOF_MANAGER_V7" "755" "" "$(cat <<'EOF_MANAGER_V7'
#!/bin/bash
# ====================================================
# UU 加速全能底座 · 中央管理面板 (v6.0 优化版 · 含 TUN 捕获端口转发修复)
# ====================================================
PANEL_VERSION="v6.0"   # 面板版本标识（v6.0 = 含 TUN 捕获模式端口转发修复的一代）

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[!] 请以 root 权限运行此面板。${NC}"
    exit 1
fi

BASE_DIR="/opt/uuplugin"
LOG_FILE="$BASE_DIR/log/deploy.log"
RULES_DB="$BASE_DIR/conf/forward_rules.conf"
PROXY_SCRIPT="$BASE_DIR/scripts/proxy_manager.sh"
WXPUSHER_CONF="$BASE_DIR/conf/wxpusher.conf"
MONITOR_SCRIPT="$BASE_DIR/scripts/uu_monitor.sh"
PORT_AUDIT_LOG="$BASE_DIR/log/port_forwarding.log"
MIHOMO_SECRET_FILE="$BASE_DIR/conf/mihomo_secret"

# ===== 阶段二：镜像/版本固定（缺陷 4.5：避免 :latest 不可复现）=====
UU_IMAGE="${UU_IMAGE:-dianqk/uuplugin}"
UU_IMAGE_TAG="${UU_IMAGE_TAG:-latest}"
UUPS_IMAGE="${UUPS_IMAGE:-gdfsnhsw/uups}"
UUPS_IMAGE_TAG="${UUPS_IMAGE_TAG:-latest}"
MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.31}"
if [ "$UU_IMAGE_TAG" = "latest" ] || [ "$UUPS_IMAGE_TAG" = "latest" ]; then
    echo -e "${YELLOW}[警告] 当前使用 :latest 标签，部署不可复现；建议通过环境变量固定版本（如 UU_IMAGE_TAG=vx.y.z）。${NC}"
fi

# ===== 阶段二：docker compose 双兼容（要求3 / 缺陷 容错）=====
dkcompose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"; return $?
    fi
    docker-compose "$@"; return $?
}

# ===== 阶段二：共享空闲 IP 嗅探（缺陷 4.9：去除重复定义）=====
find_unused_ip() {
    local start=$1
    for i in $(seq "$start" -1 2); do
        [ "$i" -le 1 ] && break
        local test_ip="${IP_PREFIX}.${i}"
        [ "$test_ip" = "$GATEWAY" ] && continue
        if ! ping -c 1 -W 1 "$test_ip" >/dev/null 2>&1; then
            if ! ip neigh show | grep "^${test_ip} " | grep -q "lladdr"; then
                echo "$test_ip"; return
            fi
        fi
    done
    echo ""
}

pause_enter() {
    echo ""
    read -r -p "👉 按下 回车键 (Enter) 返回上一级..."
    echo ""
}
log() { echo -e "$1" | tee -a "$LOG_FILE"; }

view_log_stream() {
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${YELLOW}   ▶ 正在连接实时日志流... (按下 回车键 即可退出) ◀   ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    tput civis
    ( bash -c "$1" ) >/dev/stdout 2>/dev/null &
    local bash_pid=$!
    read -r || true
    {
        kill -- -"${bash_pid}" 2>/dev/null || true
        pkill -P "${bash_pid}" 2>/dev/null || true
        kill -9 "${bash_pid}" 2>/dev/null || true
    } &>/dev/null
    tput cnorm
    echo -e "\n${GREEN}[OK] 已断开日志连接。${NC}"
    sleep 0.5
}

# ===== 阶段二：多源下载 + 超时容错（要求3：防卡死）=====
mirror_curl() {
    local url="$1" out="$2"
    curl -fsSL --connect-timeout 10 --max-time 60 "$url" -o "$out" 2>/dev/null && return 0
    curl -fsSL --connect-timeout 10 --max-time 60 "https://github.soloplus.xyz/$url" -o "$out" 2>/dev/null && return 0
    curl -fsSL --connect-timeout 10 --max-time 60 "https://ghproxy.com/$url" -o "$out" 2>/dev/null && return 0
    curl -fsSL --connect-timeout 10 --max-time 60 "https://raw.fastgit.org/${url#https://raw.githubusercontent.com/}" -o "$out" 2>/dev/null && return 0
    return 1
}

# ----------------------------------------------------
# 智能依赖安装引擎
# ----------------------------------------------------
check_and_install_env() {
    echo -e "\n${CYAN}>>> [1/7] 正在进行底层环境兼容性检测与依赖补齐 <<<${NC}"
    if ! command -v curl >/dev/null 2>&1 || ! command -v ping >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y curl wget iproute2 iputils-ping gawk grep iptables
        elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm curl wget iproute2 iputils gawk grep iptables || true
        elif command -v yum >/dev/null 2>&1; then yum install -y curl wget iproute iputils gawk grep iptables
        fi
    fi

    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}>>> 未检测到 Docker 环境，正在全自动部署引擎...${NC}"
        # 阶段二(缺陷4.6)：先落盘再执行，且加超时，避免管道直接执行远程脚本的盲注风险
        DOCKER_INSTALL_URL="${DOCKER_INSTALL_URL:-https://get.docker.com}"
        curl -fsSL --connect-timeout 15 --max-time 180 "$DOCKER_INSTALL_URL" -o /tmp/get-docker.sh 2>/dev/null
        if [ -s /tmp/get-docker.sh ]; then
            echo -e "${YELLOW}[注] 即将执行 Docker 官方安装脚本（已落盘 /tmp/get-docker.sh），请确认来源可信。${NC}"
            sh /tmp/get-docker.sh 2>/dev/null || true
        else
            echo -e "${RED}[!] Docker 安装脚本下载失败，请手动安装后重试。${NC}"
        fi
        systemctl enable docker 2>/dev/null || true
        systemctl start docker 2>/dev/null || true
    fi

    if ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
        echo -e "${YELLOW}>>> 未检测到 docker-compose，正在拉取最新版...${NC}"
        curl -L --connect-timeout 15 --max-time 120 "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose 2>/dev/null
        chmod +x /usr/local/bin/docker-compose 2>/dev/null || true
        ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose 2>/dev/null || true
    fi
}

# ----------------------------------------------------
# 初始化穿透式看门狗服务（缺陷4.4：tun 编号改为动态嗅探）
# ----------------------------------------------------
init_uu_monitor() {
    # [防回归 PUSH_DEDUP_V2] 运行时脚本已含新版标记 -> 不覆盖，保护现场修复
    if [ -f "$MONITOR_SCRIPT" ] && grep -qF "PUSH_DEDUP_V2" "$MONITOR_SCRIPT" 2>/dev/null; then
        return 0
    fi
    cat > "$MONITOR_SCRIPT" << 'EOF_MONITOR'
#!/bin/bash
# =============================================================================
#  UU 智能看门狗 —— tun 接口掉线监控 + WxPusher 微信告警
# =============================================================================
#  功能：
#    1) 逐个监控可配置列表中的 tun 接口（默认 tun163 / tun164）
#    2) 在线 -> 离线：立即推送【掉线告警】，标明接口名与发生时间
#    3) 离线 -> 在线：推送【恢复通知】，标明接口名与恢复时间
#    4) 仅在状态【发生变化】时推送一次，绝不重复刷屏
#    5) 取消周期重复提醒：离线/恢复均只在状态转换瞬间推送一条，不持续刷屏
#    6) 运行日志记录到文件，便于排查接口抖动与推送失败
#
#  用法：
#    uu_monitor.sh              # 常驻循环（systemd / rc.local 用）
#    uu_monitor.sh once         # 只检测一轮（验收/调试用）
#    uu_monitor.sh test         # 发送一条测试推送（验证 token/UID 是否正确）
#    uu_monitor.sh status       # 打印当前各接口状态与最近日志
#
#  判定说明（重要）：
#    tun 设备即使正常工作，`ip link show` 也显示 **state UNKNOWN**（无载波），
#    因此【不能】用 "state UP" 判定；本脚本解析尖括号内的标志位 <...UP...>。
#
#  依赖：bash 或 POSIX sh、docker、curl、date、mkdir（宿主侧；脚本在【宿主】运行，
#        通过 docker exec 读取容器内的接口状态）
# =============================================================================

# ---------- 默认参数（均可被 /opt/uuplugin/conf/wxpusher.conf 覆盖）----------
WXPUSHER_CONF="${WXPUSHER_CONF:-/opt/uuplugin/conf/wxpusher.conf}"

CONTAINER="${CONTAINER:-uuplugin}"
WATCH_IFACES="${WATCH_IFACES:-tun163 tun164}"
CHECK_INTERVAL_SEC="${CHECK_INTERVAL_SEC:-10}"

LOG_FILE="${LOG_FILE:-/opt/uuplugin/log/uu_watchdog.log}"
LOG_MAX_KB="${LOG_MAX_KB:-1024}"
STATE_DIR="${STATE_DIR:-/var/run/uu_watchdog}"

PUSH_TIMEOUT_SEC="${PUSH_TIMEOUT_SEC:-10}"
PUSH_RETRY="${PUSH_RETRY:-2}"
DRY_RUN="${DRY_RUN:-0}"

# ---- [WARP 自愈] tun 恢复在线后自动重启 mihomo，清除 WG stale bind ----
# 默认开启；设为 0 可关闭（纯监控不自愈）。
WARP_AUTORESTART_ON_TUNUP="${WARP_AUTORESTART_ON_TUNUP:-1}"
RESTART_DEBOUNCE_SEC="${RESTART_DEBOUNCE_SEC:-60}"      # 两次重启之间最小间隔（秒）
RESTART_MAX_PER_EPISODE="${RESTART_MAX_PER_EPISODE:-5}" # 单回合（一次掉线->恢复）最大重试次数，防重启风暴
RESTART_STAMP="${RESTART_STAMP:-$STATE_DIR/mihomo_restart.stamp}"
RESTART_CNT="${RESTART_CNT:-$STATE_DIR/mihomo_restart.cnt}"

# ---- [智能看门狗 + 熔断] 按 tun 存在性管理 mihomo 生命周期 ----
# 规则（用户硬需求）：
#   所有被监控 tun 均离线 -> 自动关闭 mihomo；
#   任一 tun 在线        -> 保持运行（已运行则不动）/ 立即启动（未运行则拉起）。
# 目的：从根上消除"mihomo 在 tun 不存在时启动并缓存 WG stale bind"的竞态
#      （即"服务器重启后手机一加速 WARP 连不上"的现象）——mihomo 当且仅当
#      至少有一个 tun 在线时才允许运行，boot 期无 tun 即保持关闭。
MH_LIFECYCLE="${MH_LIFECYCLE:-1}"                 # 总开关；0=关闭（退回纯监控 + tun-up 重启）
MH_STOP_GRACE_CYCLES="${MH_STOP_GRACE_CYCLES:-2}" # 连续 N 个周期全部 tun 离线才关 mihomo（防抖，避免瞬时双掉线误杀）
MH_START_DEBOUNCE_SEC="${MH_START_DEBOUNCE_SEC:-5}"   # 两次启动最小间隔（秒）
MH_MAX_STARTS_PER_EPISODE="${MH_MAX_STARTS_PER_EPISODE:-10}" # 单回合（一次掉线->恢复）最大启动次数，防重启风暴
MH_CB_MAX_FAILS="${MH_CB_MAX_FAILS:-5}"           # 连续启动失败达到则熔断（不再盲目重试）
MH_CB_COOLDOWN_SEC="${MH_CB_COOLDOWN_SEC:-120}"   # 熔断冷却时间（秒）
MH_FAIL_FILE="${MH_FAIL_FILE:-$STATE_DIR/mh_fail.cnt}"       # 连续启动失败计数
MH_CB_OPEN="${MH_CB_OPEN:-$STATE_DIR/mh_cb.open_until}"       # 熔断开启截止时间戳(epoch)
MH_ALLDOWN="${MH_ALLDOWN:-$STATE_DIR/mh_alldown.streak}"      # 全部 tun 离线连续周期数
MH_START_STAMP="${MH_START_STAMP:-$STATE_DIR/mh_start.stamp}" # 上次启动时间戳
MH_START_CNT="${MH_START_CNT:-$STATE_DIR/mh_start.cnt}"       # 本回合启动次数
MH_STARTED_FLAG="${MH_STARTED_FLAG:-$STATE_DIR/mh_started.flag}" # 标记"已发起启动、待下一周期校验是否存活"

WXPUSHER_APP_TOKEN=""
WXPUSHER_UID=""

# 加载配置（放在默认值之后，使配置文件优先级最高）
if [ -f "$WXPUSHER_CONF" ]; then
    . "$WXPUSHER_CONF"
fi

# ---------- 日志 ----------
log() {
    _line="$(date '+%Y-%m-%d %H:%M:%S') [uu-dog] $*"
    echo "$_line"
    echo "$_line" >> "$LOG_FILE" 2>/dev/null
}
rotate_log() {
    _max="$LOG_MAX_KB"
    case "$_max" in ''|*[!0-9]*) return 0 ;; esac
    [ "${_max:-0}" -gt 0 ] || return 0
    [ -f "$LOG_FILE" ] || return 0
    _kb=$(du -k "$LOG_FILE" 2>/dev/null | awk '{print $1}')
    case "${_kb:-}" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$_kb" -ge "$_max" ]; then
        mv "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null && : > "$LOG_FILE" 2>/dev/null
    fi
}

now_ts() { date '+%Y-%m-%d %H:%M:%S'; }
epoch()  { date '+%s'; }

# ---------- 状态持久化（跨检测周期；reboot 后 /var/run 清空 -> 重新基线，不会误报）----------
state_file()  { echo "$STATE_DIR/$1.state"; }
down_file()   { echo "$STATE_DIR/$1.downtime"; }
state_get()   { [ -f "$(state_file "$1")" ] && cat "$(state_file "$1")" 2>/dev/null || echo ""; }
state_set()   { echo "$2" > "$(state_file "$1")" 2>/dev/null || true; }

# ---------- 推送 ----------
push_configured() {
    case "$WXPUSHER_APP_TOKEN" in
        ''|AT_xxxx*) return 1 ;;
    esac
    case "$WXPUSHER_UID" in
        ''|UID_xxxx*) return 1 ;;
    esac
    return 0
}

send_wx() {
    _summary="$1"
    _content="$2"

    # DRY_RUN 优先判断：即使尚未配置凭据，也能演练验证逻辑而不打扰微信
    if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN 推送（未真正发送）: $_summary"
        return 0
    fi

    if ! push_configured; then
        log "WARN 未配置有效的 appToken/UID，跳过推送（请在 $WXPUSHER_CONF 中填写）: $_summary"
        return 1
    fi

    _payload=$(printf '{"appToken":"%s","content":"%s","summary":"%s","contentType":1,"uids":["%s"]}' \
        "$WXPUSHER_APP_TOKEN" "$_content" "$_summary" "$WXPUSHER_UID")

    _i=0
    while [ "$_i" -le "$PUSH_RETRY" ]; do
        _resp=$(curl --connect-timeout 5 -m "$PUSH_TIMEOUT_SEC" -s -X POST \
            -H "Content-Type: application/json" \
            -d "$_payload" \
            "https://wxpusher.zjiecode.com/api/send/message" 2>/dev/null)
        if printf '%s' "$_resp" | grep -q '"code":1000'; then
            log "OK   推送成功: $_summary"
            return 0
        fi
        _i=$((_i + 1))
        log "WARN 推送失败（第 $_i 次）: ${_resp:-无响应}"
        [ "$_i" -le "$PUSH_RETRY" ] && sleep 2
    done
    log "FAIL 推送最终失败: $_summary"
    return 1
}

# ---------- 接口在线判定：解析 <...> 标志位中的 UP ----------
# 入参：整份 `ip link show` 快照（避免每个接口一次 docker exec）
iface_is_up() {
    _snap="$1"
    _if="$2"
    _flags=$(printf '%s\n' "$_snap" \
        | grep -oE "^[0-9]+: ${_if}: <[^>]*>" \
        | grep -oE '<[^>]*>' | head -n1)
    [ -z "$_flags" ] && return 1
    case ",${_flags}," in
        *,UP,*) return 0 ;;
        *)      return 1 ;;
    esac
}

# ---------- [WARP 自愈] tun 恢复在线后重启 mihomo（核心修复）----------
# 背景：mihomo 在容器启动 / 加速会话激活前就按 interface-name 把 WG 外层套接字
#       绑定到 tun163/tun164；若当时隧道未就绪，绑定失败并缓存 ENODEV（stale bind），
#       此后即便隧道出现也不自愈 -> 表现为"服务器重启后手机一加速，WARP 长期连不上"。
# 解决办法：在 tun 真正 UP 之后，通过 restart_mihomo.sh 安全重启 mihomo。
#       restart_mihomo.sh 内部 wait_for_tun 会等双隧道就绪再启动，并用 flock 串行化，
#       避免并发销毁 mihomo / mihomo0。
trigger_mihomo_restart() {
    [ "$WARP_AUTORESTART_ON_TUNUP" = "1" ] || return 0
    if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN 触发 mihomo 重启（未真正执行）"
        return 0
    fi
    log "🔧 触发 mihomo 安全重启（清除 WG stale bind，恢复 WARP 出网）"
    # 后台执行，避免阻塞监控主循环（restart_mihomo 会等待对端隧道就绪，可能耗时数十秒）
    ( docker exec "$CONTAINER" sh /etc/scripts/restart_mihomo.sh >> "$LOG_FILE" 2>&1 & )
}

# 去抖 + 单回合限次后，才真正触发重启（被 maybe_restart_mihomo 调用）
_do_maybe_restart() {
    _now=$(epoch)
    _last=$(cat "$RESTART_STAMP" 2>/dev/null)
    case "${_last:-}" in ''|*[!0-9]*) _last=0 ;; esac
    if [ $((_now - _last)) -lt "$RESTART_DEBOUNCE_SEC" ]; then
        return 0   # 仍在去抖窗口内，跳过
    fi
    _cnt=$(cat "$RESTART_CNT" 2>/dev/null)
    case "${_cnt:-}" in ''|*[!0-9]*) _cnt=0 ;; esac
    if [ "$_cnt" -ge "$RESTART_MAX_PER_EPISODE" ]; then
        return 0   # 本回合已达最大重试，避免无限重启风暴（真实故障需人工排查）
    fi
    echo "$_now" > "$RESTART_STAMP" 2>/dev/null || true
    _cnt=$((_cnt + 1))
    echo "$_cnt" > "$RESTART_CNT" 2>/dev/null || true
    trigger_mihomo_restart
}
maybe_restart_mihomo() {
    [ "$WARP_AUTORESTART_ON_TUNUP" = "1" ] || return 0
    _do_maybe_restart
}

# ---------- [智能看门狗] mihomo 生命周期管理（tun 存在性闸门 + 熔断）----------
# 设计要点：
#   - mihomo 仅在"至少一个被监控 tun 在线"时才允许运行；全部离线则关闭（防抖后）。
#   - 启动受去抖 + 单回合限次约束；连续启动失败触发熔断（冷却期内不再盲目拉起）。
#   - 全部离线时清零所有熔断/启动计数（属"有意停机"而非故障）。
mihomo_is_running() {
    docker exec "$CONTAINER" sh -c \
        'for p in /proc/[0-9]*; do [ "$(cat "$p/comm" 2>/dev/null)" = mihomo ] && exit 0; done; exit 1' 2>/dev/null
}
stop_mihomo() {
    [ "$DRY_RUN" = "1" ] && { log "DRY-RUN 关闭 mihomo（未真正执行）"; return 0; }
    log "🔌 关闭 mihomo（所有 tun 离线，按生命周期策略停机）"
    # BusyBox 无 pkill：逐个扫描 /proc/comm 精确 kill -9
    docker exec "$CONTAINER" sh -c \
        'for p in /proc/[0-9]*; do [ "$(cat "$p/comm" 2>/dev/null)" = mihomo ] && kill -9 "$(echo "$p" | cut -d/ -f3)" 2>/dev/null; done' 2>/dev/null
}
tun_up_count() {
    # 注意用 ${1-...}（仅 unset 才回退），而非 ${1:-...}：
    # 调用方（enforce）总是显式传入 $_snap（可能为空串），若为空串应如实判为"无 tun 在线"，
    # 不可因 : 把空串当 unset 而回退去抓取实时接口列表（实时列表里 tun 可能仍 UP，导致误判）。
    _snap="${1-$(docker exec "$CONTAINER" ip link show 2>/dev/null)}"
    _c=0
    for _if in $WATCH_IFACES; do
        iface_is_up "$_snap" "$_if" && _c=$((_c + 1))
    done
    echo "$_c"
}
# 仅在去抖/限次内真正触发一次启动；返回 0=已发起启动，1=被限流跳过
lifecycle_start_mihomo() {
    _now=$(epoch)
    _last=$(cat "$MH_START_STAMP" 2>/dev/null); case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
    if [ $((_now - _last)) -lt "$MH_START_DEBOUNCE_SEC" ]; then return 1; fi
    _cnt=$(cat "$MH_START_CNT" 2>/dev/null); case "$_cnt" in ''|*[!0-9]*) _cnt=0 ;; esac
    if [ "$_cnt" -ge "$MH_MAX_STARTS_PER_EPISODE" ]; then
        log "WARN mihomo 本回合启动次数已达上限($MH_MAX_STARTS_PER_EPISODE)，停止自动启动（请人工排查）"
        return 1
    fi
    echo "$_now" > "$MH_START_STAMP" 2>/dev/null || true
    echo $((_cnt + 1)) > "$MH_START_CNT" 2>/dev/null || true
    trigger_mihomo_restart
    return 0
}
enforce_mihomo_lifecycle() {
    [ "$MH_LIFECYCLE" = "1" ] || return 0
    _snap="${1:-}"
    _up=$(tun_up_count "$_snap")
    _now=$(epoch)

    # ---- 全部 tun 离线：清零熔断计数，并按防抖关掉 mihomo ----
    if [ "$_up" -eq 0 ]; then
        rm -f "$MH_FAIL_FILE" "$MH_CB_OPEN" "$MH_STARTED_FLAG" "$MH_START_STAMP" "$MH_START_CNT" 2>/dev/null || true
        _streak=$(cat "$MH_ALLDOWN" 2>/dev/null); case "$_streak" in ''|*[!0-9]*) _streak=0 ;; esac
        _streak=$((_streak + 1)); echo "$_streak" > "$MH_ALLDOWN" 2>/dev/null || true
        if [ "$_streak" -ge "$MH_STOP_GRACE_CYCLES" ] && mihomo_is_running; then
            stop_mihomo
        fi
        return 0
    fi

    # ---- 至少一个 tun 在线 ----
    rm -f "$MH_ALLDOWN" 2>/dev/null || true

    # 熔断开启中：冷却期内不启动（避免对必败场景反复拉起，给人工排查窗口）
    _open=$(cat "$MH_CB_OPEN" 2>/dev/null); case "$_open" in ''|*[!0-9]*) _open=0 ;; esac
    if [ "$_now" -lt "$_open" ]; then
        log "⚡ mihomo 熔断冷却中（至 $(date -d "@$_open" '+%H:%M:%S' 2>/dev/null || echo "$_open")），暂不启动"
        return 0
    fi

    if mihomo_is_running; then
        if [ -f "$MH_STARTED_FLAG" ]; then
            rm -f "$MH_FAIL_FILE" "$MH_STARTED_FLAG" 2>/dev/null || true
            log "✅ mihomo 启动后持续存活，熔断计数已清零"
        fi
        return 0
    fi

    # mihomo 未运行：先结算上一次启动是否失败（累计熔断计数）
    if [ -f "$MH_STARTED_FLAG" ]; then
        _f=$(cat "$MH_FAIL_FILE" 2>/dev/null); case "$_f" in ''|*[!0-9]*) _f=0 ;; esac
        _f=$((_f + 1)); echo "$_f" > "$MH_FAIL_FILE" 2>/dev/null || true
        rm -f "$MH_STARTED_FLAG" 2>/dev/null || true
        if [ "$_f" -ge "$MH_CB_MAX_FAILS" ]; then
            echo $((_now + MH_CB_COOLDOWN_SEC)) > "$MH_CB_OPEN" 2>/dev/null || true
            log "⚡ mihomo 连续启动失败 ${_f} 次，熔断开启，冷却 ${MH_CB_COOLDOWN_SEC}s（请人工排查 tunnel/配置）"
            return 0
        fi
        log "⚠️ mihomo 启动后未存活（第 ${_f}/${MH_CB_MAX_FAILS} 次失败），将重试"
    fi

    # 立即启动（受去抖 + 单回合限次约束）
    if lifecycle_start_mihomo; then
        echo "$_now" > "$MH_START_STAMP" 2>/dev/null || true
        : > "$MH_STARTED_FLAG" 2>/dev/null || true
        log "🚀 检测到 tun 在线（$_up 个），已触发 mihomo 启动（生命周期联动）"
    fi
    return 0
}

# ---------- 一轮检测 ----------
check_once() {
    rotate_log
    _snap=$(docker exec "$CONTAINER" ip link show 2>/dev/null)
    if [ -z "$_snap" ]; then
        log "WARN 无法读取容器 $CONTAINER 的接口列表（docker exec 失败或容器未运行）"
        return 1
    fi

    for _if in $WATCH_IFACES; do
        if iface_is_up "$_snap" "$_if"; then _now="up"; else _now="down"; fi
        _prev=$(state_get "$_if")

        # 首次运行：只建立基线，不推送（避免重启造成告警风暴）
        if [ -z "$_prev" ]; then
            state_set "$_if" "$_now"
            log "INFO 建立基线: $_if = $_now（首次运行不推送）"
            if [ "$_now" = "down" ]; then
                echo "$(epoch)" > "$(down_file "$_if")" 2>/dev/null
            fi
            continue
        fi

        if [ "$_prev" != "$_now" ]; then
            if [ "$_now" = "down" ]; then
                _t="$(now_ts)"
                echo "$(epoch)" > "$(down_file "$_if")" 2>/dev/null
                # [WARP 自愈] 掉线即结束当前回合，重置重启计数与去抖戳
                rm -f "$RESTART_CNT" "$RESTART_STAMP" 2>/dev/null
                log "🔴 $_if 由在线变为离线（$_t）"
                send_wx "🔴 [掉线] $_if 已离线" \
                    "🔴 UU 加速接口掉线告警\n\n- 接口：$_if\n- 状态：离线（由在线变为离线）\n- 发生时间：$_t\n- 主机：$(hostname)\n- 动作：请检查 UU App 加速会话是否仍开启"
            else
                _t="$(now_ts)"
                _dur=""
                if [ -f "$(down_file "$_if")" ]; then
                    _ds=$(cat "$(down_file "$_if")" 2>/dev/null)
                    case "$_ds" in ''|*[!0-9]*) ;; *) _dur="持续离线 $(( $(epoch) - _ds )) 秒" ;; esac
                fi
                rm -f "$(down_file "$_if")" 2>/dev/null
                log "🟢 $_if 恢复在线（$_t）"
                send_wx "🟢 [恢复] $_if 已恢复" \
                    "🟢 UU 加速接口恢复通知\n\n- 接口：$_if\n- 状态：已恢复在线\n- 恢复时间：$_t\n- 主机：$(hostname)\n- 备注：${_dur:-离线时长未知}"
                # [WARP 自愈] 隧道恢复在线 -> 重启 mihomo 清除 stale bind（核心修复触发点）
                maybe_restart_mihomo
            fi
            state_set "$_if" "$_now"
        fi
    done

    # ---- [WARP 自愈] 周期自省：tun 在线但 WARP 探测失败则补触发重启 ----
    # 覆盖"首次 tun-up 触发恰好被 proxy_manager 持锁占用而未能执行"的竞态，
    # 以及"stale bind 未被一次重启清除"的边缘情况。受去抖 + 单回合限次约束，不会风暴。
    _any_up=0
    for _if in $WATCH_IFACES; do
        [ "$(state_get "$_if")" = "up" ] && _any_up=1
    done
    if [ "$_any_up" = "1" ] && [ "$WARP_AUTORESTART_ON_TUNUP" = "1" ]; then
        _w=$(docker exec "$CONTAINER" wget -q -O- 'http://127.0.0.1:9090/proxies/WARP163/delay?url=http://cp.cloudflare.com&timeout=8000' 2>/dev/null)
        if [ -z "$_w" ]; then
            maybe_restart_mihomo
        fi
    fi

    # ---- [智能看门狗] 每轮强制校核 mihomo 生命周期：
    #   全部 tun 离线 -> 关 mihomo；任一 tun 在线且 mihomo 未运行 -> 立即启动（带熔断）----
    enforce_mihomo_lifecycle "$_snap"

    return 0
}

# ---------- 启动 ----------
mkdir -p "$STATE_DIR" 2>/dev/null
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null

case "${1:-daemon}" in
    once)
        log "执行单轮检测（once）"
        check_once
        ;;
    test)
        if ! push_configured; then
            log "FAIL 未配置有效的 appToken/UID，无法测试推送。请在 $WXPUSHER_CONF 中填写后重试。"
            exit 1
        fi
        log "发送测试推送..."
        send_wx "✅ [测试] UU 看门狗" \
            "✅ UU 智能看门狗测试消息\n\n- 时间：$(now_ts)\n- 主机：$(hostname)\n- 监控接口：$WATCH_IFACES\n- 检测间隔：${CHECK_INTERVAL_SEC}s"
        ;;
    status)
        echo "=== UU 智能看门狗状态 ==="
        echo "容器: $CONTAINER    监控接口: $WATCH_IFACES    间隔: ${CHECK_INTERVAL_SEC}s"
        echo "推送策略: 状态转换仅推送一次（无周期重复提醒）    DRY_RUN: $DRY_RUN"
        echo "--- 当前状态 ---"
        for _if in $WATCH_IFACES; do
            _s=$(state_get "$_if")
            echo "  $_if = ${_s:-未记录}"
        done
        echo "--- 最近日志 ---"
        tail -n 15 "$LOG_FILE" 2>/dev/null
        ;;
    daemon|*)
        log "==== UU 智能看门狗启动 pid=$$ 容器=$CONTAINER 接口=[$WATCH_IFACES] 间隔=${CHECK_INTERVAL_SEC}s 推送策略=状态转换仅一次 ===="
        if ! push_configured; then
            log "WARN 检测到 WxPusher 未配置（appToken/UID 仍为占位或缺失），将只记录日志不推送。请编辑 $WXPUSHER_CONF"
        fi
        while true; do
            check_once
            sleep "$CHECK_INTERVAL_SEC"
        done
        ;;
esac
exit 0
EOF_MONITOR
    chmod +x "$MONITOR_SCRIPT"

    # [新增] 部署 WxPusher 配置模板（占位符需用户替换；已存在则不覆盖，避免冲掉真实凭据）
    mkdir -p "$BASE_DIR/conf" "$BASE_DIR/log" 2>/dev/null || true
    if [ ! -f "$BASE_DIR/conf/wxpusher.conf" ]; then
        cat > "$BASE_DIR/conf/wxpusher.conf" << 'EOF_WXPUSHER'
# =============================================================================
#  WxPusher 微信推送 + UU 接口监控 配置
#  本文件由 /opt/uuplugin/scripts/uu_monitor.sh 以 "." 方式加载（需合法 sh 语法）
# =============================================================================

# ---------------------------------------------------------------------------
#  【必填-需替换】WxPusher 凭据
#    获取方式：微信关注「WxPusher」公众号 -> 后台创建应用 -> 拿到 appToken；
#              在「用户」/「粉丝」列表里拿到自己的 UID（形如 UID_xxxx）。
#    ⚠️ 下面两行的 AT_xxxx… / UID_xxxx… 是【占位符】，未替换时脚本只记日志不推送。
# ---------------------------------------------------------------------------
WXPUSHER_APP_TOKEN="AT_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"   # <<<【需替换】改成你的 appToken
WXPUSHER_UID="UID_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"        # <<<【需替换】改成你的 UID

# ---------------------------------------------------------------------------
#  【可选】监控参数（均有默认值，按需调整）
# ---------------------------------------------------------------------------
# 被监控的容器名（tun 接口存在于该容器内）
CONTAINER="uuplugin"

# 需要监控的接口列表，空格分隔。默认 tun163 tun164
WATCH_IFACES="tun163 tun164"

# 检测间隔（秒）。越小发现越快，docker exec 开销越大
CHECK_INTERVAL_SEC=10

# 持续离线期间的周期提醒间隔（秒）。
#   0      = 关闭（只在状态变化时推送，最省消息）
#   1800   = 每 30 分钟提醒一次（默认）
OFFLINE_REMIND_INTERVAL_SEC=1800

# 推送超时（秒）与失败重试次数
PUSH_TIMEOUT_SEC=10
PUSH_RETRY=2

# 演练模式：1 = 只写日志不真正推送（用来验证逻辑而不打扰微信）；0 = 正常推送
DRY_RUN=0

# 运行日志（排查接口抖动 / 推送失败用）
LOG_FILE=/opt/uuplugin/log/uu_watchdog.log
LOG_MAX_KB=1024

# 状态文件目录（/var/run 为 tmpfs，重启后清空 -> 重新建立基线，不会误报）
STATE_DIR=/var/run/uu_watchdog
EOF_WXPUSHER
        chmod 644 "$BASE_DIR/conf/wxpusher.conf" 2>/dev/null || true
        echo "[uu-monitor] 已生成 WxPusher 配置模板: $BASE_DIR/conf/wxpusher.conf（需填写 appToken/UID 后才会推送）"
    else
        echo "[uu-monitor] 已存在 $BASE_DIR/conf/wxpusher.conf，保持不动"
    fi

    cat > /etc/systemd/system/uu-monitor.service << EOF_SVC
[Unit]
Description=UU Container Watchdog & WxPusher
After=docker.service
[Service]
Type=simple
ExecStart=/bin/bash $MONITOR_SCRIPT
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF_SVC
    systemctl daemon-reload 2>/dev/null
    systemctl enable uu-monitor >/dev/null 2>&1
    systemctl start uu-monitor >/dev/null 2>&1
}
init_uu_monitor

# ----------------------------------------------------
# 配置系统日志轮询
# ----------------------------------------------------
setup_log_rotation() {
    local keep_days=$1
    echo -e "\n${BLUE}>>> 正在配置系统日志与文件日志轮询 (保留 ${keep_days} 天)...${NC}"
    cat > /etc/logrotate.d/uu_logs << EOF_LOGROTATE
$BASE_DIR/log/*.log $BASE_DIR/conf/*.log {
    daily
    rotate $keep_days
    missingok
    notifempty
    copytruncate
    compress
    delaycompress
}
EOF_LOGROTATE
    cat > /etc/cron.daily/uu_journal_vacuum << EOF_CRON
#!/bin/bash
journalctl --vacuum-time=${keep_days}d > /dev/null 2>&1
EOF_CRON
    chmod +x /etc/cron.daily/uu_journal_vacuum
    systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || true
    journalctl --vacuum-time=${keep_days}d > /dev/null 2>&1
    echo -e "${GREEN}[OK] 日志清理策略已更新为保留 ${keep_days} 天！${NC}"
    pause_enter
}

# ----------------------------------------------------
# 容器内端口转发引擎（已是「先删后加」幂等范式，保留作为样板）
# ----------------------------------------------------
init_proxy_manager() {
    # [fix] 已是 TUN 捕获模式引擎(含 mihomo0 捕获设备)则不再覆盖，保留现场修复，
    # 避免每次 init_proxy_manager 把改好的引擎冲回内置旧版（旧版会把转发目标裸路由进 tun163 导致不通）。
    if grep -q 'CAP_DEV="mihomo0"' "$PROXY_SCRIPT" 2>/dev/null; then
        return 0
    fi
    cat > "$PROXY_SCRIPT" << 'EOF_PROXY'
#!/bin/sh
# UU + mihomo(WARP) 端口转发引擎（TUN 捕获模式）
# 设计要点（满足用户两条硬约束）：
#   1) mihomo 的 WARP / 功能3 端口转发的出网 必须走 tun163/tun164（WG 设备）。
#   2) 只有功能3 转发规则里的「目标 IP」才被路由进 mihomo 的 TUN 捕获设备(mihomo0)，
#      经由 WARP163/164 的 tun163/tun164 出网；其余未设定转发规则的流量默认直连(br-lan)，不走 tun。
#
# 数据流：客户端 -> 192.168.6.248:LPORT  ->  PREROUTING/DNAT 改写到 目标IP:RPORT
#        -> 主表路由把 目标IP/32 送进 mihomo0(捕获) -> mihomo 按规则集选 WARP163/164
#        -> WARP163/164 经其 WG 设备 tun163/tun164 出网(源变 WARP IP，游戏服认)
#        -> 回包由 mihomo 有状态接管，经 mihomo0 正确送回客户端。

ACTION=$1
RULES_DB="/etc/uu_conf/forward_rules.conf"
MIHOMO_RULES_DIR="/etc/mihomo/rules"
MIHOMO_BIN="/etc/mihomo/mihomo"
CAP_DEV="mihomo0"          # mihomo TUN 捕获设备（与出网 WG 设备 tun163/164 分离）

if [ ! -f "$RULES_DB" ]; then exit 0; fi

# 入站 LAN 网卡：客户端在此连接「本地监听端口」。tun163/164 只负责出网，绝不当入站接口。
DETECT_LAN_IF() {
    if ip link show br-lan >/dev/null 2>&1; then echo "br-lan"; return; fi
    _d=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ -n "$_d" ] && { echo "$_d"; return; }
    ip -o link show up 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}'
}

# 确保 mihomo(TUN 捕获)已就绪，且全局唯一（绝不允许多实例争抢 tun163/164、mihomo0）。
# 使用 ( ... & ) 让 mihomo 脱离当前 shell 存活（docker exec 会话结束也不被杀）。
ensure_mihomo() {
    _force="$1"
    _n=$(ps w 2>/dev/null | grep "$MIHOMO_BIN" | grep -v grep | wc -l)
    # 非强制 且 已单实例 + 捕获设备在线 -> 直接复用，避免无谓重启
    if [ "$_force" != "force" ] && [ "$_n" -eq 1 ] && ip link show "$CAP_DEV" >/dev/null 2>&1; then
        return 0
    fi
    # 强制重载 / 多实例 / 捕获设备未就绪 -> 清掉全部残留，启动唯一实例
    for p in $(ps w 2>/dev/null | grep "$MIHOMO_BIN" | grep -v grep | awk '{print $1}'); do
        kill -9 "$p" 2>/dev/null
    done
    # [fix] 必须等旧进程与旧捕获设备【彻底消失】再启动：
    # 否则就绪判定会拿"即将被销毁的旧 mihomo0"当成功，随后下发的 /32 路由随旧设备一起丢失。
    i=0
    while [ $i -lt 15 ]; do
        ps w 2>/dev/null | grep -q "[/]etc/mihomo/mihomo" || break
        sleep 1; i=$((i+1))
    done
    i=0
    while [ $i -lt 15 ]; do
        ip link show "$CAP_DEV" >/dev/null 2>&1 || break
        sleep 1; i=$((i+1))
    done
    ( "$MIHOMO_BIN" -d /etc/mihomo >>"${MIHOMO_LOG:-/etc/uu_conf/mihomo.log}" 2>&1 & )
    i=0
    while [ $i -lt 30 ]; do
        [ "$(ps w 2>/dev/null | grep "$MIHOMO_BIN" | grep -v grep | wc -l)" -eq 1 ] && \
            ip link show "$CAP_DEV" >/dev/null 2>&1 && return 0
        sleep 1; i=$((i+1))
    done
    return 1
}

# 把转发目标 RIP 路由进 mihomo 的 TUN 捕获设备（mihomo 据此有状态代理出网）。
add_route_network_aware() {
    _rip="$1"
    _cap="$2"
    ip link show "$_cap" >/dev/null 2>&1 || return 0   # 捕获设备未起则跳过，待 ensure_mihomo 后补
    if echo "$(ip route get "$_rip" 2>/dev/null | head -n1)" | grep -q "dev $_cap"; then
        return 0
    fi
    ip route replace "$_rip" dev "$_cap" metric 1 2>/dev/null && return 0
    return 1
}

case $ACTION in
    reload)
        # 清理旧的转发路由（仅清理我们下发到捕获设备的 /32）
        ip route show dev "$CAP_DEV" 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | while read -r rip; do
            ip route del "$rip" dev "$CAP_DEV" 2>/dev/null || true
        done

        # 入站 DNAT 链
        iptables -t nat -N UU_PORT_FWD 2>/dev/null || iptables -t nat -F UU_PORT_FWD
        iptables -t nat -D PREROUTING -j UU_PORT_FWD 2>/dev/null
        iptables -t nat -I PREROUTING 1 -j UU_PORT_FWD

        LAN_IF=$(DETECT_LAN_IF)
        [ -z "$LAN_IF" ] && LAN_IF="br-lan"

        count=0
        TMP_HOSTS=$(mktemp)
        RIPS_LIST=""

        if [ -s "$RULES_DB" ]; then
            while read -r line; do
                case "$line" in \#*) continue ;; "") continue ;; esac
                THOST=$(echo "$line" | cut -d':' -f1)
                LPORT=$(echo "$line" | cut -d':' -f2)
                RPORT=$(echo "$line" | cut -d':' -f3)
                TUN_IFACE=$(echo "$line" | cut -d':' -f4)
                RPORT=${RPORT:-$LPORT}
                [ -z "$TUN_IFACE" ] && TUN_IFACE="tun163"

                echo "$THOST" >> "$TMP_HOSTS"

                if echo "$THOST" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
                    RIP="$THOST"
                else
                    RIP=$(nslookup "$THOST" 119.29.29.29 2>/dev/null | awk '/^Address [0-9]+: /{print $3}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
                    [ -z "$RIP" ] && RIP=$(ping -c 1 -W 2 "$THOST" 2>/dev/null | grep PING | awk -F'[()]' '{print $2}')
                fi

                if [ -n "$RIP" ]; then
                    # 入站 DNAT：捕获从 LAN 网卡进入、目的端口为 LPORT 的流量，改写到 RIP:RPORT
                    iptables -t nat -A UU_PORT_FWD -i "$LAN_IF" -p tcp --dport "$LPORT" -j DNAT --to-destination "$RIP:$RPORT"
                    iptables -t nat -A UU_PORT_FWD -i "$LAN_IF" -p udp --dport "$LPORT" -j DNAT --to-destination "$RIP:$RPORT"

                    RIPS_LIST="$RIPS_LIST $RIP"

                    count=$((count + 1))
                fi
            done < "$RULES_DB"
        fi

        rm -f "$TMP_HOSTS"

        # 同步 mihomo 规则 YAML（结构校验 + 备份 + 原子写入）；失败则中止本次 reload
        /bin/sh /etc/scripts/sync_mihomo_rules.sh || {
            echo "⚠️ 规则 YAML 同步校验失败，终止本次 reload（线上文件未改动）" >&2
            exit 1
        }

        # 强制重载 mihomo（加载新 provider），保证单实例 + 捕获设备在线
        ensure_mihomo force || {
            echo "⚠️ mihomo 未就绪，回滚规则 YAML 并重载" >&2
            for _f in fwd_warp163.yaml fwd_warp164.yaml; do
                _b=$(ls -t "$MIHOMO_RULES_DIR/$_f.bak."* 2>/dev/null | head -n1)
                [ -n "$_b" ] && mv "$_b" "$MIHOMO_RULES_DIR/$_f"
            done
            ensure_mihomo force
        }

        # 下发目标捕获路由（仅转发目标进 mihomo0 -> WARP -> tun163/164）
        for RIP in $RIPS_LIST; do
            add_route_network_aware "$RIP" "$CAP_DEV" || \
                echo "⚠️ 无法为 $RIP 建立捕获路由，转发可能失败" >&2
        done

        echo "✅ 容器内端口转发引擎重载完成！共解析生效 ${count} 条策略（捕获设备 ${CAP_DEV}）。"
        ;;

    list)
        if grep -vE "^#|^$" "$RULES_DB" >/dev/null 2>&1; then
            echo "--- 当前已保存并生效的转发规则 ---"
            while read -r line; do
                case "$line" in \#*) continue ;; "") continue ;; esac
                THOST=$(echo "$line" | cut -d':' -f1)
                LPORT=$(echo "$line" | cut -d':' -f2)
                RPORT=$(echo "$line" | cut -d':' -f3)
                TUN_IFACE=$(echo "$line" | cut -d':' -f4)
                RPORT=${RPORT:-$LPORT}
                if echo "$THOST" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
                    RIP="$THOST"
                else
                    RIP=$(nslookup "$THOST" 119.29.29.29 2>/dev/null | awk '/^Address [0-9]+: /{print $3}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
                fi
                printf " ▶ 监听: %s -> 目标: %s (解析IP: %s:%s) (网卡强绑: %s)\n" "$LPORT" "$THOST" "${RIP:-解析失败}" "$RPORT" "${TUN_IFACE:-自动}"
            done < "$RULES_DB"
        else
            echo "暂无任何端口转发规则。"
        fi
        ;;
esac
EOF_PROXY
    chmod +x "$PROXY_SCRIPT"
    if [ ! -f "$RULES_DB" ]; then echo "# 格式: 目标IP或域名:本地监听端口:目标端口:绑定的网卡(可选)" > "$RULES_DB"; fi
}
init_proxy_manager

# ----------------------------------------------------
# 1. UU 加速核心管理模块
# ----------------------------------------------------
menu_uu() {
    while true; do
        clear
        local uu_state="${RED}[已停止/未安装]${NC}"
        if command -v docker >/dev/null 2>&1; then
            if docker ps | grep -q uuplugin; then uu_state="${GREEN}[运行中]${NC}"; fi
        fi

        echo -e "${BLUE}===============================================${NC}"
        echo -e "${YELLOW}           --- 1. UU 加速核心管理 ---          ${NC}"
        echo -e "${BLUE}===============================================${NC}"
        echo -e "  当前状态: $uu_state"
        echo -e "-----------------------------------------------"
        echo -e "  ${YELLOW}1)${NC} [+] 安装/更新/修复 UU 核心程序 (含一键部署)"
        echo -e "  ${GREEN}2)${NC} [*] 重启 UU 核心服务 (Restart)"
        echo -e "  ${RED}3)${NC} [*] 停止 UU 核心服务 (Stop)"
        echo -e "  ${CYAN}4)${NC} [*] 查看 运行配置文件 (docker-compose.yaml)"
        echo -e "  ${NC}0) 返回主菜单"
        echo -e "${BLUE}===============================================${NC}"
        read -p "请输入选项: " opt
        case $opt in
            1)
                check_and_install_env

                echo -e "\n${CYAN}>>> [2/7] 开始自动探测主机环境与双栈网络特征 <<<${NC}"
                IFACE=$(ip -4 route | awk '/default/ {print $5}' | head -n 1)
                if [ -z "$IFACE" ]; then log "错误：无法检测到默认活动网卡！"; pause_enter; return; fi
                log "    ✓ 识别到物理网卡: \033[36m$IFACE\033[0m"

                MAC=$(printf '02:%02x:%02x:%02x:%02x:%02x\n' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
                PS4_MAC=$(printf 'f8:46:1c:%02x:%02x:%02x\n' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
                PS5_MAC=$(printf 'f8:46:1c:%02x:%02x:%02x\n' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))

                GATEWAY=$(ip -4 route | awk '/default/ {print $3}' | head -n 1)
                IP_PREFIX=$(echo "$GATEWAY" | cut -d. -f1-3)
                GATEWAY_PREFIX_2=$(echo "$GATEWAY" | cut -d. -f1-2)

                SUBNET=$(ip -4 route show dev "$IFACE" | grep -v default | grep "^$GATEWAY_PREFIX_2" | awk '{print $1}' | head -n 1)
                [ -z "$SUBNET" ] && SUBNET="${IP_PREFIX}.0/24"

                CIDR_SUFFIX=$(echo "$SUBNET" | cut -d/ -f2)
                NETMASK=$(awk -v cidr="$CIDR_SUFFIX" 'BEGIN { mask=""; for(i=0; i<4; i++) { if(cidr >= 8) { mask = mask "255."; cidr -= 8; } else if(cidr > 0) { mask = mask (256 - 2^(8-cidr)) "."; cidr = 0; } else { mask = mask "0."; } } sub(/\.$/, "", mask); print mask; }')
                NETMASK=${NETMASK:-255.255.255.0}

                log "    ✓ 识别到 IPv4 网关: \033[36m$GATEWAY\033[0m"
                log "    ✓ 识别到 IPv4 网段: \033[36m$SUBNET\033[0m"
                log "    ✓ 识别到子网掩码: \033[36m$NETMASK\033[0m"

                log "    正在扫描未被占用的 IP 空位 (基于 $IP_PREFIX.x)..."

                IP=$(find_unused_ip 250)
                [ -z "$IP" ] && { log "错误: 找不到可分配的 UU IP"; pause_enter; return; }
                log "    ✓ 自动分配 UU IP:  \033[33m$IP\033[0m"

                IP_LAST=$(echo "$IP" | awk -F. '{print $4}')
                PS4_START=$((IP_LAST - 1))

                PS4_IP=$(find_unused_ip "$PS4_START")
                [ -z "$PS4_IP" ] && { log "错误: 找不到可分配的 PS4 IP"; pause_enter; return; }
                log "    ✓ 自动分配 PS4 IP: \033[33m$PS4_IP\033[0m"

                PS4_LAST=$(echo "$PS4_IP" | awk -F. '{print $4}')
                PS5_START=$((PS4_LAST - 1))

                PS5_IP=$(find_unused_ip "$PS5_START")
                [ -z "$PS5_IP" ] && { log "错误: 找不到可分配的 PS5 IP"; pause_enter; return; }
                log "    ✓ 自动分配 PS5 IP: \033[33m$PS5_IP\033[0m"

                echo -e "\n${CYAN}>>> [3/7] 正在配置网卡混杂模式及开机自启...${NC}"
                ip link set "$IFACE" promisc on || true
                cat << EOF > /etc/systemd/system/${IFACE}-promisc.service
[Unit]
Description=Set ${IFACE} to promiscuous mode
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/bin/ip link set ${IFACE} promisc on
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload || true
                systemctl enable "${IFACE}-promisc.service" || true
                # 阶段二(缺陷4.3)：路由幂等——使用 replace 避免重复堆叠
                ip route replace "$SUBNET" dev "$IFACE" 2>/dev/null || true

                # 宿主机 NAT（已先删后加，保持幂等）
                iptables -t nat -D POSTROUTING -s "$IP" -o "$IFACE" -j MASQUERADE 2>/dev/null || true
                iptables -t nat -A POSTROUTING -s "$IP" -o "$IFACE" -j MASQUERADE 2>/dev/null || true

                # 阶段二(缺陷4.3)：macvlan0 宿主机互通——存在则复用，路由用 replace 幂等
                MACVLAN_IP="${IP_PREFIX}.251"
                ip link show macvlan0 >/dev/null 2>&1 || ip link add macvlan0 link "$IFACE" type macvlan mode bridge 2>/dev/null || true
                ip addr show dev macvlan0 2>/dev/null | grep -q "$MACVLAN_IP" || ip addr add "$MACVLAN_IP/24" dev macvlan0 2>/dev/null || true
                ip link set macvlan0 up 2>/dev/null || true
                ip route replace "$IP/32" dev macvlan0 2>/dev/null || true

                echo -e "\n${CYAN}>>> [4/7] 正在创建持久化目录与提取系统原版大脑...${NC}"
                mkdir -p "$BASE_DIR/config" "$BASE_DIR/core"

                echo -e "    正在拉取 ${UU_IMAGE}:${UU_IMAGE_TAG} 官方镜像..."
                docker pull "${UU_IMAGE}:${UU_IMAGE_TAG}" || true

                docker rm -f uu_tmp_extract 2>/dev/null || true
                docker run -d --name uu_tmp_extract "${UU_IMAGE}:${UU_IMAGE_TAG}" /sbin/init >/dev/null 2>&1
                echo "    等待容器内核生成网络配置 (5秒)..."
                sleep 5
                docker cp uu_tmp_extract:/etc/config/. "$BASE_DIR/config/" 2>/dev/null || true
                docker rm -f uu_tmp_extract 2>/dev/null || true

                if [ -z "$(ls -A "$BASE_DIR/config" 2>/dev/null)" ]; then
                    log "    ! 警告: 提取 config 为空，uuplugin 可能缺配置"
                else
                    log "    ✓ 网络配置文件提取成功！"
                fi

                echo -e "\n${CYAN}>>> [5/7] 正在写入网络内核优化与正确的 NAT 穿透规则...${NC}"
                # 阶段二(缺陷4.1)：rc.local 内防火墙规则改为「先检后插」幂等范式（容器每次启动不再堆叠）
                cat << 'EOF' > "$BASE_DIR/rc.local"
#!/bin/sh
sleep 3

sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1
sysctl -w net.ipv6.conf.default.forwarding=1

sysctl -w net.ipv4.tcp_tw_reuse=1
sysctl -w net.ipv4.tcp_fin_timeout=15
sysctl -w net.ipv4.tcp_synack_retries=2
sysctl -w net.ipv4.tcp_keepalive_time=600

sysctl -w net.core.rmem_max=2500000 2>/dev/null || true
sysctl -w net.core.wmem_max=2500000 2>/dev/null || true
sysctl -w net.ipv4.udp_rmem_min=8192 2>/dev/null || true
sysctl -w net.ipv4.udp_wmem_min=8192 2>/dev/null || true

sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=3600 2>/dev/null || true
sysctl -w net.netfilter.nf_conntrack_udp_timeout=60 2>/dev/null || true
sysctl -w net.netfilter.nf_conntrack_udp_timeout_stream=120 2>/dev/null || true

# 自动识别 OpenWrt 容器内的实际网卡名称（br-lan 或 eth0），兼容不同版本镜像
LAN_IFACE="br-lan"
ip link show br-lan >/dev/null 2>&1 || LAN_IFACE="eth0"

# 阶段二(缺陷4.1)：幂等写入——先用 -C 检查存在，不存在才插；容器反复重启不再堆叠
iptables -C FORWARD -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -j ACCEPT
iptables -t nat -C POSTROUTING -o "$LAN_IFACE" -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -o "$LAN_IFACE" -j MASQUERADE
[ "$LAN_IFACE" = "br-lan" ] && { iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -o eth0 -j MASQUERADE; }
[ "$LAN_IFACE" = "eth0" ] && { iptables -t nat -C POSTROUTING -o br-lan -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -o br-lan -j MASQUERADE; }

# 启动 UU 守护
if [ -x /usr/sbin/uu/uuplugin_monitor.sh ]; then
    /bin/sh /usr/sbin/uu/uuplugin_monitor.sh &
fi

# 启动 Mihomo
if [ -x /etc/mihomo/mihomo ] && [ -f /etc/mihomo/config.yaml ]; then
    # [WARP 修复] 经 restart_mihomo.sh 启动：内含 wait_for_tun(等 tun163/tun164 就绪)
    # 与 flock 并发锁。若直接启动，mihomo 按 interface-name 把 WG 外层套接字绑到尚不存在的
    # tun 会失败并缓存 ENODEV(stale bind)，此后即便隧道出现也不自愈 -> WARP 长期 alive:false。
    # TUN_WAIT_STRICT=1：隧道始终未就绪则放弃启动，交由宿主看门狗在 tun 上线时拉起。
    # 后台执行，避免阻塞后续防火墙与端口转发规则加载。
    if [ -x /etc/scripts/restart_mihomo.sh ]; then
        TUN_WAIT_STRICT=1 /bin/sh /etc/scripts/restart_mihomo.sh >> /etc/uu_conf/mihomo.log 2>&1 &
    else
        /etc/mihomo/mihomo -d /etc/mihomo > /etc/uu_conf/mihomo.log 2>&1 &
    fi
    sleep 3
    for tun in $(ip link show 2>/dev/null | grep -oE 'tun[0-9]+' | sort -u); do
        num=$(echo "$tun" | grep -oE '[0-9]+')
        ip route add default dev "$tun" table "$num" 2>/dev/null || true
        tun_ip=$(ip -4 addr show "$tun" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
        [ -n "$tun_ip" ] && ip rule add from "$tun_ip" table "$num" 2>/dev/null || true
    done
fi

# 修复 OpenWrt 防火墙：将默认转发策略从 REJECT 改为 ACCEPT
if [ -f /etc/config/firewall ]; then
    sed -i 's/option forward.*REJECT/option forward ACCEPT/' /etc/config/firewall 2>/dev/null || true
    /etc/init.d/firewall restart 2>/dev/null || true
fi
# 禁用 DHCP 服务，避免与主路由冲突
/etc/init.d/dnsmasq stop 2>/dev/null || true
/etc/init.d/odhcpd stop 2>/dev/null || true
# 阶段二(缺陷4.1)：防火墙重启后再次幂等补插 FORWARD ACCEPT
iptables -C FORWARD -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -j ACCEPT

# [修复] 加载端口转发必须放在「防火墙重启之后」：
# /etc/init.d/firewall restart 会整体清空 nat 表（含 UU_PORT_FWD 链及其 PREROUTING 跳转），
# 且该链不在 fw3 配置中不会被重建。原顺序为「先装规则、后重启防火墙」，
# 导致规则刚写入即被清空 —— 表现为「重启虚拟机/UU 后转发规则不生效，必须手动按 5 重载」。
# 实测：firewall restart 后 PREROUTING->UU_PORT_FWD 跳数 1 -> 0。
if [ -x /etc/scripts/proxy_manager.sh ]; then
    /bin/sh /etc/scripts/proxy_manager.sh reload > /dev/null 2>&1
fi

# [WARP 修复] macvlan 网络下 Docker 内嵌 DNS(127.0.0.11) 不可达，容器内依赖系统 resolver
# 的工具会全部超时（实测 connection timed out）。改用公共 DNS，幂等写入。
# 注意：本段必须与主流程 EOF_RCLOCAL_V7 模板保持一致，否则 manager.sh 重新初始化时
# 会用本模板覆盖 $BASE_DIR/rc.local，导致 DNS 修复丢失。
if ! grep -q "^nameserver 119.29.29.29" /etc/resolv.conf 2>/dev/null; then
    printf "nameserver 119.29.29.29\nnameserver 223.5.5.5\noptions timeout:3 attempts:3\n" > /etc/resolv.conf
fi

exit 0
EOF
                chmod +x "$BASE_DIR/rc.local"

                echo -e "\n${CYAN}>>> [6/7] 正在启动旁路由与模拟设备容器组...${NC}"
                # 阶段二(缺陷4.9)：生成 docker-compose.yaml 前，强制校验所有动态变量非空，避免静默空展开
                for _v in IFACE GATEWAY SUBNET NETMASK IP PS4_IP PS5_IP MAC PS4_MAC PS5_MAC; do
                    if [ -z "${!_v}" ]; then
                        log "致命: 环境探测变量 $_v 为空，中止生成 docker-compose.yaml"
                        pause_enter; return 1
                    fi
                done
                cat << EOF > "$BASE_DIR/docker-compose.yaml"
version: '3.8'
services:
  uuplugin:
    image: ${UU_IMAGE}:${UU_IMAGE_TAG}
    container_name: uuplugin
    restart: always
    privileged: true
    mac_address: "$MAC"
    environment:
      - UU_LAN_IPADDR=$IP
      - UU_LAN_GATEWAY=$GATEWAY
      - UU_LAN_NETMASK=$NETMASK
    volumes:
      - ./config:/etc/config
      - ./core:/usr/sbin/uu
      - ./rc.local:/etc/rc.local
      - ./mihomo:/etc/mihomo
      - ./conf:/etc/uu_conf
      - ./scripts:/etc/scripts
    networks:
      macnet:
        ipv4_address: $IP

  ps4_sim_1:
    image: ${UUPS_IMAGE}:${UUPS_IMAGE_TAG}
    container_name: PS4
    restart: always
    mac_address: "$PS4_MAC"
    networks:
      macnet:
        ipv4_address: $PS4_IP

  ps5_sim_2:
    image: ${UUPS_IMAGE}:${UUPS_IMAGE_TAG}
    container_name: PS5
    restart: always
    mac_address: "$PS5_MAC"
    networks:
      macnet:
        ipv4_address: $PS5_IP

networks:
  macnet:
    driver: macvlan
    driver_opts:
      parent: $IFACE
    ipam:
      config:
        - subnet: $SUBNET
          gateway: $GATEWAY
EOF

                cd "$BASE_DIR"
                dkcompose down 2>/dev/null || true
                docker network rm uuplugin_macnet 2>/dev/null || true
                dkcompose up -d

                echo -e "\n${CYAN}>>> [7/7] 正在等待容器就绪并强注网易 UU 官方核心...${NC}"
                for i in $(seq 1 15); do
                    if docker exec uuplugin sh -c 'ip link show br-lan >/dev/null 2>&1' 2>/dev/null; then
                        log "    ✓ 容器网络已就绪 (等待 ${i}s)"
                        break
                    fi
                    sleep 2
                done

                # 阶段二(缺陷4.6)：UU 核心注入——先落盘并校验非空，显式提示远程脚本执行风险
                UU_CORE_INSTALL_URL="${UU_CORE_INSTALL_URL:-https://raw.githubusercontent.com/WilsonBryanz/normal_shell/refs/heads/main/network/uuplugin/install.sh}"
                if ! mirror_curl "$UU_CORE_INSTALL_URL" /tmp/uu_install.sh; then
                    curl -fsSL --connect-timeout 15 --max-time 120 "https://fastly.jsdelivr.net/gh/WilsonBryanz/normal_shell@main/network/uuplugin/install.sh" -o /tmp/uu_install.sh 2>/dev/null || true
                fi

                INJECT_OK=false
                if [ -s /tmp/uu_install.sh ]; then
                    echo -e "${YELLOW}[注] 即将在容器内执行远程核心安装脚本（已落盘 /tmp/uu_install.sh），请确认来源可信。${NC}"
                    for attempt in 1 2; do
                        if docker exec -i uuplugin sh -s openwrt x86_64 < /tmp/uu_install.sh >/dev/null 2>&1; then
                            log "    ✓ UU 核心注入完成 (第${attempt}次)"
                            INJECT_OK=true
                            break
                        fi
                        log "    ! 第${attempt}次注入失败，等待重试..."
                        sleep 3
                    done
                else
                    log "    ! 核心脚本下载失败，尝试从镜像提取..."
                fi

                if docker exec uuplugin sh -c 'ls /usr/sbin/uu/uu.tar.gz >/dev/null 2>&1' 2>/dev/null; then
                    log "    ✓ UU 核心文件验证通过"
                else
                    log "    ! 警告: 核心文件缺失，尝试从镜像提取..."
                    docker cp uu_tmp_extract:/usr/sbin/uu/. "$BASE_DIR/core/" 2>/dev/null || true
                fi

                docker exec uuplugin sh -c '
if [ -f /usr/sbin/uu/uu.tar.gz ]; then
    cd /usr/sbin/uu && tar -xzf uu.tar.gz 2>/dev/null
    chmod +x /usr/sbin/uu/uuplugin_monitor.sh 2>/dev/null
fi
if ! ps w 2>/dev/null | grep -q "uuplugin_monitor"; then
    if [ -x /usr/sbin/uu/uuplugin_monitor.sh ]; then
        /bin/sh /usr/sbin/uu/uuplugin_monitor.sh >/dev/null 2>&1 &
    fi
fi
' 2>/dev/null

                sleep 2

                if docker exec uuplugin sh -c 'ps w 2>/dev/null | grep -q "uuplugin_monitor"' 2>/dev/null; then
                    log "    ✓ uuplugin 守护进程已运行"
                else
                    log "    ! 警告: uuplugin 守护未启动，请检查容器日志"
                fi

                ACTUAL_SN=$(docker exec uuplugin cat /usr/sbin/uu/.sn 2>/dev/null | cut -d. -f1 || echo "$MAC")
                if [ -n "$ACTUAL_SN" ] && [ "$ACTUAL_SN" != "$MAC" ]; then
                    log "    ✓ 实际绑定 SN: \033[32m${ACTUAL_SN}\033[0m"
                fi

                systemctl restart uu-monitor >/dev/null 2>&1 || true

                echo -e "\n========================================================="
                echo -e " 🎉 跨平台部署全部完成！专业主机模拟环境已恢复！"
                echo -e "========================================================="
                echo -e " 🚀 你的专属绑定 SN 码为: \033[32m$MAC\033[0m"
                echo -e " (若 App 提示格式不对，请去掉冒号输入: \033[32m${MAC//:/}\033[0m )"
                echo -e "========================================================="
                echo -e " 📱 绑定指南："
                echo -e " 1. 确保手机 WiFi 的【路由器/网关】和【DNS】已改为 \033[33m$IP\033[0m"
                echo -e " 2. 确保手机 WiFi 的【子网掩码】填为 \033[36m$NETMASK\033[0m"
                echo -e " 3. 打开 UU主机加速 App，选择【手动输入 SN 码绑定】"
                echo -e " 4. 填入上方的绿色 SN 码完成强绑。"
                echo -e " 5. 绑定成功后，必须将手机 WiFi 设回自动获取！"
                echo -e "========================================================="
                echo -e " 🎮 动态环境状态："
                echo -e " - 宿主网卡: $IFACE | 动态子网掩码: \033[36m$NETMASK\033[0m"
                echo -e " - UU 旁路由 IP: \033[33m$IP\033[0m"
                echo -e " - 模拟 PS4 IP:  \033[36m$PS4_IP\033[0m"
                echo -e " - 模拟 PS5 IP:  \033[36m$PS5_IP\033[0m"
                echo -e "=========================================================\n"
                pause_enter ;;
            2) cd "$BASE_DIR" && dkcompose restart 2>/dev/null || true; echo -e "${GREEN}[OK] UU 容器组已重启。${NC}"; pause_enter ;;
            3) cd "$BASE_DIR" && dkcompose stop 2>/dev/null || true; echo -e "${YELLOW}[停用] UU 容器组已停止。${NC}"; pause_enter ;;
            4) if [ -f "$BASE_DIR/docker-compose.yaml" ]; then cat "$BASE_DIR/docker-compose.yaml"; else echo -e "${RED}[!] 配置文件不存在。${NC}"; fi; pause_enter ;;
            0) break ;;
            *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
        esac
    done
}

# ----------------------------------------------------
# 2. Mihomo 分流管理（缺陷4.7：控制面鉴权 + 版本固定）
# ----------------------------------------------------
# =============================================================================
# 安装/更新 容器内 Mihomo 核心与控制面板（菜单 2 -> 选项 1）
# -----------------------------------------------------------------------------
# 设计要点（修复新设备拉取失败）：
#   1) 版本：不再硬编码。通过 Release API / releases/latest 自动获取最新正式版，
#      排除 prerelease / alpha / beta / rc；并打印实际使用的版本号。
#   2) 架构：自动识别 amd64 / arm64 / armv7 等，下载匹配压缩包；
#      amd64 优先 amd64-compatible（不要求 v3 微架构，老 CPU 也能跑），失败再退 amd64。
#   3) 内核与 UI 分离：UI 走多来源 + 多镜像依次尝试，任一来源成功即算成功；
#      内核成功而 UI 失败时，整体仍判定成功（仅提示面板不可用）。
#   4) 容错：每个节点设超时与重试，失败自动切下一节点；全部失败时输出明确原因，
#      并提供「手动指定版本号 / 完整下载地址」的兜底入口。
#   5) 完整性：校验文件大小、gzip 头、可执行权限；解压或校验失败即回滚，
#      保留原有文件，不重启、不影响正在运行的服务（重启请用菜单 3）。
# =============================================================================

# --- 解析最新正式版版本号：成功回显版本号，失败返回 1 ---
mihomo_resolve_version() {
    local v="" j="" loc="" api mirrors m

    # 方式 A：Release API（含镜像），排除预发布与 alpha/beta/rc
    api="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
    mirrors="$api https://ghproxy.com/${api} https://gh-proxy.com/${api}"
    for m in $mirrors; do
        j="$(curl -fsSL --connect-timeout 8 --max-time 20 "$m" 2>/dev/null || true)"
        [ -n "$j" ] || continue
        # 排除预发布
        case "$j" in
            *'"prerelease":true'*|*'"prerelease": true'*) continue ;;
        esac
        v="$(printf '%s' "$j" | grep -oE '"tag_name"[^,]*' | head -n1 | cut -d'"' -f4)"
        case "$v" in
            *[Aa]lpha*|*[Bb]eta*|*-rc*|*rc[0-9]*) v="" ; continue ;;
        esac
        [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    done

    # 方式 B：解析 releases/latest 的 302 Location（无 API 限流问题）
    loc="$(curl -sSI --connect-timeout 8 --max-time 20 \
           "https://github.com/MetaCubeX/mihomo/releases/latest" 2>/dev/null \
           | grep -i '^location:' | tail -n1 | tr -d '\r')"
    v="${loc##*/tag/}"
    case "$v" in
        http*|*"location"*) v="" ;;
        *[Aa]lpha*|*[Bb]eta*|*-rc*) v="" ;;
    esac
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }

    return 1
}

# --- 多镜像 + 重试拉取：$1=url $2=输出文件 ---
mihomo_fetch() {
    local url="$1" out="$2" m i
    local mirrors="$url https://ghproxy.com/${url} https://gh-proxy.com/${url} https://ghp.ci/${url}"
    for m in $mirrors; do
        for i in 1 2; do
            echo -e "    尝试节点: ${m}  (第 ${i} 次)"
            if curl -fsSL --connect-timeout 10 --max-time "${DL_MAX_TIME:-600}" \
                    "$m" -o "$out" 2>/dev/null && [ -s "$out" ]; then
                echo -e "    ${GREEN}[OK] 拉取成功${NC}"
                return 0
            fi
            sleep 1
        done
    done
    return 1
}

# --- 主体 ---
install_mihomo_core_and_ui() {
    local ARCH OS MIHOMO_ARCH VER ARCH_VARIANTS V
    local BIN BAK TMPBIN OK_CORE=0 UI_SRC="" SIZE

    echo -e "\n${CYAN}>>> 开始多节点智能拉取 Mihomo 核心与面板 <<<${NC}"

    # ---------- 1. 运行环境识别 ----------
    ARCH="$(uname -m)"; OS="$(uname -s)"
    case "$ARCH" in
        x86_64|amd64)  MIHOMO_ARCH="amd64-compatible" ; ARCH_VARIANTS="amd64-compatible amd64" ;;
        aarch64|arm64) MIHOMO_ARCH="arm64"            ; ARCH_VARIANTS="arm64" ;;
        armv7l|armv6l) MIHOMO_ARCH="armv7"            ; ARCH_VARIANTS="armv7" ;;
        *)             MIHOMO_ARCH="amd64-compatible" ; ARCH_VARIANTS="amd64-compatible amd64" ;;
    esac
    echo -e "  运行环境: ${CYAN}${OS} / ${ARCH}${NC}  ->  内核包架构: ${CYAN}${MIHOMO_ARCH}${NC}"

    # ---------- 2. 自动获取最新正式版 ----------
    VER="$(mihomo_resolve_version 2>/dev/null || true)"
    if [ -n "$VER" ]; then
        echo -e "  ${GREEN}[OK] 检测到最新正式版: ${VER}${NC}"
    else
        echo -e "  ${YELLOW}[!] 自动获取版本号失败（API 与镜像均不可达）${NC}"
        echo -e "  兜底1: 使用脚本内置版本 ${CYAN}${MIHOMO_VERSION}${NC}"
        VER="$MIHOMO_VERSION"
        read -p "  兜底2: 可直接输入版本号(如 v1.19.31) 或完整下载地址，回车则用内置版本: " _manual
        if [ -n "$_manual" ]; then
            case "$_manual" in
                http*) MIHOMO_MANUAL_URL="$_manual" ;;
                *)     VER="$_manual" ;;
            esac
        fi
    fi
    echo -e "  ${CYAN}>>> 实际使用版本: ${VER}${NC}"

    # ---------- 3. 拉取并部署内核 ----------
    BIN="$BASE_DIR/mihomo/mihomo"
    mkdir -p "$BASE_DIR/mihomo"
    BAK="${BIN}.bak.$(date +%Y%m%d%H%M%S)"
    [ -f "$BIN" ] && cp -p "$BIN" "$BAK" && echo -e "  已备份原内核 -> $(basename "$BAK")"

    for V in $ARCH_VARIANTS; do
        local DL_OK=0
        if [ -n "${MIHOMO_MANUAL_URL:-}" ]; then
            URL="$MIHOMO_MANUAL_URL"
        else
            URL="https://github.com/MetaCubeX/mihomo/releases/download/${VER}/mihomo-linux-${V}-${VER}.gz"
        fi
        echo -e "\n  ${CYAN}>>> 内核变体: ${V}${NC}"
        if ! mihomo_fetch "$URL" /tmp/mihomo.gz; then
            echo -e "  ${YELLOW}[!] 该变体所有节点均失败，尝试下一个变体${NC}"
            rm -f /tmp/mihomo.gz
            continue
        fi

        # --- 完整性校验：大小 ---
        SIZE="$(stat -c%s /tmp/mihomo.gz 2>/dev/null || stat -f%z /tmp/mihomo.gz 2>/dev/null || echo 0)"
        if [ "${SIZE:-0}" -lt 1048576 ]; then
            echo -e "  ${RED}[!] 文件过小(${SIZE} 字节)，判定为下载不完整，切换下一节点/变体${NC}"
            rm -f /tmp/mihomo.gz; continue
        fi
        # --- 完整性校验：gzip 头 (1f 8b) ---
        if ! gzip -t /tmp/mihomo.gz >/dev/null 2>&1; then
            echo -e "  ${RED}[!] 压缩包头校验失败(非 gzip)，切换下一节点/变体${NC}"
            rm -f /tmp/mihomo.gz; continue
        fi

        # --- 解压到临时文件，校验可执行后再原子替换 ---
        TMPBIN="${BIN}.new.$$"
        if gzip -d -c /tmp/mihomo.gz > "$TMPBIN" 2>/dev/null && chmod +x "$TMPBIN" 2>/dev/null \
           && "$TMPBIN" -v >/dev/null 2>&1; then
            mv -f "$TMPBIN" "$BIN"
            rm -f /tmp/mihomo.gz
            OK_CORE=1
            echo -e "  ${GREEN}[OK] Mihomo 内核部署完成（变体 ${V}）${NC}"
            VER_SHOW="$("$BIN" -v 2>/dev/null | head -n1 || true)"
            break
        else
            echo -e "  ${RED}[!] 解压或实机校验失败，已回滚该次安装（原内核未被破坏）${NC}"
            rm -f "$TMPBIN" /tmp/mihomo.gz
            continue
        fi
    done

    if [ "$OK_CORE" = 0 ]; then
        echo -e "\n  ${RED}[!] 内核安装失败：所有变体/节点均未成功。${NC}"
        echo -e "  常见原因：① 网络不可达 GitHub 及其镜像 ② 版本 ${VER} 无对应架构包 ③ 磁盘空间不足"
        echo -e "  兜底：重选本项后输入完整下载地址（如 https://.../mihomo-linux-amd64-compatible-vX.Y.Z.gz）"
        [ -f "$BAK" ] && echo -e "  原内核保持可用: ${CYAN}${BIN}${NC}"
        return 1
    fi

    # ---------- 4. Web 控制面板（多来源 + 多镜像，任一成功即可） ----------
    echo -e "\n  ${CYAN}>>> 开始拉取 Web 控制面板（多来源依次尝试）${NC}"
    mkdir -p "$BASE_DIR/mihomo/ui"
    local ui_sources=""
    ui_sources="https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz"
    ui_sources="$ui_sources https://github.com/MetaCubeX/metacubexd/releases/download/v1.141.1/compressed-dist.tgz"
    local s
    for s in $ui_sources; do
        if mihomo_fetch "$s" /tmp/mxd.tgz; then
            SIZE="$(stat -c%s /tmp/mxd.tgz 2>/dev/null || stat -f%z /tmp/mxd.tgz 2>/dev/null || echo 0)"
            if [ "${SIZE:-0}" -lt 1024 ]; then
                echo -e "  ${YELLOW}[!] 面板包过小，视为失败，换下一来源${NC}"; rm -f /tmp/mxd.tgz; continue
            fi
            if tar -xzf /tmp/mxd.tgz -C "$BASE_DIR/mihomo/ui" 2>/dev/null; then
                rm -f /tmp/mxd.tgz
                mv "$BASE_DIR/mihomo/ui/compressed-dist/"* "$BASE_DIR/mihomo/ui/" 2>/dev/null || true
                rm -rf "$BASE_DIR/mihomo/ui/compressed-dist" 2>/dev/null || true
                UI_SRC="$s"
                echo -e "  ${GREEN}[OK] Web 控制面板部署完毕${NC}"
                break
            else
                echo -e "  ${YELLOW}[!] 面板解压失败，换下一来源${NC}"; rm -f /tmp/mxd.tgz
            fi
        fi
    done
    if [ -z "$UI_SRC" ]; then
        echo -e "  ${YELLOW}[!] 所有面板来源均失败（不影响内核与转发，仅 :9090/ui 不可用）${NC}"
    fi

    # ---------- 5. 结果汇总 ----------
    echo -e "\n${GREEN}=============================================================${NC}"
    echo -e "  ${GREEN}[OK] 内核版本${NC} : ${VER_SHOW:-$("$BIN" -v 2>/dev/null | head -n1)}"
    if [ -n "$UI_SRC" ]; then
        echo -e "  ${GREEN}[OK] 面板来源${NC} : ${UI_SRC}"
    else
        echo -e "  ${YELLOW}[!] 面板来源${NC} : 未获取到（内核已就绪，可稍后重试本项）"
    fi
    echo -e "  ${CYAN}提示${NC}     : 本次只替换了二进制文件，未重启服务；请按需执行菜单 3 重启生效"
    echo -e "${GREEN}=============================================================${NC}"
    return 0
}


menu_mihomo() {
    while true; do
        clear
        local mihomo_state="${RED}[已停止/未安装]${NC}"
        if command -v docker >/dev/null 2>&1; then
            if docker exec uuplugin pgrep -f mihomo >/dev/null 2>&1; then mihomo_state="${GREEN}[容器内运行中]${NC}"; fi
        fi

        echo -e "${BLUE}===============================================${NC}"
        echo -e "${YELLOW}           --- 2. Mihomo 代理分流管理 ---      ${NC}"
        echo -e "${BLUE}===============================================${NC}"
        echo -e "  运行位置: ${CYAN}Docker uuplugin 容器内部${NC}"
        echo -e "  当前状态: $mihomo_state"
        echo -e "-----------------------------------------------"
        echo -e "  ${YELLOW}1)${NC} [+] 安装/更新 容器内 Mihomo 核心与控制面板"
        echo -e "  ${CYAN}2)${NC} [*] 交互式生成 / 编辑 config.yaml 配置文件"
        echo -e "  ${GREEN}3)${NC} [*] 重启 容器内 Mihomo 服务"
        echo -e "  ${RED}4)${NC} [*] 停止 容器内 Mihomo 服务"
        echo -e "  ${NC}0) 返回主菜单"
        echo -e "${BLUE}===============================================${NC}"
        read -p "请输入选项: " opt
        case $opt in
            1)
                install_mihomo_core_and_ui
                pause_enter ;;
            2)
                clear
                echo -e "${CYAN}===============================================${NC}"
                echo -e "${YELLOW}        --- Mihomo 配置文件交互向导 ---        ${NC}"
                echo -e "${CYAN}===============================================${NC}"

                CONFIG_DB="$BASE_DIR/conf/mihomo_nodes.txt"
                SUB_DB="$BASE_DIR/conf/mihomo_sub.txt"
                touch "$CONFIG_DB" "$SUB_DB"

                EXISTING_NODES=$(cut -d'|' -f1 "$CONFIG_DB" 2>/dev/null | tr '\n' ' ')
                if [ -n "$EXISTING_NODES" ]; then
                    echo -e "  ▶ 当前已保存的加速通道: ${GREEN}${EXISTING_NODES}${NC}"
                else
                    echo -e "  ▶ 当前已保存的加速通道: ${YELLOW}无${NC}"
                fi

                old_sub=$(cat "$SUB_DB" 2>/dev/null)
                read -p "▶ 机场订阅链接 [当前已存: ${old_sub:-无}, 回车保持原样]: " sub_input
                [ -n "$sub_input" ] && sub_url="$sub_input" || sub_url="$old_sub"
                echo "$sub_url" > "$SUB_DB"

                echo -e "\n${YELLOW}--- WARP 节点状态保留配置 ---${NC}"
                read -p "▶ 请输入要 新增或覆盖 的网卡名 (例如 tun164，直接回车则跳过): " bind_tun
                bind_tun=$(echo "$bind_tun" | tr -d ' ')

                if [ -n "$bind_tun" ]; then
                    if grep -q "^${bind_tun}|" "$CONFIG_DB" 2>/dev/null; then
                        read -p "  ⚠️ 发现已存在 [${bind_tun}]，如需覆盖修改请输入 Y: " overwrite_confirm
                        if [[ ! "$overwrite_confirm" =~ ^[Yy]$ ]]; then
                            echo -e "  ${YELLOW}操作已取消，保持原有 [${bind_tun}] 配置不变。${NC}"
                            bind_tun=""
                        fi
                    fi

                    if [ -n "$bind_tun" ]; then
                        rnd_ss_port=$((RANDOM % 45000 + 10000))
                        rnd_mixed_port=$((RANDOM % 10000 + 20000))
                        read -p "  1. SS 监听端口 [默认随机: $rnd_ss_port]: " ss_port
                        ss_port=${ss_port:-$rnd_ss_port}
                        read -p "  2. SS 密码 [默认: password]: " ss_pass
                        ss_pass=${ss_pass:-password}
                        read -p "  3. WARP Private Key [选填, 回车待填]: " warp_key
                        warp_key=${warp_key:-ReplaceWithYourWarpPrivateKey}
                        read -p "  4. WARP IPv6 [选填, 回车跳过]: " warp_ipv6
                        read -p "  5. WARP Reserved [选填, 回车跳过]: " warp_reserved
                        read -p "  6. WARP 接入点 IP [默认: 162.159.192.1]: " warp_endpoint
                        warp_endpoint=${warp_endpoint:-162.159.192.1}

                        TMP_DB=$(mktemp)
                        grep -v "^${bind_tun}|" "$CONFIG_DB" > "$TMP_DB" 2>/dev/null || true
                        cat "$TMP_DB" > "$CONFIG_DB"
                        rm -f "$TMP_DB"

                        echo "${bind_tun}|${ss_port}|${ss_pass}|${warp_key}|${warp_ipv6}|${warp_reserved}|${warp_endpoint}|${rnd_mixed_port}" >> "$CONFIG_DB"
                        echo -e "  ${GREEN}✓ 网卡 [${bind_tun}] 的配置已安全保存！${NC}"
                    fi
                fi

                LISTENERS_YAML=""
                PROXIES_YAML=""
                PROXY_NAMES=""

                if [ -s "$CONFIG_DB" ]; then
                    while IFS='|' read -r t_tun t_ss_port t_ss_pass t_w_key t_w_ipv6 t_w_res t_w_ep t_mix_port || [ -n "$t_tun" ]; do
                        [ -z "$t_tun" ] && continue

                        num=$(echo "$t_tun" | grep -oE '[0-9]+' | head -n 1)
                        suffix="${num:-_$t_tun}"
                        node_name="WARP${suffix}"
                        ss_name="ss-in${suffix}"
                        socks_name="socks-in${suffix}"

                        LISTENERS_YAML="${LISTENERS_YAML}
  - name: ${ss_name}
    type: shadowsocks
    port: ${t_ss_port}
    listen: 0.0.0.0
    cipher: aes-256-gcm
    password: \"${t_ss_pass}\"
    udp: true
    proxy: ${node_name}
  - name: ${socks_name}
    type: mixed
    port: ${t_mix_port}
    listen: 0.0.0.0
    proxy: ${node_name}"

                        ipv6_line="# ipv6: 未设置"
                        [ -n "$t_w_ipv6" ] && ipv6_line="ipv6: \"$t_w_ipv6\""

                        res_line="# reserved: 未设置"
                        if [ -n "$t_w_res" ]; then
                            if [[ "$t_w_res" != \[* ]]; then t_w_res="[$t_w_res]"; fi
                            res_line="reserved: ${t_w_res}"
                        fi

                        PROXIES_YAML="${PROXIES_YAML}
  - name: \"${node_name}\"
    type: wireguard
    server: ${t_w_ep}
    port: 2408
    ip: \"172.16.0.2/32\"
    ${ipv6_line}
    private-key: \"${t_w_key}\"
    ${res_line}
    public-key: \"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=\"
    udp: true
    mtu: 1280
    remote-dns-resolve: false
    dns:
      - https://dns.cloudflare.com/dns-query
    interface-name: ${t_tun}"

                        PROXY_NAMES="${PROXY_NAMES}
      - ${node_name}"
                    done < "$CONFIG_DB"
                else
                    rnd_ss_fallback=$((RANDOM % 45000 + 10000))
                    LISTENERS_YAML="
  - name: ss-in
    type: shadowsocks
    port: ${rnd_ss_fallback}
    listen: 0.0.0.0
    cipher: aes-256-gcm
    password: \"password\"
    udp: true
    proxy: DIRECT"
                fi

                provider_block=""
                proxy_use_list=""
                if [ -n "${sub_url}" ]; then
                    mkdir -p "$BASE_DIR/mihomo/providers"
                    provider_block="proxy-providers:
  my_airport:
    type: http
    url: \"${sub_url}\"
    interval: 86400
    path: ./providers/airport.yaml
    health-check:
      enable: true
      interval: 600
      url: http://cp.cloudflare.com"
                    proxy_use_list="    use:
      - my_airport"
                fi

                mkdir -p "$BASE_DIR/mihomo/rules"
                if [ ! -f "$BASE_DIR/mihomo/rules/fwd_whitelist.yaml" ]; then
                    echo -e "payload:\n  - IP-CIDR,127.0.0.1/32" > "$BASE_DIR/mihomo/rules/fwd_whitelist.yaml"
                fi

                proxies_header=""
                if [ -n "$PROXIES_YAML" ]; then
                    proxies_header="proxies:${PROXIES_YAML}"
                fi

                # 阶段二(缺陷4.7)：external-controller 设置随机 secret，避免局域网无鉴权接管
                if [ ! -s "$MIHOMO_SECRET_FILE" ]; then
                    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 > "$MIHOMO_SECRET_FILE" 2>/dev/null || true
                fi
                MIHOMO_SECRET="$(cat "$MIHOMO_SECRET_FILE" 2>/dev/null)"
                [ -z "$MIHOMO_SECRET" ] && MIHOMO_SECRET="changeme-please-set"

                # [fix] 已是 TUN 捕获模式配置(含 mihomo0)则不再覆盖，保留现场修复，
                # 否则会冲掉端口转发依赖的 tun: / device: mihomo0 / fwd_warp163|164 规则集。
                if grep -qE 'device: *mihomo0' "$BASE_DIR/mihomo/config.yaml" 2>/dev/null; then
                    echo -e "${YELLOW}[跳过] 检测到已有 TUN 捕获模式配置(config.yaml 含 mihomo0)，已保留不覆盖。${NC}"
                    echo -e "${YELLOW}       如需重新生成，请先手动备份并删除 config.yaml 后再执行本项。${NC}"
                    pause_enter
                    continue
                fi
                # [fix] 端口转发依赖 TUN 捕获模式：仅当生成的代理中出现 WARP163/WARP164
                # （即已配置绑定 tun163/164 的 WARP 出网节点）时才写入对应规则集，
                # 避免引用不存在的代理名造成 mihomo 规则失效。
                FWD_PROVIDERS_YAML=""
                FWD_RULES_YAML=""
                if echo "${proxies_header}${PROXY_NAMES}" | grep -q 'WARP163'; then
                    FWD_PROVIDERS_YAML="$FWD_PROVIDERS_YAML
  fwd_warp163:
    type: file
    behavior: classical
    format: yaml
    path: ./rules/fwd_warp163.yaml"
                    FWD_RULES_YAML="$FWD_RULES_YAML
  - RULE-SET,fwd_warp163,WARP163"
                fi
                if echo "${proxies_header}${PROXY_NAMES}" | grep -q 'WARP164'; then
                    FWD_PROVIDERS_YAML="$FWD_PROVIDERS_YAML
  fwd_warp164:
    type: file
    behavior: classical
    format: yaml
    path: ./rules/fwd_warp164.yaml"
                    FWD_RULES_YAML="$FWD_RULES_YAML
  - RULE-SET,fwd_warp164,WARP164"
                fi
                # 规则集文件必须存在，否则 mihomo 加载 provider 会失败
                mkdir -p "$BASE_DIR/mihomo/rules"
                if [ -n "$FWD_PROVIDERS_YAML" ]; then
                    for _f in fwd_warp163.yaml fwd_warp164.yaml; do
                        [ -s "$BASE_DIR/mihomo/rules/$_f" ] || printf 'payload:\n  - IP-CIDR,127.0.0.1/32\n' > "$BASE_DIR/mihomo/rules/$_f"
                    done
                fi
                cat > "$BASE_DIR/mihomo/config.yaml" << EOF_CONF
port: 7890
socks-port: 7891
mixed-port: 7892
allow-lan: true
bind-address: '*'
mode: rule
log-level: info
ipv6: false

external-controller: 0.0.0.0:9090
external-ui: ui
secret: "${MIHOMO_SECRET}"

# ===== TUN 捕获模式（端口转发依赖）=====
# 转发流量经 DNAT 后被引擎路由进捕获设备 mihomo0，由 mihomo 有状态代理出网。
# 不可改为裸路由进 tun163/164：WARP 会把源 NAT 成 WARP IP，回包到不了客户端。
# auto-route:false 保证「只有转发目标」被引入 mihomo，其余流量默认直连。
tun:
  enable: true
  device: mihomo0
  stack: system
  auto-route: false
  auto-detect-interface: false
  dns-hijack: []
  endpoint-independent-nat: true
  address: 172.19.233.1/24

dns:
  enable: true
  listen: 0.0.0.0:1053
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    # [WARP 修复] 必须用纯 IP 的 DNS，不能用 DoH(https://...)：
    # DoH 需要先解析 dns.cloudflare.com，而解析本身又依赖 DNS —— 一旦上游不通就形成
    # 自指死锁，表现为 WARP 节点 alive:false 且日志刷 "requesting https://dns.cloudflare.com/...
    # context deadline exceeded"。纯 IP 无此依赖。
    - 119.29.29.29
    - 223.5.5.5
    - 8.8.8.8

listeners:${LISTENERS_YAML}

${proxies_header}

${provider_block}

proxy-groups:
  - name: "PROXIES"
    type: select
    proxies:
      - DIRECT${PROXY_NAMES}
${proxy_use_list}

rule-providers:
  fwd_whitelist:
    type: file
    behavior: classical
    format: yaml
    path: ./rules/fwd_whitelist.yaml${FWD_PROVIDERS_YAML}

rules:
  - RULE-SET,fwd_whitelist,DIRECT${FWD_RULES_YAML}
  - MATCH,PROXIES
EOF_CONF

                echo -e "\n${GREEN}[OK] 配置文件 (config.yaml) 生成成功！${NC}"
                echo -e "${YELLOW}    ⚠️ Mihomo 面板鉴权 secret 已随机生成：${MIHOMO_SECRET}（请妥善保存，访问 :9090/ui 需此口令）${NC}"
                read -p "是否需要使用 nano 编辑器进行高级微调？(y/n): " edit_confirm
                if [[ "$edit_confirm" =~ ^[Yy]$ ]]; then
                    if command -v nano >/dev/null 2>&1; then nano "$BASE_DIR/mihomo/config.yaml"; else echo -e "${RED}系统未安装 nano，跳过。${NC}"; fi
                fi
                pause_enter ;;
            3)
                if docker ps | grep -q uuplugin; then
                    docker exec uuplugin sh /etc/scripts/restart_mihomo.sh 2>&1 | tail -n 6
                    CONT_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' uuplugin 2>/dev/null)
                    echo -e "${GREEN}[OK] 已在容器内拉起 Mihomo 进程。\n🌐 面板访问地址: ${CYAN}http://$CONT_IP:9090/ui${NC}  (需 secret 鉴权)"
                else
                    echo -e "${RED}[!] UU 容器未运行。${NC}"
                fi
                pause_enter ;;
            4) docker exec uuplugin killall mihomo 2>/dev/null || true; echo -e "${YELLOW}[停用] 已关闭容器内的 Mihomo 进程。${NC}"; pause_enter ;;
            0) break ;;
            *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
        esac
    done
}

# ----------------------------------------------------
# 3. 端口转发管理模块
# ----------------------------------------------------
menu_port() {
    while true; do
        clear
        echo -e "${BLUE}===============================================${NC}"
        echo -e "${YELLOW}           --- 3. 端口转发与规则管理 ---       ${NC}"
        echo -e "${BLUE}===============================================${NC}"
        echo -e "  配置存放池: ${GREEN}$RULES_DB${NC}"
        echo -e "-----------------------------------------------"
        echo -e "  ${CYAN}1)${NC} [*] 查看当前所有生效的转发规则"
        echo -e "  ${GREEN}2)${NC} [+] 添加新转发规则 (支持绑定指定 tun 网卡)"
        echo -e "  ${RED}3)${NC} [-] 删除现有转发规则"
        echo -e "  ${YELLOW}4)${NC} [~] 手动编辑规则配置文件 (nano)"
        echo -e "  ${BLUE}5)${NC} [↻] 重载/刷新 转发IP规则 (修改文件后执行)"
        echo -e "  ${NC}0) 返回主菜单"
        echo -e "${BLUE}===============================================${NC}"
        read -p "请输入选项: " opt
        case $opt in
            1)
                if grep -vE "^#|^$" "$RULES_DB" >/dev/null 2>&1; then
                    echo -e "\033[0;36m--- 当前保存在宿主机的转发规则 ---\033[0m"
                    while read -r line; do
                        case "$line" in \#*) continue ;; "") continue ;; esac
                        THOST=$(echo "$line" | cut -d':' -f1); LPORT=$(echo "$line" | cut -d':' -f2); RPORT=$(echo "$line" | cut -d':' -f3); TUN=$(echo "$line" | cut -d':' -f4)
                        printf " ▶ 监听: \033[1;32m%s\033[0m -> 目标: \033[1;33m%s\033[0m:%s (网卡强绑: \033[1;35m%s\033[0m)\n" "$LPORT" "$THOST" "${RPORT:-$LPORT}" "${TUN:-未绑定}"
                    done < "$RULES_DB"
                else
                    echo -e "\033[1;33m暂无任何端口转发规则。\033[0m"
                fi
                pause_enter ;;
            2)
                echo -e "\n${CYAN}--- 添加新规则 ---${NC}"
                echo -e "${YELLOW}正在探测容器内可用的 UU 加速通道...${NC}"
                bind_tun=""
                if docker ps | grep -q uuplugin; then
                    available_tuns=$(docker exec uuplugin ip link show 2>/dev/null | grep -oE 'tun[0-9]+' | sort -u)
                    if [ -n "$available_tuns" ]; then
                        echo -e "发现活动通道:"
                        tun_idx=1
                        echo "$available_tuns" | while read -r tun_name; do
                            echo -e "  ${GREEN}${tun_idx})${NC} 绑定 ${CYAN}${tun_name}${NC}"
                            tun_idx=$((tun_idx + 1))
                        done
                        tun_count=$(echo "$available_tuns" | wc -l)
                        echo -e "  ${YELLOW}0)${NC} 不绑定网卡（直接回车默认）"
                        echo ""
                        read -p "1. 选择【出站】强绑的 UU 隧道网卡 [0-${tun_count}] (回车=不绑定/走默认): " tun_choice
                        if [ -n "$tun_choice" ] && [ "$tun_choice" -gt 0 ] 2>/dev/null; then
                            bind_tun=$(echo "$available_tuns" | sed -n "${tun_choice}p")
                            [ -n "$bind_tun" ] && echo -e "  ${GREEN}✓ 已选择绑定: ${bind_tun}${NC}" || echo -e "  ${YELLOW}序号无效，将不绑定网卡${NC}"
                        fi
                    else
                        echo -e "${RED}未检测到活动 tun 通道，UU 可能未开启加速。${NC}"
                    fi
                fi

                read -p "2. 输入目标服务器 IP 或 域名 (例: google.com): " dest_host
                read -p "3. 输入本地监听端口 (例: 10001): " lport
                read -p "4. 输入目标服务器端口 (例: 443, 回车默认与本地一致): " dport

                if [ -n "$dest_host" ] && [ -n "$lport" ]; then
                    dport=${dport:-$lport}
                    echo "${dest_host}:${lport}:${dport}:${bind_tun}" >> "$RULES_DB"
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - [添加规则] $dest_host:$lport:$dport (网卡强绑: ${bind_tun:-未绑定})" >> "$PORT_AUDIT_LOG"
                    echo -e "${GREEN}规则已写入。正在向容器下发重载指令...${NC}"
                    docker exec uuplugin sh /etc/scripts/proxy_manager.sh reload 2>/dev/null || true
                else
                    echo -e "${RED}输入不完整，操作取消。${NC}"
                fi
                pause_enter ;;
            3)
                read -p "输入要删除的 本地监听端口: " lport
                if [ -n "$lport" ]; then
                    TMP_DB=$(mktemp)
                    grep -v "^.*:${lport}:.*$" "$RULES_DB" > "$TMP_DB" 2>/dev/null || true
                    cat "$TMP_DB" > "$RULES_DB"
                    rm -f "$TMP_DB"

                    echo "$(date '+%Y-%m-%d %H:%M:%S') - [删除规则] 清除了端口 $lport 相关的转发规则" >> "$PORT_AUDIT_LOG"
                    echo -e "${GREEN}删除成功，重载规则...${NC}"
                    docker exec uuplugin sh /etc/scripts/proxy_manager.sh reload 2>/dev/null || true
                fi
                pause_enter ;;
            4) if command -v nano >/dev/null; then nano "$RULES_DB"; docker exec uuplugin sh /etc/scripts/proxy_manager.sh reload 2>/dev/null; fi; pause_enter ;;
            5) docker exec uuplugin sh /etc/scripts/proxy_manager.sh reload 2>/dev/null; echo "已下发重载命令。"; pause_enter ;;
            0) break ;;
            *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
        esac
    done
}

# ----------------------------------------------------
# 4. 日志与看门狗监控中心
# ----------------------------------------------------
menu_logs() {
    while true; do
        clear
        local log_status="${RED}未配置${NC}"
        if grep -q "time=7d" "/etc/cron.daily/uu_journal_vacuum" 2>/dev/null; then log_status="${GREEN}7天轮询 (推荐使用)${NC}"
        elif grep -q "time=3d" "/etc/cron.daily/uu_journal_vacuum" 2>/dev/null; then log_status="${YELLOW}3天轮询 (极致清理)${NC}"; fi

        echo -e "${BLUE}===============================================${NC}"
        echo -e "${YELLOW}           --- 4. 日志管理与监控看板 ---       ${NC}"
        echo -e "${BLUE}===============================================${NC}"
        echo -e "  当前清理策略: ${log_status}"
        echo -e "-----------------------------------------------"
        echo -e "  ${GREEN}1)${NC} [*] 实时查看: UU 加速核心 日志"
        echo -e "  ${CYAN}2)${NC} [*] 实时查看: Mihomo 分流 日志"
        echo -e "  ${RED}3)${NC} [*] 实时查看: 智能看门狗与熔断机制 日志"
        echo -e "-----------------------------------------------"
        echo -e "  ${YELLOW}4)${NC} [#] 历史审计: 端口转发配置文件增删记录"
        echo -e "-----------------------------------------------"
        echo -e "  ${GREEN}5)${NC} [+] 设为 7天日志轮询 (推荐使用)"
        echo -e "  ${YELLOW}6)${NC} [+] 设为 3天日志轮询 (清理旧数据)"
        echo -e "  ${RED}7)${NC} [-] 一键彻底清理所有日志数据 (释放空间)"
        echo -e "-----------------------------------------------"
        echo -e "  ${CYAN}8)${NC} [@] 配置 WxPusher 微信消息推送 (掉线/恢复告警)"
        echo -e "  ${RED}9)${NC} [-] 清理并关闭 WxPusher 消息推送"
        echo -e "  ${NC}0) 返回主菜单"
        echo -e "${BLUE}===============================================${NC}"
        read -p "请输入选项: " opt
        case $opt in
            1) view_log_stream "docker logs --tail 50 -f uuplugin"; pause_enter ;;
            2) [ -f "$BASE_DIR/conf/mihomo.log" ] && view_log_stream "tail -n 50 -f $BASE_DIR/conf/mihomo.log" || (echo -e "${RED}无 Mihomo 日志。${NC}"; pause_enter) ;;
            3) view_log_stream "journalctl -u uu-monitor -n 50 -f"; pause_enter ;;
            4) echo ""; cat "$PORT_AUDIT_LOG" 2>/dev/null || echo "暂无记录。"; pause_enter ;;
            5) setup_log_rotation 7 ;;
            6) setup_log_rotation 3 ;;
            7)
                echo -e "\n${BLUE}>>> 正在彻底清理系统与面板的所有日志数据...${NC}"
                journalctl --rotate >/dev/null 2>&1; journalctl --vacuum-time=1s >/dev/null 2>&1
                find /var/lib/docker/containers/ -type f -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null || true
                rm -f "$BASE_DIR/conf/"*.log "$BASE_DIR/log/"*.log 2>/dev/null || true
                echo -e "${GREEN}[OK] 日志清理完成！系统犹如新生。${NC}"
                pause_enter ;;
            8)
                clear
                echo -e "${CYAN}===============================================${NC}"
                echo -e "${YELLOW}       --- WxPusher 微信推送配置向导 ---       ${NC}"
                echo -e "${CYAN}===============================================${NC}"
                echo -e "获取 Token 与 UID 请访问: https://wxpusher.zjiecode.com\n"
                local current_token="未配置"; local current_uid="未配置"
                if [ -f "$WXPUSHER_CONF" ]; then
                    source "$WXPUSHER_CONF"
                    [ -n "$WXPUSHER_APP_TOKEN" ] && current_token="${WXPUSHER_APP_TOKEN:0:6}******${WXPUSHER_APP_TOKEN: -4}"
                    [ -n "$WXPUSHER_UID" ] && current_uid="${WXPUSHER_UID:0:6}******${WXPUSHER_UID: -4}"
                fi
                echo -e "当前 AppToken: ${GREEN}${current_token}${NC}"
                echo -e "当前 UID:      ${GREEN}${current_uid}${NC}\n"

                read -p "请输入您的 AppToken (直接回车保持不变): " input_token
                if [ -n "$input_token" ]; then
                    read -p "请输入您的接收 UID (UID_xxx...): " input_uid
                    if [ -n "$input_uid" ]; then
                        echo "WXPUSHER_APP_TOKEN=\"$input_token\"" > "$WXPUSHER_CONF"
                        echo "WXPUSHER_UID=\"$input_uid\"" >> "$WXPUSHER_CONF"
                        systemctl restart uu-monitor >/dev/null 2>&1
                        echo -e "\n${GREEN}[OK] 看门狗已热重载！掉线/连接状态将推送到您的微信。${NC}"
                    fi
                else
                    echo -e "\n${YELLOW}未修改任何配置。${NC}"
                fi
                pause_enter ;;
            9)
                rm -f "$WXPUSHER_CONF"
                systemctl restart uu-monitor >/dev/null 2>&1
                echo -e "\n${GREEN}[OK] 已清空配置并彻底关闭 WxPusher 微信消息推送功能！${NC}"; pause_enter ;;
            0) break ;;
            *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
        esac
    done
}

menu_backup_restore() {
    while true; do
        clear
        echo -e "${BLUE}===============================================${NC}"
        echo -e "${YELLOW}           --- 5. 备份还原 (迁移功能) ---      ${NC}"
        echo -e "${BLUE}===============================================${NC}"
        echo -e "  数据目录: ${GREEN}$BASE_DIR${NC}"
        echo -e "-----------------------------------------------"
        echo -e "  ${GREEN}1)${NC} [+] 完整备份 (打包所有数据与配置)"
        echo -e "  ${CYAN}2)${NC} [*] 完整还原 (覆盖并固化数据)"
        echo -e "  ${NC}0) 返回主菜单"
        echo -e "${BLUE}===============================================${NC}"
        read -p "请输入选项: " opt
        case $opt in
            1)
                clear
                echo -e "${CYAN}===============================================${NC}"
                echo -e "${YELLOW}        --- 完整备份向导 ---        ${NC}"
                echo -e "${CYAN}===============================================${NC}"
                BACKUP_FILE="/root/uuplugin_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
                echo -e "\n${BLUE}>>> 正在停止容器以确保数据一致性...${NC}"
                cd "$BASE_DIR" && dkcompose stop 2>/dev/null || true
                echo -e "${BLUE}>>> 正在打包全部数据与配置...${NC}"
                cd /opt
                tar -czf "$BACKUP_FILE" uuplugin/ 2>/dev/null
                echo -e "${BLUE}>>> 正在重新启动容器...${NC}"
                cd "$BASE_DIR" && dkcompose start 2>/dev/null || true
                if [ -f "$BACKUP_FILE" ]; then
                    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
                    echo -e "\n${GREEN}✅ 备份完成！${NC}"
                    echo -e "   文件路径: ${CYAN}$BACKUP_FILE${NC}"
                    echo -e "   文件大小: ${CYAN}$BACKUP_SIZE${NC}"
                    echo -e "\n${YELLOW}📋 迁移步骤：${NC}"
                    echo -e "   1. 将备份文件拷贝到新设备: ${CYAN}scp $BACKUP_FILE root@新设备IP:/root/${NC}"
                    echo -e "   2. 在新设备上运行管理面板，选择「完整还原」"
                    echo -e "   3. 还原后根据新设备网络环境调整 IP 和网卡参数"
                else
                    echo -e "\n${RED}[!] 备份失败，请检查磁盘空间。${NC}"
                fi
                pause_enter ;;
            2)
                clear
                echo -e "${RED}===============================================${NC}"
                echo -e "${YELLOW}        [!] 完整还原向导 (危险操作) [!]        ${NC}"
                echo -e "${RED}===============================================${NC}"
                echo -e "${YELLOW}⚠️  警告：还原将覆盖当前所有数据与配置！${NC}"
                echo -e ""
                read -p "请输入备份文件路径 (例: /root/uuplugin_backup_20260918_120000.tar.gz): " RESTORE_FILE
                if [ ! -f "$RESTORE_FILE" ]; then
                    echo -e "${RED}[!] 文件不存在: $RESTORE_FILE${NC}"
                    pause_enter
                    continue
                fi
                echo -e ""
                read -p "确定要还原吗？当前所有数据将被覆盖！(输入 yes 确认): " confirm
                if [ "$confirm" != "yes" ]; then
                    echo -e "${GREEN}操作已取消。${NC}"
                    pause_enter
                    continue
                fi
                echo -e "\n${BLUE}>>> 正在停止所有服务...${NC}"
                systemctl stop uu-monitor 2>/dev/null || true
                cd "$BASE_DIR" 2>/dev/null && dkcompose down 2>/dev/null || true
                echo -e "${BLUE}>>> 正在备份当前数据 (以防万一)...${NC}"
                if [ -d "/opt/uuplugin" ]; then
                    mv /opt/uuplugin "/opt/uuplugin_old_$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
                fi
                echo -e "${BLUE}>>> 正在解包还原数据...${NC}"
                cd /opt
                tar -xzf "$RESTORE_FILE" 2>/dev/null
                if [ -d "/opt/uuplugin" ]; then
                    echo -e "${BLUE}>>> 正在适配当前设备网络环境...${NC}"
                    IFACE=$(ip -4 route | awk '/default/ {print $5}' | head -n 1)
                    GATEWAY=$(ip -4 route | awk '/default/ {print $3}' | head -n 1)
                    IP_PREFIX=$(echo "$GATEWAY" | cut -d. -f1-3)
                    GATEWAY_PREFIX_2=$(echo "$GATEWAY" | cut -d. -f1-2)
                    SUBNET=$(ip -4 route show dev "$IFACE" | grep -v default | grep "^$GATEWAY_PREFIX_2" | awk '{print $1}' | head -n 1)
                    [ -z "$SUBNET" ] && SUBNET="${IP_PREFIX}.0/24"
                    CIDR_SUFFIX=$(echo "$SUBNET" | cut -d/ -f2)
                    NETMASK=$(awk -v cidr="$CIDR_SUFFIX" 'BEGIN { mask=""; for(i=0; i<4; i++) { if(cidr >= 8) { mask = mask "255."; cidr -= 8; } else if(cidr > 0) { mask = mask (256 - 2^(8-cidr)) "."; cidr = 0; } else { mask = mask "0."; } } sub(/\.$/, "", mask); print mask; }')
                    NETMASK=${NETMASK:-255.255.255.0}

                    # 阶段二(缺陷4.2 FIX)：按服务顺序定向替换三个 ipv4_address，杜绝 PS4/PS5 与 UU 同 IP 冲突
                    NEW_IP=$(find_unused_ip 250)
                    [ -z "$NEW_IP" ] && NEW_IP="${IP_PREFIX}.250"
                    NEW_PS4_IP=$(find_unused_ip 249)
                    [ -z "$NEW_PS4_IP" ] && NEW_PS4_IP="${IP_PREFIX}.249"
                    NEW_PS5_IP=$(find_unused_ip 248)
                    [ -z "$NEW_PS5_IP" ] && NEW_PS5_IP="${IP_PREFIX}.248"

                    if [ -f "$BASE_DIR/docker-compose.yaml" ]; then
                        # 使用行级改写：依次替换第 1/2/3 个 ipv4_address 为各自的独立 IP
                        _i=0
                        _tmp_compose="$(mktemp)"
                        while IFS= read -r _line; do
                            if [[ "$_line" =~ ^[[:space:]]*ipv4_address:\ [0-9.]+ ]]; then
                                _i=$((_i + 1))
                                case $_i in
                                    1) _line="    ipv4_address: $NEW_IP" ;;
                                    2) _line="    ipv4_address: $NEW_PS4_IP" ;;
                                    3) _line="    ipv4_address: $NEW_PS5_IP" ;;
                                esac
                            fi
                            printf '%s\n' "$_line"
                        done < "$BASE_DIR/docker-compose.yaml" > "$_tmp_compose"
                        mv "$_tmp_compose" "$BASE_DIR/docker-compose.yaml"

                        # 其余网络参数（parent/subnet/gateway）同步刷新
                        sed -i "s/^\([[:space:]]*parent: \).*/\1$IFACE/" "$BASE_DIR/docker-compose.yaml"
                        sed -i "s|^\([[:space:]]*subnet: \).*|\1$SUBNET|" "$BASE_DIR/docker-compose.yaml"
                        sed -i "s|^\([[:space:]]*gateway: \).*|\1$GATEWAY|" "$BASE_DIR/docker-compose.yaml"
                    fi

                    echo -e "${BLUE}>>> 正在配置网卡混杂模式与宿主机互通（幂等）...${NC}"
                    ip link set "$IFACE" promisc on || true
                    cat << EOF > /etc/systemd/system/${IFACE}-promisc.service
[Unit]
Description=Set ${IFACE} to promiscuous mode
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/bin/ip link set ${IFACE} promisc on
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
                    systemctl daemon-reload || true
                    systemctl enable "${IFACE}-promisc.service" || true
                    # 阶段二(缺陷4.3)：路由/地址幂等
                    ip route replace "$SUBNET" dev "$IFACE" 2>/dev/null || true
                    iptables -t nat -D POSTROUTING -s "$NEW_IP" -o "$IFACE" -j MASQUERADE 2>/dev/null || true
                    iptables -t nat -A POSTROUTING -s "$NEW_IP" -o "$IFACE" -j MASQUERADE 2>/dev/null || true
                    MACVLAN_IP="${IP_PREFIX}.251"
                    ip link show macvlan0 >/dev/null 2>&1 || ip link add macvlan0 link "$IFACE" type macvlan mode bridge 2>/dev/null || true
                    ip addr show dev macvlan0 2>/dev/null | grep -q "$MACVLAN_IP" || ip addr add "$MACVLAN_IP/24" dev macvlan0 2>/dev/null || true
                    ip link set macvlan0 up 2>/dev/null || true
                    ip route replace "$NEW_IP/32" dev macvlan0 2>/dev/null || true

                    echo -e "${BLUE}>>> 正在启动容器与服务...${NC}"
                    cd "$BASE_DIR" && dkcompose up -d 2>/dev/null || true
                    systemctl restart uu-monitor 2>/dev/null || true
                    echo -e "\n${GREEN}✅ 还原完成！数据已固化，App 无需重新绑定。${NC}"
                    echo -e "   新设备 UU IP:    ${CYAN}$NEW_IP${NC}"
                    echo -e "   新设备 PS4 IP:   ${CYAN}$NEW_PS4_IP${NC}"
                    echo -e "   新设备 PS5 IP:   ${CYAN}$NEW_PS5_IP${NC}"
                    echo -e "   物理网卡:       ${CYAN}$IFACE${NC}"
                    echo -e "   网关:           ${CYAN}$GATEWAY${NC}"
                    echo -e "   子网:           ${CYAN}$SUBNET${NC}"
                else
                    echo -e "${RED}[!] 还原失败，备份文件可能已损坏。${NC}"
                fi
                pause_enter ;;
            0) break ;;
            *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
        esac
    done
}

restart_all_services() {
    echo -e "\n${BLUE}>>> 正在重启整个 UU 容器底座及看门狗衍生服务...${NC}"
    systemctl restart uu-monitor >/dev/null 2>&1 || true
    cd "$BASE_DIR" && dkcompose restart 2>/dev/null || true
    echo -e "${GREEN}[OK] 重启指令已发送。容器内的 rc.local 会自动按序拉起 UU/Mihomo/端口转发！${NC}"
    pause_enter
}

menu_cleanup() {
    clear
    echo -e "${RED}===============================================${NC}"
    echo -e "${YELLOW}          [!] 危险操作：彻底清理系统 [!]       ${NC}"
    echo -e "${RED}===============================================${NC}"
    read -p "确定要卸载并彻底清理 UU 及所有容器组件吗？(输入 yes 确认): " confirm
    if [ "$confirm" == "yes" ]; then
        echo -e "\n${BLUE}正在停用看门狗守护服务...${NC}"
        systemctl stop uu-monitor >/dev/null 2>&1 || true
        systemctl disable uu-monitor >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/uu-monitor.service

        echo -e "${BLUE}正在销毁 Docker 容器及网络...${NC}"
        cd "$BASE_DIR" 2>/dev/null || true
        dkcompose down 2>/dev/null || true
        docker rm -f uuplugin PS4 PS5 2>/dev/null || true
        docker network rm uuplugin_macnet 2>/dev/null || true

        echo -e "${BLUE}正在清理宿主机网卡混杂与相关服务...${NC}"
        IFACE=$(ip -4 route | awk '/default/ {print $5}' | head -n 1)
        if [ -n "$IFACE" ]; then
            systemctl disable "${IFACE}-promisc.service" 2>/dev/null || true
            rm -f /etc/systemd/system/"${IFACE}-promisc.service"
            systemctl daemon-reload 2>/dev/null || true
        fi

        echo -e "${BLUE}正在清空映射目录与快捷指令...${NC}"
        rm -f /etc/cron.daily/uu_journal_vacuum /etc/logrotate.d/uu_logs
        rm -f /usr/local/bin/uu
        rm -rf "$BASE_DIR"
        echo -e "${GREEN}[OK] 清理完成！你的系统已犹如新生。${NC}"
        exit 0
    else
        echo -e "${GREEN}操作已取消。${NC}"
        pause_enter
    fi
}

# ================= 主循环 =================
while true; do
    clear
    uu_state="${RED}[已停止/未安装]${NC}"
    mihomo_state="${RED}[已停止/未安装]${NC}"
    if command -v docker >/dev/null 2>&1; then
        if docker ps | grep -q uuplugin; then uu_state="${GREEN}[运行中]${NC}"; fi
        if docker exec uuplugin pgrep -f mihomo >/dev/null 2>&1; then mihomo_state="${GREEN}[运行中]${NC}"; fi
    fi
    MONITOR_STATUS=$(systemctl is-active uu-monitor >/dev/null 2>&1 && echo -e "${GREEN}[运行中]${NC}" || echo -e "${RED}[已停止]${NC}")

    echo -e "${CYAN}====================================================${NC}"
    echo -e "${CYAN}       *** UU 加速全能底座 中央管理面板 (v6.0) *** ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    echo -e "  【核心服务运行状态监控】"
    echo -e "   ▶ UU 主核: $uu_state   ▶ Mihomo分流: $mihomo_state"
    echo -e "   ▶ 智能看门狗 (路由/熔断): $MONITOR_STATUS"
    echo -e "${CYAN}====================================================${NC}"
    echo -e "  ${GREEN}1)${NC} [*] 1. UU 加速核心管理"
    echo -e "  ${GREEN}2)${NC} [~] 2. Mihomo 代理分流管理"
    echo -e "  ${GREEN}3)${NC} [@] 3. 端口转发与规则管理面板"
    echo -e "  ${YELLOW}4)${NC} [#] 4. 日志管理与监控看板"
    echo -e "  ${CYAN}5)${NC} [📦] 5. 备份还原 (迁移功能)"
    echo -e "  ${RED}6)${NC} [!] 一键重启所有服务 (重启)"
    echo -e "  ${RED}7)${NC} [!] 一键彻底清理系统 (卸载)"
    echo -e "  ${NC}0) [<] 退出面板"
    echo -e "${CYAN}====================================================${NC}"
    read -p "请输入选项 [0-7]: " main_opt

    case $main_opt in
        1) menu_uu ;;
        2) menu_mihomo ;;
        3) menu_port ;;
        4) menu_logs ;;
        5) menu_backup_restore ;;
        6) restart_all_services ;;
        7) menu_cleanup ;;
        0) clear; echo -e "${GREEN}已退出管理面板。${NC}"; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新输入。${NC}"; sleep 1 ;;
    esac
done
EOF_MANAGER_V7
)"

deploy_file "$BASE_DIR/scripts/proxy_manager.sh" "EOF_PROXY_V7" "755" "" "$(cat <<'EOF_PROXY_V7'
#!/bin/sh
# UU + mihomo(WARP) 端口转发引擎（TUN 捕获模式）
# 设计要点（满足用户两条硬约束）：
#   1) mihomo 的 WARP / 功能3 端口转发的出网 必须走 tun163/tun164（WG 设备）。
#   2) 只有功能3 转发规则里的「目标 IP」才被路由进 mihomo 的 TUN 捕获设备(mihomo0)，
#      经由 WARP163/164 的 tun163/tun164 出网；其余未设定转发规则的流量默认直连(br-lan)，不走 tun。
#
# 数据流：客户端 -> 192.168.6.248:LPORT  ->  PREROUTING/DNAT 改写到 目标IP:RPORT
#        -> 主表路由把 目标IP/32 送进 mihomo0(捕获) -> mihomo 按规则集选 WARP163/164
#        -> WARP163/164 经其 WG 设备 tun163/tun164 出网(源变 WARP IP，游戏服认)
#        -> 回包由 mihomo 有状态接管，经 mihomo0 正确送回客户端。

ACTION=$1
RULES_DB="/etc/uu_conf/forward_rules.conf"
MIHOMO_RULES_DIR="/etc/mihomo/rules"
MIHOMO_BIN="/etc/mihomo/mihomo"
CAP_DEV="mihomo0"          # mihomo TUN 捕获设备（与出网 WG 设备 tun163/164 分离）

# ---- [E3 修复] 并发锁：防止守护/面板/看门狗并发触发，导致 mihomo 被反复销毁重建 ----
# 现象：mihomo 曾 18 秒内重启 3 次、4 秒内 2 次（日志 7 次 Tun adapter listening），
#       并非崩溃（无 coredump、容器 RestartCount=0），而是多入口并发调用 ensure_mihomo force 重入。
# 设计要点（避免自锁）：父进程持锁后导出 UU_MIHOMO_LOCK_HELD=1，
#       子进程（如 restart_mihomo.sh 调用本脚本 reload）继承该标记，不再重复加锁。
#       flock 不存在时自动降级为不加锁，保证原有行为不变。
MIHOMO_LOCK="${MIHOMO_LOCK:-/var/lock/uu_mihomo.lock}"
acquire_lock(){
    [ "${UU_MIHOMO_LOCK_HELD:-}" = "1" ] && return 0
    command -v flock >/dev/null 2>&1 || return 0
    mkdir -p "$(dirname "$MIHOMO_LOCK")" 2>/dev/null
    exec 9>"$MIHOMO_LOCK" 2>/dev/null || return 0
    if ! flock -n 9 2>/dev/null; then
        echo "[proxy_manager] 已有实例正在执行，本次退出（避免并发重建 mihomo）" >&2
        exit 0
    fi
    UU_MIHOMO_LOCK_HELD=1
    export UU_MIHOMO_LOCK_HELD
}
acquire_lock

# ---- [P0-1] mihomo 日志参数（缺失时用默认值兜底）----
GUARD_CONF="${GUARD_CONF:-/etc/uu_conf/service_guard.conf}"
[ -f "$GUARD_CONF" ] && . "$GUARD_CONF"
MIHOMO_LOG="${MIHOMO_LOG:-/etc/uu_conf/mihomo.log}"
MIHOMO_LOG_MAX_KB="${MIHOMO_LOG_MAX_KB:-2048}"

# 日志轮转：超过上限则把当前日志挪为 .1，避免无限增长撑爆磁盘
rotate_mihomo_log(){
    _max="$MIHOMO_LOG_MAX_KB"
    case "$_max" in ''|*[!0-9]*) return 0 ;; esac
    [ "${_max:-0}" -gt 0 ] || return 0
    [ -f "$MIHOMO_LOG" ] || return 0
    _kb=$(du -k "$MIHOMO_LOG" 2>/dev/null | awk '{print $1}')
    case "${_kb:-}" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$_kb" -ge "$_max" ]; then
        mv "$MIHOMO_LOG" "$MIHOMO_LOG.1" 2>/dev/null && : > "$MIHOMO_LOG" 2>/dev/null
    fi
}

# ---- [P0-2] 域名解析（与 sync_mihomo_rules.sh 同一套逻辑）----
# 容器内 BusyBox 未编译 timeout/getent（实测 rc=127），原写法恒定失败，
# 实际一直靠 ping 兜底才出结果；解析失败时还会【静默不建 DNAT 规则】。
DNS_SERVERS="${DNS_SERVERS:-119.29.29.29 223.5.5.5 8.8.8.8}"
DNS_RESOLVE_RETRY="${DNS_RESOLVE_RETRY:-2}"
DNS_CACHE_FILE="${DNS_CACHE_FILE:-/etc/uu_conf/.dns_cache}"
resolve_ipv4(){
    _h="$1"; _try=0
    while [ "$_try" -le "$DNS_RESOLVE_RETRY" ]; do
        for _dns in $DNS_SERVERS; do
            _ip=$(nslookup "$_h" "$_dns" 2>/dev/null \
                  | awk '/^Address [0-9]+: /{print $3}' \
                  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
            if [ -n "$_ip" ]; then echo "$_ip"; return 0; fi
        done
        _ip=$(ping -c1 -W2 "$_h" 2>/dev/null | grep PING | awk -F'[()]' '{print $2}')
        case "$_ip" in
            ''|*[!0-9.]*) : ;;
            *) echo "$_ip"; return 0 ;;
        esac
        _try=$((_try+1))
        [ "$_try" -le "$DNS_RESOLVE_RETRY" ] && sleep 1
    done
    return 1
}
cache_get(){
    [ -f "$DNS_CACHE_FILE" ] || return 1
    grep "^$1 " "$DNS_CACHE_FILE" 2>/dev/null | head -n1 | awk '{print $2}'
}
cache_put(){
    _k="$1"; _v="$2"; _t=$(mktemp 2>/dev/null) || return 0
    grep -v "^$_k " "$DNS_CACHE_FILE" 2>/dev/null > "$_t"
    printf '%s %s\n' "$_k" "$_v" >> "$_t"
    mv "$_t" "$DNS_CACHE_FILE" 2>/dev/null || rm -f "$_t"
}

# [加固] 原实现在规则库缺失时静默 exit 0：转发会悄无声息地整体消失且无任何报错。
# 改为自动创建空规则库并继续，保证 DNAT 链与 mihomo 规则集仍被正确建立。
if [ ! -f "$RULES_DB" ]; then
    echo "[proxy_manager] 警告: 规则库 $RULES_DB 不存在，已自动创建空规则库"
    mkdir -p "$(dirname "$RULES_DB")" 2>/dev/null || true
    printf '# 格式: 目标IP或域名:本地监听端口:目标端口:绑定的网卡(可选)\n' > "$RULES_DB"
fi

# 入站 LAN 网卡：客户端在此连接「本地监听端口」。tun163/164 只负责出网，绝不当入站接口。
DETECT_LAN_IF() {
    if ip link show br-lan >/dev/null 2>&1; then echo "br-lan"; return; fi
    _d=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ -n "$_d" ] && { echo "$_d"; return; }
    ip -o link show up 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}'
}

# 确保 mihomo(TUN 捕获)已就绪，且全局唯一（绝不允许多实例争抢 tun163/164、mihomo0）。
# 使用 ( ... & ) 让 mihomo 脱离当前 shell 存活（docker exec 会话结束也不被杀）。
ensure_mihomo() {
    _force="$1"
    _n=$(ps w 2>/dev/null | grep "$MIHOMO_BIN" | grep -v grep | wc -l)
    # 非强制 且 已单实例 + 捕获设备在线 -> 直接复用，避免无谓重启
    if [ "$_force" != "force" ] && [ "$_n" -eq 1 ] && ip link show "$CAP_DEV" >/dev/null 2>&1; then
        return 0
    fi
    # 强制重载 / 多实例 / 捕获设备未就绪 -> 清掉全部残留，启动唯一实例
    for p in $(ps w 2>/dev/null | grep "$MIHOMO_BIN" | grep -v grep | awk '{print $1}'); do
        kill -9 "$p" 2>/dev/null
    done
    # [fix] 必须等旧进程与旧捕获设备【彻底消失】再启动：
    # 否则就绪判定会拿"即将被销毁的旧 mihomo0"当成功，随后下发的 /32 路由随旧设备一起丢失。
    i=0
    while [ $i -lt 15 ]; do
        ps w 2>/dev/null | grep -q "[/]etc/mihomo/mihomo" || break
        sleep 1; i=$((i+1))
    done
    i=0
    while [ $i -lt 15 ]; do
        ip link show "$CAP_DEV" >/dev/null 2>&1 || break
        sleep 1; i=$((i+1))
    done
    # [P0-1 修复] 原为 >/dev/null 2>&1 —— mihomo 的全部输出被显式丢弃，
    # 导致 /etc/uu_conf/mihomo.log 长期停留在旧时间戳、排障完全失去依据。
    # 注意：mihomo 的 -d 是【配置目录】参数，不是守护化标志，故此处无需改动 -d。
    # 改为追加写入可配置日志文件；> 会清空历史，用 >> 保留轮转前的内容。
    rotate_mihomo_log
    # [WARP 自愈] exec 9>&- 关闭继承自 acquire_lock 的锁 fd，避免 mihomo 长期持有
    # /var/lock/uu_mihomo.lock（/var/lock 实际是 /tmp/lock 的软链），导致后续
    # restart_mihomo / proxy_manager 永远被 flock 阻塞、自愈无法触发。
    ( exec 9>&-; "$MIHOMO_BIN" -d /etc/mihomo >>"$MIHOMO_LOG" 2>&1 & )
    i=0
    while [ $i -lt 30 ]; do
        [ "$(ps w 2>/dev/null | grep "$MIHOMO_BIN" | grep -v grep | wc -l)" -eq 1 ] && \
            ip link show "$CAP_DEV" >/dev/null 2>&1 && return 0
        sleep 1; i=$((i+1))
    done
    return 1
}

# 把转发目标 RIP 路由进 mihomo 的 TUN 捕获设备（mihomo 据此有状态代理出网）。
add_route_network_aware() {
    _rip="$1"
    _cap="$2"
    ip link show "$_cap" >/dev/null 2>&1 || return 0   # 捕获设备未起则跳过，待 ensure_mihomo 后补
    if echo "$(ip route get "$_rip" 2>/dev/null | head -n1)" | grep -q "dev $_cap"; then
        return 0
    fi
    ip route replace "$_rip" dev "$_cap" metric 1 2>/dev/null && return 0
    return 1
}

case $ACTION in
    reload)
        # 清理旧的转发路由（仅清理我们下发到捕获设备的 /32）
        ip route show dev "$CAP_DEV" 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | while read -r rip; do
            ip route del "$rip" dev "$CAP_DEV" 2>/dev/null || true
        done

        # 入站 DNAT 链
        iptables -t nat -N UU_PORT_FWD 2>/dev/null || iptables -t nat -F UU_PORT_FWD
        iptables -t nat -D PREROUTING -j UU_PORT_FWD 2>/dev/null
        iptables -t nat -I PREROUTING 1 -j UU_PORT_FWD

        LAN_IF=$(DETECT_LAN_IF)
        [ -z "$LAN_IF" ] && LAN_IF="br-lan"

        count=0
        TMP_HOSTS=$(mktemp)
        RIPS_LIST=""

        if [ -s "$RULES_DB" ]; then
            while read -r line; do
                case "$line" in \#*) continue ;; "") continue ;; esac
                THOST=$(echo "$line" | cut -d':' -f1)
                LPORT=$(echo "$line" | cut -d':' -f2)
                RPORT=$(echo "$line" | cut -d':' -f3)
                TUN_IFACE=$(echo "$line" | cut -d':' -f4)
                RPORT=${RPORT:-$LPORT}
                [ -z "$TUN_IFACE" ] && TUN_IFACE="tun163"

                echo "$THOST" >> "$TMP_HOSTS"

                if echo "$THOST" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
                    RIP="$THOST"
                else
                    # [P0-2] 主路径改为 nslookup（容器内可用），失败回退缓存并告警
                    RIP=$(resolve_ipv4 "$THOST" || true)
                    if [ -n "$RIP" ]; then
                        cache_put "$THOST" "$RIP"
                    else
                        RIP=$(cache_get "$THOST" || true)
                        [ -n "$RIP" ] && echo "[proxy_manager] WARN 解析失败，沿用缓存: $THOST -> $RIP" >&2
                    fi
                fi

                if [ -n "$RIP" ]; then
                    # 入站 DNAT：捕获从 LAN 网卡进入、目的端口为 LPORT 的流量，改写到 RIP:RPORT
                    iptables -t nat -A UU_PORT_FWD -i "$LAN_IF" -p tcp --dport "$LPORT" -j DNAT --to-destination "$RIP:$RPORT"
                    iptables -t nat -A UU_PORT_FWD -i "$LAN_IF" -p udp --dport "$LPORT" -j DNAT --to-destination "$RIP:$RPORT"

                    RIPS_LIST="$RIPS_LIST $RIP"

                    count=$((count + 1))
                else
                    echo "[proxy_manager] FAIL 目标无法解析且无缓存，未创建 DNAT: $line" >&2
                fi
            done < "$RULES_DB"
        fi

        rm -f "$TMP_HOSTS"

        # 同步 mihomo 规则 YAML（结构校验 + 备份 + 原子写入）；失败则中止本次 reload
        /bin/sh /etc/scripts/sync_mihomo_rules.sh || {
            echo "⚠️ 规则 YAML 同步校验失败，终止本次 reload（线上文件未改动）" >&2
            exit 1
        }

        # 强制重载 mihomo（加载新 provider），保证单实例 + 捕获设备在线
        ensure_mihomo force || {
            echo "⚠️ mihomo 未就绪，回滚规则 YAML 并重载" >&2
            for _f in fwd_warp163.yaml fwd_warp164.yaml; do
                _b=$(ls -t "$MIHOMO_RULES_DIR/$_f.bak."* 2>/dev/null | head -n1)
                [ -n "$_b" ] && mv "$_b" "$MIHOMO_RULES_DIR/$_f"
            done
            ensure_mihomo force
        }

        # 下发目标捕获路由（仅转发目标进 mihomo0 -> WARP -> tun163/164）
        for RIP in $RIPS_LIST; do
            add_route_network_aware "$RIP" "$CAP_DEV" || \
                echo "⚠️ 无法为 $RIP 建立捕获路由，转发可能失败" >&2
        done

        echo "✅ 容器内端口转发引擎重载完成！共解析生效 ${count} 条策略（捕获设备 ${CAP_DEV}）。"
        ;;

    list)
        if grep -vE "^#|^$" "$RULES_DB" >/dev/null 2>&1; then
            echo "--- 当前已保存并生效的转发规则 ---"
            while read -r line; do
                case "$line" in \#*) continue ;; "") continue ;; esac
                THOST=$(echo "$line" | cut -d':' -f1)
                LPORT=$(echo "$line" | cut -d':' -f2)
                RPORT=$(echo "$line" | cut -d':' -f3)
                TUN_IFACE=$(echo "$line" | cut -d':' -f4)
                RPORT=${RPORT:-$LPORT}
                if echo "$THOST" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
                    RIP="$THOST"
                else
                    RIP=$(resolve_ipv4 "$THOST" || true)
                    [ -z "$RIP" ] && RIP=$(cache_get "$THOST" || true)
                fi
                printf " ▶ 监听: %s -> 目标: %s (解析IP: %s:%s) (网卡强绑: %s)\n" "$LPORT" "$THOST" "${RIP:-解析失败}" "$RPORT" "${TUN_IFACE:-自动}"
            done < "$RULES_DB"
        else
            echo "暂无任何端口转发规则。"
        fi
        ;;
esac
EOF_PROXY_V7
)"

deploy_file "$BASE_DIR/scripts/restart_mihomo.sh" "EOF_RESTART_V7" "755" "" "$(cat <<'EOF_RESTART_V7'
#!/bin/sh
# 安全重启容器内的 mihomo（供 UU 面板 "重启 Mihomo" 调用）
# 原实现缺陷：manager.sh 用双引号把 $(ps w ...) 拼进 docker exec sh -c "..."，
# 命令替换在【宿主】先展开 -> 容器里根本没杀掉 mihomo -> 新实例抢不到 9090
# -> 面板 :9090/ui 打不开；且用宿主 PID 在容器内 kill 会误杀无关进程。

MIHOMO_BIN="/etc/mihomo/mihomo"
LOG="/etc/uu_conf/mihomo.log"
CAP_DEV="mihomo0"

# ---- [P0-1/P2-6] 稳定性加固参数（缺失时用默认值兜底）----
GUARD_CONF="${GUARD_CONF:-/etc/uu_conf/service_guard.conf}"
[ -f "$GUARD_CONF" ] && . "$GUARD_CONF"
MIHOMO_LOG="${MIHOMO_LOG:-$LOG}"
TUN_WAIT_TIMEOUT_SEC="${TUN_WAIT_TIMEOUT_SEC:-60}"
TUN_WAIT_INTERVAL_SEC="${TUN_WAIT_INTERVAL_SEC:-2}"
TUN_WAIT_RETRY="${TUN_WAIT_RETRY:-3}"
TUN_WAIT_STRICT="${TUN_WAIT_STRICT:-0}"

# [P2-6] 等待 UU 隧道就绪后再启动 mihomo。
# 背景：tun163/tun164 由 UU 在加速会话激活时才创建。若 mihomo 先启动，
# 其 WG 外层套接字按 interface-name 绑定会失败并缓存 ENODEV（stale bind），
# 此后即使隧道出现也不自愈 —— 表现为 WARP 长期 alive:false。
wait_for_tun(){
    _elapsed=0
    while [ "$_elapsed" -lt "$TUN_WAIT_TIMEOUT_SEC" ]; do
        if ip link show tun163 >/dev/null 2>&1 && ip link show tun164 >/dev/null 2>&1; then
            return 0
        fi
        sleep "$TUN_WAIT_INTERVAL_SEC"
        _elapsed=$((_elapsed + TUN_WAIT_INTERVAL_SEC))
    done
    return 1
}

# ---- [E3 修复] 并发锁（与 proxy_manager.sh 共用 /var/lock/uu_mihomo.lock）----
# 避免 panel / service_guard / 本脚本多入口并发导致 mihomo 与 mihomo0 被反复销毁重建。
# 子进程若由已持锁的父进程调起（UU_MIHOMO_LOCK_HELD=1）则继承标记、不再重复加锁。
MIHOMO_LOCK="${MIHOMO_LOCK:-/var/lock/uu_mihomo.lock}"
acquire_lock(){
    [ "${UU_MIHOMO_LOCK_HELD:-}" = "1" ] && return 0
    command -v flock >/dev/null 2>&1 || return 0
    mkdir -p "$(dirname "$MIHOMO_LOCK")" 2>/dev/null
    exec 9>"$MIHOMO_LOCK" 2>/dev/null || return 0
    if ! flock -n 9 2>/dev/null; then
        echo "[restart_mihomo] 已有实例正在执行，本次退出（避免并发重建 mihomo）"
        exit 0
    fi
    UU_MIHOMO_LOCK_HELD=1
    export UU_MIHOMO_LOCK_HELD
}
acquire_lock

echo "[restart_mihomo] 1/5 停止已有 mihomo 进程..."
for p in $(ps w 2>/dev/null | grep "$MIHOMO_BIN" | grep -v grep | awk '{print $1}'); do
    kill -9 "$p" 2>/dev/null
done

echo "[restart_mihomo] 2/5 等待进程退出与 9090 释放..."
i=0
while [ $i -lt 15 ]; do
    ps w 2>/dev/null | grep -q "[/]etc/mihomo/mihomo" || break
    sleep 1
    i=$((i+1))
done
sleep 1

# [P2-6] 等待隧道就绪（可配置超时 + 重试轮数）
echo "[restart_mihomo] 2.5/5 等待 UU 隧道 tun163/tun164 就绪（超时 ${TUN_WAIT_TIMEOUT_SEC}s × ${TUN_WAIT_RETRY} 轮）..."
_try=0
_tun_ready=1
while [ "$_try" -lt "$TUN_WAIT_RETRY" ]; do
    if wait_for_tun; then _tun_ready=0; break; fi
    _try=$((_try+1))
    echo "[restart_mihomo]   第 $_try 轮等待超时（已等 ${TUN_WAIT_TIMEOUT_SEC}s）"
done
if [ "$_tun_ready" -ne 0 ]; then
    if [ "$TUN_WAIT_STRICT" = "1" ]; then
        echo "[restart_mihomo] 中止：隧道始终未就绪（TUN_WAIT_STRICT=1），避免 stale bind"
        exit 1
    fi
    echo "[restart_mihomo] 警告: 隧道未就绪，仍继续启动（TUN_WAIT_STRICT=0）。若 WARP 报 no such device，请待加速会话生效后重试。"
else
    echo "[restart_mihomo]   隧道已就绪"
fi

echo "[restart_mihomo] 3/5 启动 mihomo..."
# 用 ( ... & ) 双层脱离：mihomo 自身 -d 会守护化，但若 exec 会话回收过快仍可能被信号带走，
# 子 shell + 后台可确保进程被 init(PID 1) 收养，docker exec 退出后依旧存活。
# [P0-1] 改为追加写入（原为覆盖），与 proxy_manager.sh 的日志路径保持一致。
# [WARP 自愈] exec 9>&- 关闭继承自 acquire_lock 的锁 fd，避免 mihomo 长期持有
# /var/lock/uu_mihomo.lock（/var/lock 实际是 /tmp/lock 的软链），导致后续
# restart_mihomo / proxy_manager 永远被 flock 阻塞、自愈无法触发。
( exec 9>&-; "$MIHOMO_BIN" -d /etc/mihomo >>"$MIHOMO_LOG" 2>&1 & )

echo "[restart_mihomo] 4/5 等待捕获设备 $CAP_DEV 就绪..."
i=0
while [ $i -lt 25 ]; do
    ip link show "$CAP_DEV" >/dev/null 2>&1 && break
    sleep 1
    i=$((i+1))
done

echo "[restart_mihomo] 5/5 重载转发引擎（重建 mihomo0 捕获路由 + 同步 mihomo 规则集）..."
sh /etc/scripts/proxy_manager.sh reload >/dev/null 2>&1

# UU 隧道策略路由（幂等：先查后插，避免反复重启导致 rule/route 无限堆叠）
for tun in $(ip link show 2>/dev/null | grep -oE 'tun[0-9]+' | sort -u); do
    num=$(echo "$tun" | grep -oE '[0-9]+')
    tip=$(ip -4 addr show "$tun" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    if [ -n "$tip" ]; then
        ip route show table "$num" 2>/dev/null | grep -q "^default " || \
            ip route add default dev "$tun" table "$num" 2>/dev/null
        ip rule show 2>/dev/null | grep -q "from $tip lookup $num" || \
            ip rule add from "$tip" table "$num" 2>/dev/null
        # [加固] 清理历史重复项：旧版非幂等实现每次重启都插一条，已实测堆积到 43 条。
        # 这里保留第一条、删除其余（功能完全等价），使 ip rule 列表收敛到每个隧道 1 条。
        _dup=$(ip rule show 2>/dev/null | grep -c "from $tip lookup $num")
        while [ "${_dup:-0}" -gt 1 ]; do
            ip rule del from "$tip" table "$num" 2>/dev/null || break
            _dup=$(ip rule show 2>/dev/null | grep -c "from $tip lookup $num")
        done
    fi
done

echo "[restart_mihomo] 完成. mihomo 进程数=$(ps w 2>/dev/null | grep -c '[/]etc/mihomo/mihomo')"
EOF_RESTART_V7
)"

deploy_file "$BASE_DIR/scripts/sync_mihomo_rules.sh" "EOF_SYNC_V7" "644" "" "$(cat <<'EOF_SYNC_V7'
#!/bin/sh
# 同步 forward_rules.conf -> mihomo 规则提供 YAML (fwd_warp163.yaml / fwd_warp164.yaml)
#  + 【端口感知】生成 AND,((IP-CIDR,<ip>/32),(DST-PORT,<port>)),WARPxxx 并注入 config.yaml
#
# 触发时机：由 proxy_manager.sh reload（面板保存规则时调用）或本脚本被直接调用。
# 职责：
#   1) 全量重建两个 provider 文件（杜绝旧条目残留，保证与 forward_rules.conf 一致）；
#   2) 【端口感知改造】为每条规则生成 (IP,端口) 精确绑定的 AND 规则，置于规则集之前。
#      目的：规则集只有 IP-CIDR 维度、无端口维度，若同一 IP 出现两条不同 tun 的规则，
#      先出现的规则集会抢走全部流量（曾致 akilela:63146 错走 WARP163）。
#      端口感知规则按 (IP,目标端口) 精确命中，彻底消除此类静默错路。
#   3) 冲突检测：同一 IP 被分配到不同 WARP 时显式告警（不再静默）。
#   4) 结构校验（容器无 python，用 shell 校验 payload: 头 + 每行 IP-CIDR 模式）；
#   5) 写入前备份旧文件（.bak.<ts>）；同文件系统内 mv 原子写入（要么全生效，要么不变）。
# 不负责 mihomo 重载（由调用方 ensure_mihomo force 处理），故本脚本失败绝不留半成品。
set -u

RULES_DB="/etc/uu_conf/forward_rules.conf"
DIR="/etc/mihomo/rules"
CFG="/etc/mihomo/config.yaml"
TS=$(date +%Y%m%d%H%M%S)
# config.yaml 备份保留份数（仅保留最新 N 份，可用环境变量覆盖：KEEP_CONFIG_BACKUPS=5 ...）
KEEP_CONFIG_BACKUPS="${KEEP_CONFIG_BACKUPS:-3}"
# 豁免标记：备份文件名包含该标记时永不删除（如手工加 config.yaml.bak.20260101000000.keep）
BACKUP_KEEP_MARKER="${BACKUP_KEEP_MARKER:-.keep}"
BEGIN_MARK='# >>> FWD_PORT_AWARE_BEGIN (generated by sync_mihomo_rules.sh, DO NOT EDIT)'
END_MARK='# <<< FWD_PORT_AWARE_END'
log(){ echo "[sync-mihomo] $*"; }

# ---- [P0-2] 稳定性加固参数（缺失时脚本内默认值兜底）----
GUARD_CONF="${GUARD_CONF:-/etc/uu_conf/service_guard.conf}"
[ -f "$GUARD_CONF" ] && . "$GUARD_CONF"
DNS_SERVERS="${DNS_SERVERS:-119.29.29.29 223.5.5.5 8.8.8.8}"
DNS_RESOLVE_RETRY="${DNS_RESOLVE_RETRY:-2}"
DNS_CACHE_FILE="${DNS_CACHE_FILE:-/etc/uu_conf/.dns_cache}"

# 域名解析：nslookup 主路径 -> ping 兜底。
# 【为什么不用 getent/timeout】容器内 BusyBox 未编译 timeout/getent（实测 rc=127），
# 原实现 `timeout 2 getent ahostsv4` 恒定失败，实际一直靠 ping 兜底才出结果。
resolve_ipv4(){
    _h="$1"; _try=0
    while [ "$_try" -le "$DNS_RESOLVE_RETRY" ]; do
        for _dns in $DNS_SERVERS; do
            _ip=$(nslookup "$_h" "$_dns" 2>/dev/null \
                  | awk '/^Address [0-9]+: /{print $3}' \
                  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
            if [ -n "$_ip" ]; then echo "$_ip"; return 0; fi
        done
        _ip=$(ping -c1 -W2 "$_h" 2>/dev/null | grep PING | awk -F'[()]' '{print $2}')
        case "$_ip" in
            ''|*[!0-9.]*) : ;;
            *) echo "$_ip"; return 0 ;;
        esac
        _try=$((_try+1))
        [ "$_try" -le "$DNS_RESOLVE_RETRY" ] && sleep 1
    done
    return 1
}
cache_get(){
    [ -f "$DNS_CACHE_FILE" ] || return 1
    grep "^$1 " "$DNS_CACHE_FILE" 2>/dev/null | head -n1 | awk '{print $2}'
}
cache_put(){
    _k="$1"; _v="$2"; _t=$(mktemp 2>/dev/null) || return 0
    grep -v "^$_k " "$DNS_CACHE_FILE" 2>/dev/null > "$_t"
    printf '%s %s\n' "$_k" "$_v" >> "$_t"
    mv "$_t" "$DNS_CACHE_FILE" 2>/dev/null || rm -f "$_t"
}

[ -f "$RULES_DB" ] || { log "无规则库，跳过"; exit 0; }
mkdir -p "$DIR"

T163=$(mktemp); T164=$(mktemp)
PA=$(mktemp)          # 端口感知规则块（不含标记行）
SEEN=$(mktemp)        # 冲突检测：RIP<空格>WARP
printf 'payload:\n' > "$T163"
printf 'payload:\n' > "$T164"
: > "$PA"
: > "$SEEN"

# 解析规则 -> 按隧道分桶写入 IP-CIDR 条目，并生成端口感知 AND 规则
if [ -s "$RULES_DB" ]; then
    while read -r line; do
        case "$line" in \#*|"") continue ;; esac
        THOST=$(echo "$line" | cut -d: -f1)
        LPORT=$(echo "$line" | cut -d: -f2)
        RPORT=$(echo "$line" | cut -d: -f3)
        TUN=$(echo "$line" | cut -d: -f4); [ -z "$TUN" ] && TUN=tun163
        [ -z "$RPORT" ] && RPORT="$LPORT"

        if echo "$THOST" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            RIP="$THOST"
        else
            # [P0-2] 解析失败不再静默跳过：先重试，失败则回退上次成功结果并告警，
            #        仍无结果才跳过（并明确记录原因与影响的端口）。
            RIP=$(resolve_ipv4 "$THOST" || true)
            if [ -n "$RIP" ]; then
                cache_put "$THOST" "$RIP"
            else
                RIP=$(cache_get "$THOST" || true)
                if [ -n "$RIP" ]; then
                    log "WARN 解析失败，沿用上次成功结果: $THOST -> $RIP（缓存兜底）"
                else
                    log "FAIL 解析失败且无缓存，跳过该规则: $line（影响本地端口 ${LPORT:-?}）"
                    continue
                fi
            fi
        fi

        case "$TUN" in
            tun164) WARP=WARP164; printf '  - IP-CIDR,%s/32\n' "$RIP" >> "$T164" ;;
            *)      WARP=WARP163; printf '  - IP-CIDR,%s/32\n' "$RIP" >> "$T163" ;;
        esac

        # 端口感知规则（决定性，注入到规则集之前）
        printf '  - AND,((IP-CIDR,%s/32),(DST-PORT,%s)),%s\n' "$RIP" "$RPORT" "$WARP" >> "$PA"
        echo "$RIP $WARP" >> "$SEEN"
    done < "$RULES_DB"
fi

# ---- 去重：同一 IP 的多条规则（如 akilela 63145/63146）会产生重复 IP-CIDR 条目 ----
for _f in "$T163" "$T164"; do
    _h=$(head -n1 "$_f")
    _u=$(tail -n +2 "$_f" | grep -v '^$' | sort -u)
    _t=$(mktemp)
    printf '%s\n%s\n' "$_h" "$_u" > "$_t"
    mv "$_t" "$_f"
done

# ---- 冲突检测：同一 IP 被分配到多个不同 WARP ----
_dups=$(cut -d' ' -f1 "$SEEN" | sort | uniq -d)
for _d in $_dups; do
    _ws=$(grep "^$_d " "$SEEN" | cut -d' ' -f2 | sort -u | tr '\n' ',')
    case "$_ws" in
        *,*,*) log "⚠️ 注意: $_d 被分配到多个出口($_ws)。端口感知规则已按各自端口精确命中，不再互相抢；若无端口感知则会错路。" ;;
    esac
done

# ---- 结构校验：首行必须为 payload:；其余非空行必须命中 IP-CIDR 模式 ----
validate(){
    _f="$1"
    head -n1 "$_f" | grep -qxF 'payload:' || return 1
    _bad=$(awk 'NR>1 && $0!="" && $0 !~ /^  - IP-CIDR,[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ {print}' "$_f")
    [ -n "$_bad" ] && return 1
    return 0
}
if ! validate "$T163" || ! validate "$T164"; then
    log "YAML 结构校验失败，中止写入（线上文件保持不变）"
    rm -f "$T163" "$T164" "$PA" "$SEEN"
    exit 1
fi

# ---- 备份当前线上文件（便于回滚）----
for _f in fwd_warp163.yaml fwd_warp164.yaml; do
    [ -f "$DIR/$_f" ] && cp -p "$DIR/$_f" "$DIR/$_f.bak.$TS"
done

# ---- 原子写入规则集（同 fs mv 原子，避免半截文件）----
mv "$T163" "$DIR/fwd_warp163.yaml"
mv "$T164" "$DIR/fwd_warp164.yaml"
log "已写入 fwd_warp163.yaml / fwd_warp164.yaml（备份前缀 .bak.$TS）"

# ---- config.yaml 备份清理：仅保留最新 N 份（N = KEEP_CONFIG_BACKUPS）----
# 设计约束：
#   · 严格限定匹配范围：只处理 config.yaml 的备份（两种历史命名都覆盖），
#     绝不触碰其它 .yaml（如 rules/fwd_warp163.yaml）或其它 .bak 文件；
#   · 按文件名中的时间戳排序（YYYYMMDDHHMMSS 等宽，字典序即时间序），删除最旧的若干份；
#   · 边界：目录不存在 / 无备份 / 备份数 ≤ N 时直接跳过；文件名含空格也安全（逐行读取）；
#   · 删除失败只提示，不中断主流程。
prune_config_backups() {
    _pdir="$1"
    _keep="${KEEP_CONFIG_BACKUPS:-3}"
    _mark="${BACKUP_KEEP_MARKER:-.keep}"
    # 合法性校验：非纯数字或小于 1 时回退为 3，避免误删全部备份
    case "$_keep" in
        ''|*[!0-9]*) _keep=3 ;;
    esac
    [ "${_keep:-0}" -ge 1 ] 2>/dev/null || _keep=3

    [ -d "$_pdir" ] || { log "备份清理：目录不存在，跳过（$_pdir）"; return 0; }

    # 严格匹配：仅 config.yaml 的备份（当前命名 config.yaml.bak.<ts>；兼容旧命名 config.yaml.<ts>.bak）
    _list=$(
        ls -1 "$_pdir" 2>/dev/null | while IFS= read -r _n; do
            case "$_n" in
                config.yaml.bak.*|config.yaml.*.bak)
                    # 豁免：带保留标记的备份永不删除，也不占用保留名额
                    case "$_n" in *"$_mark"*) continue ;; esac
                    printf '%s\n' "$_n" ;;
            esac
        done | sort
    )
    _exempt=$(ls -1 "$_pdir" 2>/dev/null | grep -c -- "$_mark" || true)
    [ "${_exempt:-0}" -gt 0 ] 2>/dev/null && log "备份清理：${_exempt} 份带豁免标记（$_mark），已跳过"
    [ -n "$_list" ] || { log "备份清理：无可清理的 config.yaml 备份，跳过"; return 0; }

    _total=$(printf '%s\n' "$_list" | wc -l | tr -d ' ')
    _total=$((_total + 0))
    if [ "$_total" -le "$_keep" ]; then
        log "备份清理：现有 ${_total} 份 ≤ 保留 ${_keep} 份，无需清理"
        return 0
    fi

    _del=$((_total - _keep))
    log "备份清理：现有 ${_total} 份，保留最新 ${_keep} 份，删除最旧的 ${_del} 份"
    printf '%s\n' "$_list" | head -n "$_del" | while IFS= read -r _old; do
        [ -n "$_old" ] || continue
        if rm -f "$_pdir/$_old" 2>/dev/null; then
            log "  已删除旧备份: $_old"
        else
            log "  ⚠️ 删除失败（已跳过，不影响主流程）: $_old"
        fi
    done
    return 0
}

# ---- 注入端口感知规则块到 config.yaml ----
if [ -s "$PA" ] && [ -f "$CFG" ]; then
    CFGBAK="$CFG.bak.$TS"
    cp -p "$CFG" "$CFGBAK" 2>/dev/null || { log "config.yaml 备份失败，跳过注入"; rm -f "$PA" "$SEEN"; exit 0; }
    # 备份创建成功后立即清理，仅保留最新 KEEP_CONFIG_BACKUPS 份
    prune_config_backups "$(dirname "$CFG")"
    HEAD=$(mktemp); TAILF=$(mktemp); NEWCFG=$(mktemp)
    # 幂等切分：head = BEGIN 之前（不含 BEGIN）；tail = END 之后（不含 END）
    # 不可用 '1,/BEGIN/p' + '/END/,$p'，那会把标记本身留在 head/tail 里导致每次 sync 重复叠加。
    if grep -q 'FWD_PORT_AWARE_BEGIN' "$CFG"; then
        sed '/FWD_PORT_AWARE_BEGIN/,$d' "$CFG" > "$HEAD"
        sed '1,/FWD_PORT_AWARE_END/d'   "$CFG" > "$TAILF"
    else
        _ln=$(grep -n 'RULE-SET,fwd_warp163' "$CFG" | head -n1 | cut -d: -f1)
        if [ -n "$_ln" ]; then
            head -n $((_ln - 1)) "$CFG" > "$HEAD"
            tail -n +"$_ln"      "$CFG" > "$TAILF"
        else
            cat "$CFG" > "$HEAD"
            : > "$TAILF"
        fi
    fi
    # 再兜底清一遍残留标记行（清理历史重复叠加，保证幂等收敛）
    H2=$(mktemp); T2=$(mktemp)
    grep -v -e 'FWD_PORT_AWARE_BEGIN' -e 'FWD_PORT_AWARE_END' "$HEAD"  > "$H2"
    grep -v -e 'FWD_PORT_AWARE_BEGIN' -e 'FWD_PORT_AWARE_END' "$TAILF" > "$T2"
    {
        cat "$H2"
        printf '%s\n' "$BEGIN_MARK"
        cat "$PA"
        printf '%s\n' "$END_MARK"
        cat "$T2"
    } > "$NEWCFG"
    rm -f "$H2" "$T2"
    # 基本健全性检查：非空且仍含 rules: 段
    if [ -s "$NEWCFG" ] && grep -q '^rules:' "$NEWCFG"; then
        mv "$NEWCFG" "$CFG"
        log "已注入端口感知规则块到 config.yaml（备份 $CFGBAK）"
    else
        log "⚠️ 生成的 config.yaml 未通过健全性检查，已放弃注入（原文件不变）"
        rm -f "$NEWCFG"
    fi
    rm -f "$HEAD" "$TAILF"
fi

rm -f "$PA" "$SEEN"
exit 0
EOF_SYNC_V7
)"

# [稳定性加固] 守护脚本：dnsmasq 存活守护 / WARP alive 恢复即刷新 / 域名定期重解析
deploy_file "$BASE_DIR/scripts/service_guard.sh" "EOF_GUARD_V121" "755" "" "$(cat <<'EOF_GUARD_V121'
#!/bin/sh
# ============================================================
# 稳定性守护（单一常驻进程，覆盖 P1-3 / P1-4 / P0-2 的定期部分）
#   P1-3 dnsmasq 存活守护：进程异常退出自动拉起，记录重启次数与事件日志
#   P1-4 WARP alive 恢复刷新：周期性 delay 探针；状态由异常转可用立即触发刷新
#   P0-2 域名定期重解析：按可配置间隔刷新 DNS；变化才重载；失败保留上次结果并告警
#
# 用法：
#   sh service_guard.sh ensure   # 幂等拉起（未运行才启动）— 供 firewall.user / 开机调用
#   sh service_guard.sh daemon   # 前台运行主循环（由 ensure 调用，勿手动）
#   sh service_guard.sh restart  # 先停再起
#   sh service_guard.sh stop
#   sh service_guard.sh once     # 只执行一次检查，不常驻（验收用）
#   sh service_guard.sh status
#
# 兼容性：BusyBox sh；容器内【无】timeout/getent/dig/curl，故解析只用 nslookup + ping 兜底。
# ============================================================
set -u

GUARD_CONF="${GUARD_CONF:-/etc/uu_conf/service_guard.conf}"
[ -f "$GUARD_CONF" ] && . "$GUARD_CONF"

RULES_DB="${RULES_DB:-/etc/uu_conf/forward_rules.conf}"
SYNC="${SYNC:-/etc/scripts/sync_mihomo_rules.sh}"
ENGINE="${ENGINE:-/etc/scripts/proxy_manager.sh}"
GUARD_LOG="${GUARD_LOG:-/etc/uu_conf/service_guard.log}"
GUARD_LOG_MAX_KB="${GUARD_LOG_MAX_KB:-1024}"
PIDFILE="${PIDFILE:-/var/run/service_guard.pid}"
STATEDIR="${STATEDIR:-/var/run}"
GUARD_LOOP_INTERVAL_SEC="${GUARD_LOOP_INTERVAL_SEC:-10}"

DNS_SERVERS="${DNS_SERVERS:-119.29.29.29 223.5.5.5 8.8.8.8}"
DNS_RESOLVE_RETRY="${DNS_RESOLVE_RETRY:-2}"
DNS_CACHE_FILE="${DNS_CACHE_FILE:-/etc/uu_conf/.dns_cache}"
DNS_REFRESH_INTERVAL_SEC="${DNS_REFRESH_INTERVAL_SEC:-300}"
DNS_REFRESH_ENABLED="${DNS_REFRESH_ENABLED:-1}"

DNSMASQ_GUARD_ENABLED="${DNSMASQ_GUARD_ENABLED:-1}"
DNSMASQ_GUARD_INTERVAL_SEC="${DNSMASQ_GUARD_INTERVAL_SEC:-30}"

WARP_WATCH_ENABLED="${WARP_WATCH_ENABLED:-1}"
WARP_WATCH_INTERVAL_SEC="${WARP_WATCH_INTERVAL_SEC:-60}"
WARP_WATCH_TIMEOUT_MS="${WARP_WATCH_TIMEOUT_MS:-8000}"
WARP_REFRESH_ON_RECOVER="${WARP_REFRESH_ON_RECOVER:-1}"
WARP_REFRESH_CMD="${WARP_REFRESH_CMD:-/etc/scripts/proxy_manager.sh reload}"
WARP_NODES="${WARP_NODES:-WARP163 WARP164}"

# ---- mihomo 存活看护（R1 验收暴露：mihomo 被 kill 后无任何组件负责拉起）----
MIHOMO_GUARD_ENABLED="${MIHOMO_GUARD_ENABLED:-1}"
MIHOMO_GUARD_INTERVAL_SEC="${MIHOMO_GUARD_INTERVAL_SEC:-30}"
MIHOMO_RESTART_CMD="${MIHOMO_RESTART_CMD:-/etc/scripts/restart_mihomo.sh}"
MIHOMO_RESTART_WAIT_SEC="${MIHOMO_RESTART_WAIT_SEC:-8}"

DNSMASQ_RESTART_COUNT=0
MIHOMO_RESTART_COUNT=0

# ---- 日志（同时进文件；轮转避免无限增长）----
log(){
    _line="[$(date '+%Y-%m-%d %H:%M:%S')] [guard] $*"
    echo "$_line" >> "$GUARD_LOG" 2>/dev/null
    echo "$_line"
}
rotate_log(){
    _f="$1"; _max="$2"
    case "$_max" in ''|*[!0-9]*) return 0 ;; esac
    [ "${_max:-0}" -gt 0 ] || return 0
    [ -f "$_f" ] || return 0
    _kb=$(du -k "$_f" 2>/dev/null | awk '{print $1}')
    case "${_kb:-}" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$_kb" -ge "$_max" ]; then
        mv "$_f" "$_f.1" 2>/dev/null && : > "$_f" 2>/dev/null
    fi
}

# ---- 域名解析：nslookup 主路径 -> ping 兜底 -> 失败返回非 0 ----
resolve_ipv4(){
    _h="$1"; _try=0
    while [ "$_try" -le "$DNS_RESOLVE_RETRY" ]; do
        for _dns in $DNS_SERVERS; do
            _ip=$(nslookup "$_h" "$_dns" 2>/dev/null \
                  | awk '/^Address [0-9]+: /{print $3}' \
                  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
            if [ -n "$_ip" ]; then echo "$_ip"; return 0; fi
        done
        _ip=$(ping -c1 -W2 "$_h" 2>/dev/null | grep PING | awk -F'[()]' '{print $2}')
        case "$_ip" in
            ''|*[!0-9.]*) : ;;
            *) echo "$_ip"; return 0 ;;
        esac
        _try=$((_try+1))
        [ "$_try" -le "$DNS_RESOLVE_RETRY" ] && sleep 1
    done
    return 1
}

cache_get(){
    [ -f "$DNS_CACHE_FILE" ] || return 1
    grep "^$1 " "$DNS_CACHE_FILE" 2>/dev/null | head -n1 | awk '{print $2}'
}
cache_put(){
    _k="$1"; _v="$2"; _t=$(mktemp 2>/dev/null) || return 0
    grep -v "^$_k " "$DNS_CACHE_FILE" 2>/dev/null > "$_t"
    printf '%s %s\n' "$_k" "$_v" >> "$_t"
    mv "$_t" "$DNS_CACHE_FILE" 2>/dev/null || rm -f "$_t"
}

# ---- P1-3 dnsmasq 存活守护 ----
dnsmasq_alive(){ ps w 2>/dev/null | grep -q '[d]nsmasq'; }
check_dnsmasq(){
    [ "$DNSMASQ_GUARD_ENABLED" = "1" ] || return 0
    if dnsmasq_alive; then return 0; fi
    DNSMASQ_RESTART_COUNT=$((DNSMASQ_RESTART_COUNT+1))
    log "WARN dnsmasq 进程不存在，尝试拉起（本次守护内第 ${DNSMASQ_RESTART_COUNT} 次）"
    /etc/init.d/dnsmasq start >/dev/null 2>&1
    sleep 2
    if dnsmasq_alive; then
        log "OK   dnsmasq 已拉起成功（累计重启 ${DNSMASQ_RESTART_COUNT} 次）"
    else
        log "FAIL dnsmasq 拉起失败，将在下个周期重试"
    fi
}

# ---- mihomo 存活看护（R1 验收新增）----
# 背景：验收时 kill 掉 mihomo 后无任何组件拉起它。原职责划分里
#   uuplugin_monitor.sh 只看护 uuplugin；service_guard 只看 dnsmasq/WARP/DNS。
#   -> mihomo 处于"三不管"状态，一旦退出即永久失效（转发、WARP、mihomo0 全丢）。
# 设计：仅在进程不存在时调用 restart_mihomo.sh（其内部有并发锁），并记录重启次数。
mihomo_alive(){ ps w 2>/dev/null | grep -q "[e]tc/mihomo/mihomo"; }
# [生命周期闸门] 任一被监控 tun 在线（UP 标志）即返回 0；全部离线/不存在返回 1。
# 注意：ip link show <不存在接口> 会报错且无输出，grep 自然不匹配 -> 视为不在线。
tun_any_up(){
    for _if in tun163 tun164; do
        if ip link show "$_if" 2>/dev/null | grep -qE '<[^>]*UP[^>]*>'; then
            return 0
        fi
    done
    return 1
}
check_mihomo(){
    [ "$MIHOMO_GUARD_ENABLED" = "1" ] || return 0
    if mihomo_alive; then
        _n=$(ps w 2>/dev/null | grep -c "[e]tc/mihomo/mihomo")
        [ "${_n:-0}" -gt 1 ] && log "WARN mihomo 存在 ${_n} 个实例（异常，多实例会争抢 mihomo0）"
        return 0
    fi
    # [生命周期闸门] 所有 tun 均离线时，按看门狗策略【不】自动拉起 mihomo：
    # 否则会与"无 tun 即关闭 mihomo"的宿主看门狗互殴（守护每 30s 拉起、看门狗每周期关掉）。
    # 待任一 tun 恢复在线，再由本看护或宿主机 uu_monitor.sh 拉起。
    if ! tun_any_up; then
        log "INFO 所有 tun 接口均离线，按生命周期策略保持 mihomo 关闭（不自动拉起）"
        return 0
    fi
    MIHOMO_RESTART_COUNT=$((MIHOMO_RESTART_COUNT+1))
    log "WARN mihomo 进程不存在且 tun 在线，尝试拉起（本次守护内第 ${MIHOMO_RESTART_COUNT} 次）"
    sh $MIHOMO_RESTART_CMD >/dev/null 2>&1
    sleep "${MIHOMO_RESTART_WAIT_SEC}"
    if mihomo_alive; then
        log "OK   mihomo 已拉起成功（累计重启 ${MIHOMO_RESTART_COUNT} 次）"
    else
        log "FAIL mihomo 拉起失败，将在下个周期重试"
    fi
}

# ---- P1-4 WARP alive 恢复即刷新 ----
state_get(){ [ -f "$STATEDIR/guard_$1.state" ] && cat "$STATEDIR/guard_$1.state" 2>/dev/null || echo ""; }
state_set(){ echo "$2" > "$STATEDIR/guard_$1.state" 2>/dev/null || true; }
probe_delay(){
    wget -q -O- "http://127.0.0.1:9090/proxies/$1/delay?url=http://cp.cloudflare.com&timeout=$WARP_WATCH_TIMEOUT_MS" 2>/dev/null
}
check_warp(){
    [ "$WARP_WATCH_ENABLED" = "1" ] || return 0
    for _n in $WARP_NODES; do
        _d=$(probe_delay "$_n")
        case "$_d" in
            *'"delay"'*) _now=1 ;;
            *)           _now=0 ;;
        esac
        _prev=$(state_get "$_n")
        if [ "${_prev:-}" != "$_now" ]; then
            if [ "$_now" = "1" ]; then
                log "OK   $_n 状态恢复可用（探针=${_d}），触发一次状态与规则刷新"
                if [ "$WARP_REFRESH_ON_RECOVER" = "1" ]; then
                    sh $WARP_REFRESH_CMD >/dev/null 2>&1 \
                        && log "     刷新命令执行成功: $WARP_REFRESH_CMD" \
                        || log "FAIL 刷新命令执行失败: $WARP_REFRESH_CMD"
                fi
            else
                log "WARN $_n 转为不可用（探针=${_d:-空}）"
            fi
        fi
        state_set "$_n" "$_now"
    done
}

# ---- P0-2 域名定期重解析（变化才重载；失败保留上次结果并告警）----
check_dns_refresh(){
    [ "$DNS_REFRESH_ENABLED" = "1" ] || return 0
    [ -f "$RULES_DB" ] || return 0
    _changed=0
    while read -r line; do
        case "$line" in \#*|"") continue ;; esac
        _h=$(echo "$line" | cut -d: -f1)
        [ -n "$_h" ] || continue
        case "$_h" in
            *[!0-9.]*) : ;;   # 含非数字/点 => 域名，需解析
            *) continue ;;    # 纯 IP，跳过
        esac
        _old=$(cache_get "$_h" || true)
        _new=$(resolve_ipv4 "$_h" || true)
        if [ -n "$_new" ]; then
            if [ "$_new" != "${_old:-}" ]; then
                log "INFO 域名解析变更: $_h ${_old:-<无>} -> $_new"
                cache_put "$_h" "$_new"
                _changed=1
            fi
        else
            log "WARN 定期重解析失败，保留上次结果: $_h -> ${_old:-<无缓存>}"
        fi
    done < "$RULES_DB"
    if [ "$_changed" = "1" ]; then
        log "INFO 检测到解析结果变更，同步规则并重载转发引擎"
        sh "$SYNC" >/dev/null 2>&1 && log "     规则同步完成" || log "FAIL 规则同步失败"
        sh "$ENGINE" reload >/dev/null 2>&1 && log "     转发引擎重载完成" || log "FAIL 转发引擎重载失败"
    fi
}

daemon_loop(){
    # [防多开自锁] 收尾复核曾观测到 service_guard 出现 2 个实例的瞬时态。
    # 双实例会重复看护 dnsmasq/mihomo，并可能【重复推送 WARP 告警】（违反"避免刷屏"要求）。
    # 与 uuplugin_monitor.sh 同一模式：BusyBox flock 必须用 -xn（不支持 util-linux 的 -e）。
    if [ "${SG_FLOCKER:-}" != "$0" ] && command -v flock >/dev/null 2>&1; then
        exec env SG_FLOCKER="$0" flock -xn "$0" /bin/sh "$0" "$@"
        # 抢不到锁时 flock -xn 直接退出 1，exec 后本进程随之结束 -> 不会执行到下面登记 PIDFILE。
    fi
    # 只有走到这里 = 已独占锁（或环境无 flock）的进程，才登记 PIDFILE。
    # exec 不改变 PID，所以这里的 $$ 与外层看到的 PID 一致。
    mkdir -p "$(dirname "$PIDFILE")" 2>/dev/null
    echo $$ > "$PIDFILE" 2>/dev/null
    trap 'rm -f "$PIDFILE" 2>/dev/null' EXIT
    log "==== 守护启动 pid=$$ 间隔: dnsmasq=${DNSMASQ_GUARD_INTERVAL_SEC}s mihomo=${MIHOMO_GUARD_INTERVAL_SEC}s warp=${WARP_WATCH_INTERVAL_SEC}s dns=${DNS_REFRESH_INTERVAL_SEC}s ===="
    _t_dnsq=0; _t_warp=0; _t_dns=0; _t_mih=0
    while true; do
        rotate_log "$GUARD_LOG" "$GUARD_LOG_MAX_KB"
        _t_dnsq=$((_t_dnsq + GUARD_LOOP_INTERVAL_SEC))
        _t_warp=$((_t_warp + GUARD_LOOP_INTERVAL_SEC))
        _t_dns=$((_t_dns + GUARD_LOOP_INTERVAL_SEC))
        _t_mih=$((_t_mih + GUARD_LOOP_INTERVAL_SEC))
        if [ "$_t_dnsq" -ge "$DNSMASQ_GUARD_INTERVAL_SEC" ];   then check_dnsmasq;      _t_dnsq=0; fi
        if [ "$_t_mih"  -ge "$MIHOMO_GUARD_INTERVAL_SEC" ];    then check_mihomo;       _t_mih=0;  fi
        if [ "$_t_warp" -ge "$WARP_WATCH_INTERVAL_SEC" ];      then check_warp;         _t_warp=0; fi
        if [ "$_t_dns"  -ge "$DNS_REFRESH_INTERVAL_SEC" ];     then check_dns_refresh;  _t_dns=0;  fi
        sleep "$GUARD_LOOP_INTERVAL_SEC"
    done
}

guard_alive(){
    [ -f "$PIDFILE" ] || return 1
    _p=$(cat "$PIDFILE" 2>/dev/null)
    case "${_p:-}" in ''|*[!0-9]*) return 1 ;; esac
    [ -d "/proc/$_p" ] || return 1
    return 0
}

case "${1:-ensure}" in
    ensure)
        if guard_alive; then
            echo "[guard] 已在运行 pid=$(cat "$PIDFILE" 2>/dev/null)"; exit 0
        fi
        rm -f "$PIDFILE" 2>/dev/null
        ( sh "$0" daemon >/dev/null 2>&1 & )
        sleep 2
        if ! guard_alive; then
            # 2 秒内未登记成功，可能是启动偏慢或刚好撞上锁竞争 -> 多等 2 秒再判一次
            sleep 2
            if ! guard_alive; then
                ( sh "$0" daemon >/dev/null 2>&1 & )
                sleep 3
            fi
        fi
        if guard_alive; then
            echo "[guard] 已启动 pid=$(cat "$PIDFILE" 2>/dev/null)"
        else
            echo "[guard] 启动失败，请检查 $GUARD_LOG"
            exit 1
        fi
        ;;
    daemon)
        # [修复] 旧实现在这里【先写 PIDFILE，再由 daemon_loop 里的 flock -xn 抢锁】。
        # 若锁已被存活的守护持有，flock -xn 立即失败 -> 本进程退出 -> 而 PIDFILE 已被写成这个
        # 已死 PID -> guard_alive() 从此永远返回假 -> 之后每次 ensure 都以为"没在跑"，
        # 不断拉起注定抢不到锁的新守护，守护再也无法自愈（实测新机 service_guard 永不运行的根因）。
        # 对策：PIDFILE 只在【真正抢到锁之后】才写（见 daemon_loop 内），抢不到锁的进程不留痕迹。
        # 必须显式把脚本参数传给 daemon_loop：函数内的 "$@" 是【函数参数】而非脚本参数，
        # 若无参调用则 $@ 为空 -> flock 以无参启动脚本 -> ${1:-ensure} 退回 ensure -> 递归自启导致启动失败。
        daemon_loop "$@"
        ;;
    stop)
        if guard_alive; then
            kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
            rm -f "$PIDFILE" 2>/dev/null
            echo "[guard] 已停止"
        else
            echo "[guard] 未在运行"
        fi
        ;;
    restart)
        sh "$0" stop
        sleep 1
        sh "$0" ensure
        ;;
    once)
        echo "[guard] 执行一次检查（不常驻）..."
        check_dnsmasq
        check_mihomo
        check_warp
        check_dns_refresh
        echo "[guard] 检查完成，日志见 $GUARD_LOG"
        ;;
    status)
        if guard_alive; then
            echo "[guard] 运行中 pid=$(cat "$PIDFILE" 2>/dev/null)"
        else
            echo "[guard] 未运行"
        fi
        echo "--- 最近日志 ---"
        tail -n 15 "$GUARD_LOG" 2>/dev/null
        ;;
    *)
        echo "用法: $0 {ensure|daemon|restart|stop|once|status}"
        exit 1
        ;;
esac
exit 0
EOF_GUARD_V121
)"

# [稳定性加固] 守护参数（超时/重试/间隔等均可配置）
deploy_file "$BASE_DIR/conf/service_guard.conf" "EOF_GUARDCONF_V121" "644" "" "$(cat <<'EOF_GUARDCONF_V121'
# ============================================================
# 稳定性加固参数（各脚本 source 本文件；文件缺失时脚本内默认值兜底）
# 真身：宿主 /opt/uuplugin/conf/service_guard.conf
#     = 容器 /etc/uu_conf/service_guard.conf
# 修改后需重启守护生效：sh /etc/scripts/service_guard.sh restart
# ============================================================

# ---- P0-1 mihomo 日志 ----
MIHOMO_LOG=/etc/uu_conf/mihomo.log
MIHOMO_LOG_MAX_KB=2048          # 超过则轮转为 <log>.1；0=不限制

# ---- P0-2 域名解析 ----
DNS_SERVERS="119.29.29.29 223.5.5.5 8.8.8.8"
DNS_RESOLVE_RETRY=2             # 每个域名的解析重试次数（0=不重试）
DNS_CACHE_FILE=/etc/uu_conf/.dns_cache
DNS_REFRESH_INTERVAL_SEC=300    # 定期重解析间隔（秒）
DNS_REFRESH_ENABLED=1           # 1=开启定期重解析

# ---- P1-3 dnsmasq 存活守护 ----
DNSMASQ_GUARD_ENABLED=1
DNSMASQ_GUARD_INTERVAL_SEC=30   # 存活检查间隔（秒）

# ---- P1-4 WARP alive 恢复即刷新 ----
WARP_WATCH_ENABLED=1
WARP_WATCH_INTERVAL_SEC=60      # 探针间隔（秒）
WARP_WATCH_TIMEOUT_MS=8000      # 单次探针超时（毫秒）
WARP_REFRESH_ON_RECOVER=1       # 1=状态由异常转可用时立即刷新
WARP_REFRESH_CMD="/etc/scripts/proxy_manager.sh reload"
WARP_NODES="WARP163 WARP164"

# ---- P2-6 等待 tun 就绪后再启动 mihomo ----
TUN_WAIT_TIMEOUT_SEC=20         # 单轮等待超时（秒）
TUN_WAIT_INTERVAL_SEC=2         # 轮询间隔（秒）
# [R1 调整] 原为 3 轮（最坏 60×3=180s）。看门狗拉起 mihomo 时会被这段等待阻塞，
# 导致"进程掉了却迟迟拉不回来"。隧道通常在容器启动后即就绪，
# 故收敛为 1 轮 20 秒：未就绪则告警继续，不再拖慢看护响应。
TUN_WAIT_RETRY=1                # 超时后的重试轮数
TUN_WAIT_STRICT=0               # 1=最终仍未就绪则中止启动；0=告警并继续

# ---- mihomo 存活看护（R1 验收新增：mihomo 被 kill 后原本无人拉起）----
MIHOMO_GUARD_ENABLED=1
MIHOMO_GUARD_INTERVAL_SEC=10    # 存活检查间隔（秒；R1 收紧以缩短拉起时延）
MIHOMO_RESTART_CMD="/etc/scripts/restart_mihomo.sh"
MIHOMO_RESTART_WAIT_SEC=8       # 拉起后等待确认的秒数

# ---- 守护自身 ----
GUARD_LOG=/etc/uu_conf/service_guard.log
GUARD_LOG_MAX_KB=1024
GUARD_LOOP_INTERVAL_SEC=10      # 主循环 tick（秒）
EOF_GUARDCONF_V121
)"

deploy_file "$BASE_DIR/scripts/watch_rules.sh" "EOF_WATCH_V7" "755" "" "$(cat <<'EOF_WATCH_V7'
#!/bin/sh
# 自动同步守护：轮询 forward_rules.conf，内容变化即触发同步+重载 mihomo。
# 满足需求「自动识别新增规则并同步写入 mihomo YAML，并自动触发 mihomo 重载/启动」。
# 触发时机补充：除面板保存(reload)外，本守护覆盖「手动/第三方修改配置未主动 reload」的场景，杜绝漂移。
set -u

RULES_DB="/etc/uu_conf/forward_rules.conf"
ENGINE="/etc/scripts/proxy_manager.sh"
SUM=""

log(){ echo "[watch-rules] $*"; }

# 计算校验和（BusyBox 有 md5sum）
checksum(){
    md5sum "$1" 2>/dev/null | awk '{print $1}'
}

while true; do
    if [ -f "$RULES_DB" ]; then
        _new=$(checksum "$RULES_DB")
        if [ -n "$_new" ] && [ "$_new" != "$SUM" ]; then
            # 首次运行(SUM 为空)仅记录基线，不触发；后续变化才触发
            if [ -n "$SUM" ]; then
                log "检测到规则变更，触发同步+重载"
                /bin/sh "$ENGINE" reload
            fi
            SUM="$_new"
        fi
    fi
    sleep 5
done
EOF_WATCH_V7
)"

deploy_file "$BASE_DIR/scripts/uu_monitor.sh" "EOF_MONITOR_V7" "755" "PUSH_DEDUP_V2" "$(cat <<'EOF_MONITOR_V7'
#!/bin/bash
# =============================================================================
#  UU 智能看门狗 —— tun* 接口掉线监控 + WxPusher 微信告警
#  版本标记：PUSH_DEDUP_V2（用于 install/manager 防回归识别，勿删）
# =============================================================================
#  推送去重契约（硬需求，务必保持）：
#    * 对 WATCH_IFACES 及动态发现的 tun* 接口，逐个独立跟踪状态
#    * 【离线】【恢复】两种事件，各自只在状态真正翻转的那一瞬间推送【一条】
#    * 状态未变化 -> 一律不推送（无周期提醒、无重复刷屏）
#    * 采用 write-ahead 落盘：先持久化新状态，再发推送，
#      确保推送前状态已变更，杜绝"推送了但状态没写进去"导致的重推
#
#  用法：
#    uu_monitor.sh              # 常驻循环（systemd / rc.local 用）
#    uu_monitor.sh once         # 只检测一轮（验收/调试用）
#    uu_monitor.sh test         # 发送一条测试推送（验证 token/UID 是否正确）
#    uu_monitor.sh status       # 打印当前各接口状态与最近日志
#
#  判定说明（重要）：
#    tun 设备即使正常工作，`ip link show` 也显示 **state UNKNOWN**（无载波），
#    因此【不能】用 "state UP" 判定；本脚本解析尖括号内的标志位 <...UP...>。
#
#  依赖：bash、docker、curl、date、mkdir（宿主侧；脚本在【宿主】运行，
#        通过 docker exec 读取容器内的接口状态）
# =============================================================================

# ---------- 默认参数（均可被 /opt/uuplugin/conf/wxpusher.conf 覆盖）----------
WXPUSHER_CONF="${WXPUSHER_CONF:-/opt/uuplugin/conf/wxpusher.conf}"

CONTAINER="${CONTAINER:-uuplugin}"
WATCH_IFACES="${WATCH_IFACES:-tun163 tun164}"
CHECK_INTERVAL_SEC="${CHECK_INTERVAL_SEC:-10}"

LOG_FILE="${LOG_FILE:-/opt/uuplugin/log/uu_watchdog.log}"
LOG_MAX_KB="${LOG_MAX_KB:-1024}"
STATE_DIR="${STATE_DIR:-/var/run/uu_watchdog}"

PUSH_TIMEOUT_SEC="${PUSH_TIMEOUT_SEC:-10}"
PUSH_RETRY="${PUSH_RETRY:-2}"
DRY_RUN="${DRY_RUN:-0}"

# ---- [WARP 自愈] tun 恢复在线后自动重启 mihomo，清除 WG stale bind ----
WARP_AUTORESTART_ON_TUNUP="${WARP_AUTORESTART_ON_TUNUP:-1}"
RESTART_DEBOUNCE_SEC="${RESTART_DEBOUNCE_SEC:-60}"      # 两次重启最小间隔（秒）
RESTART_MAX_PER_EPISODE="${RESTART_MAX_PER_EPISODE:-5}" # 单回合最大重启次数，防风暴
RESTART_STAMP="${RESTART_STAMP:-$STATE_DIR/mihomo_restart.stamp}"
RESTART_CNT="${RESTART_CNT:-$STATE_DIR/mihomo_restart.cnt}"

# ---- [智能看门狗 + 熔断] 按 tun 存在性管理 mihomo 生命周期 ----
#   所有被监控 tun 均离线 -> 自动关闭 mihomo；
#   任一 tun 在线        -> 保持运行 / 立即启动（未运行则拉起）。
MH_LIFECYCLE="${MH_LIFECYCLE:-1}"
MH_STOP_GRACE_CYCLES="${MH_STOP_GRACE_CYCLES:-2}"       # 连续 N 周期全离线才关 mihomo
MH_START_DEBOUNCE_SEC="${MH_START_DEBOUNCE_SEC:-5}"
MH_MAX_STARTS_PER_EPISODE="${MH_MAX_STARTS_PER_EPISODE:-10}"
MH_CB_MAX_FAILS="${MH_CB_MAX_FAILS:-5}"
MH_CB_COOLDOWN_SEC="${MH_CB_COOLDOWN_SEC:-120}"
MH_FAIL_FILE="${MH_FAIL_FILE:-$STATE_DIR/mh_fail.cnt}"
MH_CB_OPEN="${MH_CB_OPEN:-$STATE_DIR/mh_cb.open_until}"
MH_ALLDOWN="${MH_ALLDOWN:-$STATE_DIR/mh_alldown.streak}"
MH_START_STAMP="${MH_START_STAMP:-$STATE_DIR/mh_start.stamp}"
MH_START_CNT="${MH_START_CNT:-$STATE_DIR/mh_start.cnt}"
MH_STARTED_FLAG="${MH_STARTED_FLAG:-$STATE_DIR/mh_started.flag}"

# 本轮生效的监控列表（配置 + 动态发现的 tun*），由 check_once 计算
EFFECTIVE_IFACES="$WATCH_IFACES"

WXPUSHER_APP_TOKEN=""
WXPUSHER_UID=""

# 加载配置（放在默认值之后，使配置文件优先级最高）
if [ -f "$WXPUSHER_CONF" ]; then
    . "$WXPUSHER_CONF"
fi

# ---------- 日志 ----------
log() {
    local _line
    _line="$(date '+%Y-%m-%d %H:%M:%S') [uu-dog] $*"
    echo "$_line"
    echo "$_line" >> "$LOG_FILE" 2>/dev/null
}
rotate_log() {
    local _max="$LOG_MAX_KB" _kb
    case "$_max" in ''|*[!0-9]*) return 0 ;; esac
    [ "${_max:-0}" -gt 0 ] || return 0
    [ -f "$LOG_FILE" ] || return 0
    _kb=$(du -k "$LOG_FILE" 2>/dev/null | awk '{print $1}')
    case "${_kb:-}" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$_kb" -ge "$_max" ]; then
        mv "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null && : > "$LOG_FILE" 2>/dev/null
    fi
}

now_ts() { date '+%Y-%m-%d %H:%M:%S'; }
epoch()  { date '+%s'; }

# ---------- 状态持久化 ----------
# 约定：.state 文件【只能】是 "up" 或 "down" 两个字面值之一。
# 历史 bug：某些版本曾把 epoch 时间戳误写进 .state，导致 _prev 永远 != 当前状态，
#           表现为每轮重复推送"恢复"。故 state_set 增加回读校验 + 值域校验。
state_file()  { echo "$STATE_DIR/$1.state"; }
down_file()   { echo "$STATE_DIR/$1.downtime"; }
state_get()   { [ -f "$(state_file "$1")" ] && cat "$(state_file "$1")" 2>/dev/null || echo ""; }
state_set()   {
    local _sf _v
    _sf="$(state_file "$1")"
    _v="$2"
    case "$_v" in
        up|down) ;;
        *) log "ERROR 拒绝写入非法状态值 '$_v' 到 $_sf（只允许 up/down）"; return 1 ;;
    esac
    echo "$_v" > "$_sf" 2>/dev/null || { log "ERROR 状态落盘失败: $_sf"; return 1; }
    # 回读校验：确保去重基线真实生效，否则宁可报错也不要静默重推
    if [ "$(cat "$_sf" 2>/dev/null)" != "$_v" ]; then
        log "ERROR 状态回读校验失败: $_sf 期望=$_v 实际=$(cat "$_sf" 2>/dev/null)"
        return 1
    fi
    return 0
}

# ---------- 推送 ----------
push_configured() {
    case "$WXPUSHER_APP_TOKEN" in ''|AT_xxxx*) return 1 ;; esac
    case "$WXPUSHER_UID" in ''|UID_xxxx*) return 1 ;; esac
    return 0
}

send_wx() {
    local _summary="$1" _content="$2" _payload _resp _i=0

    if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN 推送（未真正发送）: $_summary"
        return 0
    fi

    if ! push_configured; then
        log "WARN 未配置有效的 appToken/UID，跳过推送（请在 $WXPUSHER_CONF 中填写）: $_summary"
        return 1
    fi

    _payload=$(printf '{"appToken":"%s","content":"%s","summary":"%s","contentType":1,"uids":["%s"]}' \
        "$WXPUSHER_APP_TOKEN" "$_content" "$_summary" "$WXPUSHER_UID")

    while [ "$_i" -le "$PUSH_RETRY" ]; do
        _resp=$(curl --connect-timeout 5 -m "$PUSH_TIMEOUT_SEC" -s -X POST \
            -H "Content-Type: application/json" \
            -d "$_payload" \
            "https://wxpusher.zjiecode.com/api/send/message" 2>/dev/null)
        if printf '%s' "$_resp" | grep -q '"code":1000'; then
            log "OK   推送成功: $_summary"
            return 0
        fi
        _i=$((_i + 1))
        log "WARN 推送失败（第 $_i 次）: ${_resp:-无响应}"
        [ "$_i" -le "$PUSH_RETRY" ] && sleep 2
    done
    log "FAIL 推送最终失败: $_summary"
    return 1
}

# ---------- 接口在线判定：解析 <...> 标志位中的 UP ----------
iface_is_up() {
    local _snap="$1" _if="$2" _flags
    _flags=$(printf '%s\n' "$_snap" \
        | grep -oE "^[0-9]+: ${_if}: <[^>]*>" \
        | grep -oE '<[^>]*>' | head -n1)
    [ -z "$_flags" ] && return 1
    case ",${_flags}," in
        *,UP,*) return 0 ;;
        *)      return 1 ;;
    esac
}

# ---------- 动态发现容器内的 tun* 接口（满足 tun 通配需求）----------
discover_tun_ifaces() {
    local _snap="$1"
    printf '%s\n' "$_snap" \
        | grep -oE '^[0-9]+: tun[A-Za-z0-9._-]*:' \
        | sed -E 's/^[0-9]+: //; s/:$//' \
        | sort -u
}

# 把动态发现的接口并入监控列表（去重）
build_effective_ifaces() {
    local _snap="$1" _d
    EFFECTIVE_IFACES="$WATCH_IFACES"
    for _d in $(discover_tun_ifaces "$_snap"); do
        case " $EFFECTIVE_IFACES " in
            *" $_d "*) ;;
            *) EFFECTIVE_IFACES="$EFFECTIVE_IFACES $_d" ;;
        esac
    done
}

# ---------- [WARP 自愈] 重启 mihomo 清除 WG stale bind ----------
trigger_mihomo_restart() {
    [ "$WARP_AUTORESTART_ON_TUNUP" = "1" ] || return 0
    if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN 触发 mihomo 重启（未真正执行）"
        return 0
    fi
    log "🔧 触发 mihomo 安全重启（清除 WG stale bind，恢复 WARP 出网）"
    ( docker exec "$CONTAINER" sh /etc/scripts/restart_mihomo.sh >> "$LOG_FILE" 2>&1 & )
}

_do_maybe_restart() {
    # 注意：这里所有变量必须 local。历史上曾用全局 _now 保存 epoch，
    # 覆盖了 check_once 中表示接口状态的同名变量，导致 .state 被写入时间戳。
    local _now _last _cnt
    _now=$(epoch)
    _last=$(cat "$RESTART_STAMP" 2>/dev/null)
    case "${_last:-}" in ''|*[!0-9]*) _last=0 ;; esac
    if [ $((_now - _last)) -lt "$RESTART_DEBOUNCE_SEC" ]; then
        return 0
    fi
    _cnt=$(cat "$RESTART_CNT" 2>/dev/null)
    case "${_cnt:-}" in ''|*[!0-9]*) _cnt=0 ;; esac
    if [ "$_cnt" -ge "$RESTART_MAX_PER_EPISODE" ]; then
        return 0
    fi
    echo "$_now" > "$RESTART_STAMP" 2>/dev/null || true
    _cnt=$((_cnt + 1))
    echo "$_cnt" > "$RESTART_CNT" 2>/dev/null || true
    trigger_mihomo_restart
}
maybe_restart_mihomo() {
    [ "$WARP_AUTORESTART_ON_TUNUP" = "1" ] || return 0
    _do_maybe_restart
}

# ---------- [智能看门狗] mihomo 生命周期管理 ----------
mihomo_is_running() {
    docker exec "$CONTAINER" sh -c \
        'for p in /proc/[0-9]*; do [ "$(cat "$p/comm" 2>/dev/null)" = mihomo ] && exit 0; done; exit 1' 2>/dev/null
}
stop_mihomo() {
    [ "$DRY_RUN" = "1" ] && { log "DRY-RUN 关闭 mihomo（未真正执行）"; return 0; }
    log "🔌 关闭 mihomo（所有 tun 离线，按生命周期策略停机）"
    docker exec "$CONTAINER" sh -c \
        'for p in /proc/[0-9]*; do [ "$(cat "$p/comm" 2>/dev/null)" = mihomo ] && kill -9 "$(echo "$p" | cut -d/ -f3)" 2>/dev/null; done' 2>/dev/null
}
tun_up_count() {
    # 用 ${1-...}（仅 unset 才回退）而非 ${1:-...}：调用方显式传入的空串应如实判为 0
    local _snap="${1-$(docker exec "$CONTAINER" ip link show 2>/dev/null)}"
    local _c=0 _if
    for _if in $EFFECTIVE_IFACES; do
        iface_is_up "$_snap" "$_if" && _c=$((_c + 1))
    done
    echo "$_c"
}
lifecycle_start_mihomo() {
    local _now _last _cnt
    _now=$(epoch)
    _last=$(cat "$MH_START_STAMP" 2>/dev/null); case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
    if [ $((_now - _last)) -lt "$MH_START_DEBOUNCE_SEC" ]; then return 1; fi
    _cnt=$(cat "$MH_START_CNT" 2>/dev/null); case "$_cnt" in ''|*[!0-9]*) _cnt=0 ;; esac
    if [ "$_cnt" -ge "$MH_MAX_STARTS_PER_EPISODE" ]; then
        log "WARN mihomo 本回合启动次数已达上限($MH_MAX_STARTS_PER_EPISODE)，停止自动启动（请人工排查）"
        return 1
    fi
    echo "$_now" > "$MH_START_STAMP" 2>/dev/null || true
    echo $((_cnt + 1)) > "$MH_START_CNT" 2>/dev/null || true
    trigger_mihomo_restart
    return 0
}
enforce_mihomo_lifecycle() {
    [ "$MH_LIFECYCLE" = "1" ] || return 0
    local _snap="${1:-}" _up _now _streak _open _f
    _up=$(tun_up_count "$_snap")
    _now=$(epoch)

    if [ "$_up" -eq 0 ]; then
        rm -f "$MH_FAIL_FILE" "$MH_CB_OPEN" "$MH_STARTED_FLAG" "$MH_START_STAMP" "$MH_START_CNT" 2>/dev/null || true
        _streak=$(cat "$MH_ALLDOWN" 2>/dev/null); case "$_streak" in ''|*[!0-9]*) _streak=0 ;; esac
        _streak=$((_streak + 1)); echo "$_streak" > "$MH_ALLDOWN" 2>/dev/null || true
        if [ "$_streak" -ge "$MH_STOP_GRACE_CYCLES" ] && mihomo_is_running; then
            stop_mihomo
        fi
        return 0
    fi

    rm -f "$MH_ALLDOWN" 2>/dev/null || true

    _open=$(cat "$MH_CB_OPEN" 2>/dev/null); case "$_open" in ''|*[!0-9]*) _open=0 ;; esac
    if [ "$_now" -lt "$_open" ]; then
        log "⚡ mihomo 熔断冷却中（至 $(date -d "@$_open" '+%H:%M:%S' 2>/dev/null || echo "$_open")），暂不启动"
        return 0
    fi

    if mihomo_is_running; then
        if [ -f "$MH_STARTED_FLAG" ]; then
            rm -f "$MH_FAIL_FILE" "$MH_STARTED_FLAG" 2>/dev/null || true
            log "✅ mihomo 启动后持续存活，熔断计数已清零"
        fi
        return 0
    fi

    if [ -f "$MH_STARTED_FLAG" ]; then
        _f=$(cat "$MH_FAIL_FILE" 2>/dev/null); case "$_f" in ''|*[!0-9]*) _f=0 ;; esac
        _f=$((_f + 1)); echo "$_f" > "$MH_FAIL_FILE" 2>/dev/null || true
        rm -f "$MH_STARTED_FLAG" 2>/dev/null || true
        if [ "$_f" -ge "$MH_CB_MAX_FAILS" ]; then
            echo $((_now + MH_CB_COOLDOWN_SEC)) > "$MH_CB_OPEN" 2>/dev/null || true
            log "⚡ mihomo 连续启动失败 ${_f} 次，熔断开启，冷却 ${MH_CB_COOLDOWN_SEC}s（请人工排查 tunnel/配置）"
            return 0
        fi
        log "⚠️ mihomo 启动后未存活（第 ${_f}/${MH_CB_MAX_FAILS} 次失败），将重试"
    fi

    if lifecycle_start_mihomo; then
        echo "$_now" > "$MH_START_STAMP" 2>/dev/null || true
        : > "$MH_STARTED_FLAG" 2>/dev/null || true
        log "🚀 检测到 tun 在线（$_up 个），已触发 mihomo 启动（生命周期联动）"
    fi
    return 0
}

# ---------- 一轮检测 ----------
check_once() {
    rotate_log
    local _snap
    _snap=$(docker exec "$CONTAINER" ip link show 2>/dev/null)
    if [ -z "$_snap" ]; then
        log "WARN 无法读取容器 $CONTAINER 的接口列表（docker exec 失败或容器未运行）"
        return 1
    fi

    build_effective_ifaces "$_snap"

    local _if _st _prev _t _dur _ds
    for _if in $EFFECTIVE_IFACES; do
        if iface_is_up "$_snap" "$_if"; then _st="up"; else _st="down"; fi
        _prev=$(state_get "$_if")

        # 1) 首次运行：只建立基线，不推送（避免重启造成告警风暴）
        if [ -z "$_prev" ]; then
            state_set "$_if" "$_st"
            log "INFO 建立基线: $_if = $_st（首次运行不推送）"
            if [ "$_st" = "down" ]; then
                echo "$(epoch)" > "$(down_file "$_if")" 2>/dev/null
            fi
            continue
        fi

        # 2) 历史脏数据自愈：.state 里若不是 up/down（例如旧版误写的 epoch 时间戳），
        #    直接重建基线，不推送。避免脏值导致 _prev 恒 != _st 而无限重推。
        case "$_prev" in
            up|down) ;;
            *)
                log "WARN $_if 状态值异常（'$_prev'），重建基线为 $_st（不推送）"
                state_set "$_if" "$_st"
                [ "$_st" = "down" ] && echo "$(epoch)" > "$(down_file "$_if")" 2>/dev/null
                continue
                ;;
        esac

        # 3) 状态未变化 -> 绝不推送（这是"仅转换时推一次"的核心保证）
        if [ "$_prev" = "$_st" ]; then
            continue
        fi

        _t="$(now_ts)"
        if [ "$_st" = "down" ]; then
            echo "$(epoch)" > "$(down_file "$_if")" 2>/dev/null
            rm -f "$RESTART_CNT" "$RESTART_STAMP" 2>/dev/null
            # write-ahead：先落盘新状态，再推送，确保同一转换只推一条
            state_set "$_if" "$_st" || log "ERROR $_if 状态落盘失败，可能重复推送"
            log "🔴 $_if 由在线变为离线（$_t）"
            send_wx "🔴 [掉线] $_if 已离线" \
                "🔴 UU 加速接口掉线告警\n\n- 接口：$_if\n- 状态：离线（由在线变为离线）\n- 发生时间：$_t\n- 主机：$(hostname)\n- 动作：请检查 UU App 加速会话是否仍开启"
        else
            _dur=""
            if [ -f "$(down_file "$_if")" ]; then
                _ds=$(cat "$(down_file "$_if")" 2>/dev/null)
                case "$_ds" in ''|*[!0-9]*) ;; *) _dur="持续离线 $(( $(epoch) - _ds )) 秒" ;; esac
            fi
            rm -f "$(down_file "$_if")" 2>/dev/null
            # write-ahead：先落盘新状态，再推送，确保同一转换只推一条
            state_set "$_if" "$_st" || log "ERROR $_if 状态落盘失败，可能重复推送"
            log "🟢 $_if 恢复在线（$_t）"
            send_wx "🟢 [恢复] $_if 已恢复" \
                "🟢 UU 加速接口恢复通知\n\n- 接口：$_if\n- 状态：已恢复在线\n- 恢复时间：$_t\n- 主机：$(hostname)\n- 备注：${_dur:-离线时长未知}"
            maybe_restart_mihomo
        fi
    done

    # ---- 周期自省：tun 在线但 WARP 探测失败则补触发重启（受去抖+限次约束）----
    local _any_up=0 _w
    for _if in $EFFECTIVE_IFACES; do
        [ "$(state_get "$_if")" = "up" ] && _any_up=1
    done
    if [ "$_any_up" = "1" ] && [ "$WARP_AUTORESTART_ON_TUNUP" = "1" ]; then
        _w=$(docker exec "$CONTAINER" wget -q -O- 'http://127.0.0.1:9090/proxies/WARP163/delay?url=http://cp.cloudflare.com&timeout=8000' 2>/dev/null)
        if [ -z "$_w" ]; then
            maybe_restart_mihomo
        fi
    fi

    # ---- 每轮强制校核 mihomo 生命周期 ----
    enforce_mihomo_lifecycle "$_snap"

    return 0
}

# ---------- 启动 ----------
mkdir -p "$STATE_DIR" 2>/dev/null
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null

case "${1:-daemon}" in
    once)
        log "执行单轮检测（once）"
        check_once
        ;;
    test)
        if ! push_configured; then
            log "FAIL 未配置有效的 appToken/UID，无法测试推送。请在 $WXPUSHER_CONF 中填写后重试。"
            exit 1
        fi
        log "发送测试推送..."
        send_wx "✅ [测试] UU 看门狗" \
            "✅ UU 智能看门狗测试消息\n\n- 时间：$(now_ts)\n- 主机：$(hostname)\n- 监控接口：$WATCH_IFACES\n- 检测间隔：${CHECK_INTERVAL_SEC}s"
        ;;
    status)
        echo "=== UU 智能看门狗状态 ==="
        echo "容器: $CONTAINER    监控接口: $WATCH_IFACES    间隔: ${CHECK_INTERVAL_SEC}s"
        echo "推送策略: 状态转换仅推送一次（无周期重复提醒）    DRY_RUN: $DRY_RUN"
        echo "--- 当前状态 ---"
        for _if in $WATCH_IFACES; do
            _s=$(state_get "$_if")
            echo "  $_if = ${_s:-未记录}"
        done
        echo "--- 最近日志 ---"
        tail -n 15 "$LOG_FILE" 2>/dev/null
        ;;
    daemon|*)
        log "==== UU 智能看门狗启动 pid=$$ 容器=$CONTAINER 接口=[$WATCH_IFACES] 间隔=${CHECK_INTERVAL_SEC}s 推送策略=状态转换仅一次(PUSH_DEDUP_V2) ===="
        if ! push_configured; then
            log "WARN 检测到 WxPusher 未配置（appToken/UID 仍为占位或缺失），将只记录日志不推送。请编辑 $WXPUSHER_CONF"
        fi
        while true; do
            check_once
            sleep "$CHECK_INTERVAL_SEC"
        done
        ;;
esac
exit 0
EOF_MONITOR_V7
)"

deploy_file "$BASE_DIR/rc.local" "EOF_RCLOCAL_V7" "755" "" "$(cat <<'EOF_RCLOCAL_V7'
#!/bin/sh
sleep 3

# 统一转发配置路径：容器真实 bind 挂载点为 /etc/uu_conf（= 宿主 /opt/uuplugin/conf）。
# 面板“功能3”显示 /opt/uuplugin/conf、用户习惯写 /uu_conf，二者在容器内不存在，
# 建符号链接使其都解析到真实文件，避免“手动编辑(nano)落空 / 找不到文件”。
ln -sf /etc/uu_conf /uu_conf 2>/dev/null || true
mkdir -p /opt/uuplugin 2>/dev/null || true
ln -sf /etc/uu_conf /opt/uuplugin/conf 2>/dev/null || true

sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1
sysctl -w net.ipv6.conf.default.forwarding=1

sysctl -w net.ipv4.tcp_tw_reuse=1
sysctl -w net.ipv4.tcp_fin_timeout=15
sysctl -w net.ipv4.tcp_synack_retries=2
sysctl -w net.ipv4.tcp_keepalive_time=600

sysctl -w net.core.rmem_max=2500000 2>/dev/null || true
sysctl -w net.core.wmem_max=2500000 2>/dev/null || true
sysctl -w net.ipv4.udp_rmem_min=8192 2>/dev/null || true
sysctl -w net.ipv4.udp_wmem_min=8192 2>/dev/null || true

sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=3600 2>/dev/null || true
sysctl -w net.netfilter.nf_conntrack_udp_timeout=60 2>/dev/null || true
sysctl -w net.netfilter.nf_conntrack_udp_timeout_stream=120 2>/dev/null || true

# 自动识别 OpenWrt 容器内的实际网卡名称（br-lan 或 eth0），兼容不同版本镜像
LAN_IFACE="br-lan"
ip link show br-lan >/dev/null 2>&1 || LAN_IFACE="eth0"

# 阶段二(缺陷4.1)：幂等写入——先用 -C 检查存在，不存在才插；容器反复重启不再堆叠
iptables -C FORWARD -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -j ACCEPT
iptables -t nat -C POSTROUTING -o "$LAN_IFACE" -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -o "$LAN_IFACE" -j MASQUERADE
[ "$LAN_IFACE" = "br-lan" ] && { iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -o eth0 -j MASQUERADE; }
[ "$LAN_IFACE" = "eth0" ] && { iptables -t nat -C POSTROUTING -o br-lan -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -o br-lan -j MASQUERADE; }

# 启动 UU 守护
if [ -x /usr/sbin/uu/uuplugin_monitor.sh ]; then
    /bin/sh /usr/sbin/uu/uuplugin_monitor.sh &
fi

# 启动 Mihomo
if [ -x /etc/mihomo/mihomo ] && [ -f /etc/mihomo/config.yaml ]; then
    # [WARP 修复] 经 restart_mihomo.sh 启动：内含 wait_for_tun(等 tun163/tun164 就绪)
    # 与 flock 并发锁。若直接启动，mihomo 按 interface-name 把 WG 外层套接字绑到尚不存在的
    # tun 会失败并缓存 ENODEV(stale bind)，此后即便隧道出现也不自愈 -> WARP 长期 alive:false。
    # TUN_WAIT_STRICT=1：隧道始终未就绪则放弃启动，交由宿主看门狗在 tun 上线时拉起。
    # 后台执行，避免阻塞后续防火墙与端口转发规则加载。
    if [ -x /etc/scripts/restart_mihomo.sh ]; then
        TUN_WAIT_STRICT=1 /bin/sh /etc/scripts/restart_mihomo.sh >> /etc/uu_conf/mihomo.log 2>&1 &
    else
        /etc/mihomo/mihomo -d /etc/mihomo > /etc/uu_conf/mihomo.log 2>&1 &
    fi
    # [加固] 原实现固定 sleep 3：若 WireGuard 握手慢于 3 秒，tun 设备尚未创建，
    # 下面的策略路由会被静默丢弃且后续无人补。改为轮询等待捕获设备就绪（最多 30s）。
    _i=0
    while [ $_i -lt 30 ]; do
        ip link show mihomo0 >/dev/null 2>&1 && break
        sleep 1
        _i=$((_i+1))
    done
    # 幂等：容器每次重启都会执行 rc.local，必须先查后插，否则 rule/route 无限堆叠
    for tun in $(ip link show 2>/dev/null | grep -oE 'tun[0-9]+' | sort -u); do
        num=$(echo "$tun" | grep -oE '[0-9]+')
        tun_ip=$(ip -4 addr show "$tun" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
        if [ -n "$tun_ip" ]; then
            ip route show table "$num" 2>/dev/null | grep -q "^default " || \
                ip route add default dev "$tun" table "$num" 2>/dev/null || true
            ip rule show 2>/dev/null | grep -q "from $tun_ip lookup $num" || \
                ip rule add from "$tun_ip" table "$num" 2>/dev/null || true
        # [加固] 清理历史重复项：旧版非幂等实现每次重启都插一条，已实测堆积到 43 条。
        # 这里保留第一条、删除其余（功能完全等价），使 ip rule 列表收敛到每个隧道 1 条。
        _dup=$(ip rule show 2>/dev/null | grep -c "from $tun_ip lookup $num")
        while [ "${_dup:-0}" -gt 1 ]; do
            ip rule del from "$tun_ip" table "$num" 2>/dev/null || break
            _dup=$(ip rule show 2>/dev/null | grep -c "from $tun_ip lookup $num")
        done
        fi
    done
fi

# 修复 OpenWrt 防火墙：将默认转发策略从 REJECT 改为 ACCEPT
if [ -f /etc/config/firewall ]; then
    sed -i 's/option forward.*REJECT/option forward ACCEPT/' /etc/config/firewall 2>/dev/null || true
    /etc/init.d/firewall restart 2>/dev/null || true
fi
# 禁用 DHCP 服务，避免与主路由冲突
/etc/init.d/dnsmasq stop 2>/dev/null || true
/etc/init.d/odhcpd stop 2>/dev/null || true
# 阶段二(缺陷4.1)：防火墙重启后再次幂等补插 FORWARD ACCEPT
iptables -C FORWARD -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -j ACCEPT

# [修复] 加载端口转发必须放在「防火墙重启之后」。
# 原因：/etc/init.d/firewall restart 会整体清空 nat 表（含 UU_PORT_FWD 链及其 PREROUTING 跳转），
#       且该链不在 fw3 配置中、不会被重建。
#       原实现把本段放在防火墙重启之前 => 规则刚装好即被清空，
#       表现为「重启虚拟机/UU 后转发规则不生效，必须手动按 5 重载」。
# 实测：firewall restart 后 PREROUTING->UU_PORT_FWD 跳数由 1 变 0；置于最后即随启动自动生效。
if [ -x /etc/scripts/proxy_manager.sh ]; then
    /bin/sh /etc/scripts/proxy_manager.sh reload > /dev/null 2>&1
fi

# [WARP 修复] macvlan 网络下 Docker 内嵌 DNS(127.0.0.11) 不可达，
# 容器内 nslookup/ping 等依赖系统 resolver 的工具会全部超时（实测 connection timed out）。
# 改用公共 DNS。幂等：已含 119.29.29.29 则不改动。
if ! grep -q "^nameserver 119.29.29.29" /etc/resolv.conf 2>/dev/null; then
    printf "nameserver 119.29.29.29\nnameserver 223.5.5.5\noptions timeout:3 attempts:3\n" > /etc/resolv.conf
fi

exit 0
EOF_RCLOCAL_V7
)"

# mihomo 主配置：含设备专属 WARP 私钥，仅在缺失时部署，绝不覆盖已有配置
if [ "$CHECK_ONLY" = 1 ]; then
    ok "config.yaml 内嵌内容校验通过（2837 字符）"
elif [ -s "$BASE_DIR/mihomo/config.yaml" ]; then
    ok "config.yaml 已存在，保留不覆盖（含设备专属 WARP 密钥）"
else
    deploy_file "$BASE_DIR/mihomo/config.yaml" "EOF_CONFIG_V7" "644" "" "$(cat <<'EOF_CONFIG_V7'
port: 7890
socks-port: 7891
mixed-port: 7892
allow-lan: true
bind-address: '*'
mode: rule
log-level: info
ipv6: false

external-controller: 0.0.0.0:9090
external-ui: ui
secret: ""

dns:
  enable: true
  listen: 0.0.0.0:1053
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - 119.29.29.29
    - 223.5.5.5
    - 8.8.8.8

# ===== TUN 捕获模式：建立专用捕获设备 mihomo0 =====
# 转发流量(DNAT 后目的=目标IP)被引擎路由进 mihomo0，mihomo 按规则集代理出网；
# auto-route:false 保证「只有转发目标」被引入 mihomo，其余流量默认走 br-lan 直连。
# 之所以必须走 TUN 捕获而非裸路由进 tun163：WARP(Cloudflare)会把内层源 NAT 成 WARP IP，
# 若裸路由进 tun163，回包目的=容器 WARP IP(本地)，客户端永远收不到答复；而 mihomo 作为有状态
# 代理接管连接，回包由 mihomo 经 mihomo0 正确送回客户端。出网仍经 WARP163/164 的 WG 设备 tun163/164。
tun:
  enable: true
  device: mihomo0
  stack: system
  auto-route: false
  auto-detect-interface: false
  dns-hijack: []
  endpoint-independent-nat: true
  address: 172.19.233.1/24

listeners:
  - name: ss-in163
    type: shadowsocks
    port: 19587
    listen: 0.0.0.0
    cipher: aes-256-gcm
    password: "MySecretSSPassword123"
    udp: true
    proxy: WARP163

  - name: socks-in163
    type: mixed
    port: 25877
    proxy: WARP163


  - name: ss-in164
    type: shadowsocks
    port: 18415
    listen: 0.0.0.0
    cipher: aes-256-gcm
    password: "MySecretSSPassword123"
    udp: true
    proxy: WARP164

  - name: socks-in164
    type: mixed
    port: 28742
    proxy: WARP164


proxies:
  - name: "WARP163"
    type: wireguard
    server: engage.cloudflareclient.com
    port: 2408
    ip: "172.16.0.2/32"
    ipv6: "2606:4700:110:87d7:8afb:35e1:acf1:48cc/128"
    private-key: "0HO7x0hFV9FJgA38rRDG9A5viEMXsIpfu/mB25Rda0k="
    reserved: [184,70,243]
    public-key: "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
    udp: true
    mtu: 1380
    remote-dns-resolve: false
    dns:
      - https://dns.cloudflare.com/dns-query
    interface-name: tun163
    allowed-ips: [0.0.0.0/0]


  - name: "WARP164"
    type: wireguard
    server: engage.cloudflareclient.com
    port: 2408
    ip: "172.16.0.2/32"
    ipv6: "2606:4700:110:8b34:41d4:3a97:5d7d:f7b5/128"
    private-key: "0LOwWOuAlTS2ElnY95jfYTAre6ugbaidFhBf1sRCXlI="
    reserved: [18,151,83]
    public-key: "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
    udp: true
    mtu: 1380
    remote-dns-resolve: false
    dns:
      - https://dns.cloudflare.com/dns-query
    interface-name: tun164
    allowed-ips: [0.0.0.0/0]


proxy-groups:
  - name: "PROXIES"
    type: select
    proxies:
      - DIRECT
      - WARP164
      - WARP163


rule-providers:
  fwd_warp163:
    type: file
    behavior: classical
    format: yaml
    path: ./rules/fwd_warp163.yaml
  fwd_warp164:
    type: file
    behavior: classical
    format: yaml
    path: ./rules/fwd_warp164.yaml

rules:
  - RULE-SET,fwd_warp163,WARP163
  - RULE-SET,fwd_warp164,WARP164
  - MATCH,DIRECT
EOF_CONFIG_V7
)"
fi

# ---------------------------------------------------------------- 步骤 5
if [ "${LEGACY_FULL:-0}" = 1 ]; then
STEP_NO="5/10 部署 mihomo 内核与 Web 面板"
step "步骤 5/10：部署 mihomo 内核与 Web 控制面板"
MIHOMO_BIN="$BASE_DIR/mihomo/mihomo"
UI_DIR="$BASE_DIR/mihomo/ui"

if [ "$CHECK_ONLY" = 1 ]; then
    info "自检模式：跳过下载。正式运行会确保 mihomo 内核与 UI 就位。"
elif [ "${UU_INSTALL_MIHOMO:-1}" = 0 ] && [ "${UU_INSTALL_UI:-1}" = 0 ]; then
    info "自定义模式：未勾选 mihomo 内核与 Web 面板，跳过本步骤"
else
    # --- 组件 1：mihomo 内核（自定义模式可关闭）---
    if [ "${UU_INSTALL_MIHOMO:-1}" = 1 ]; then
    # 离线包预检：上一次被中断的下载会在 /tmp 留下半截 mihomo.gz。
    # 若直接采用会导致 gzip 解压失败并中止部署，且此后每次重跑都卡在同一处（不会自愈）。
    # 这里先做完整性校验，损坏则隔离（保留现场便于排查），让流程自动回落到在线下载。
    if [ -s /tmp/mihomo.gz ] && ! gzip -t /tmp/mihomo.gz >/dev/null 2>&1; then
        warn "离线包 /tmp/mihomo.gz 完整性校验失败（多为上次下载中断留下的半截文件）"
        mv /tmp/mihomo.gz "/tmp/mihomo.gz.corrupt.$(date +%Y%m%d%H%M%S)" 2>/dev/null || rm -f /tmp/mihomo.gz
        info "已隔离该损坏包，改用在线下载"
    fi

    if [ -x "$MIHOMO_BIN" ] && "$MIHOMO_BIN" -v >/dev/null 2>&1; then
        ok "mihomo 内核已就位（$("$MIHOMO_BIN" -v 2>/dev/null | head -1 || true)）"
    elif [ -s /tmp/mihomo.gz ]; then
        info "检测到离线包 /tmp/mihomo.gz，优先使用"
        gzip -d -c /tmp/mihomo.gz > "$MIHOMO_BIN" && chmod +x "$MIHOMO_BIN" \
            && ok "mihomo 内核已从离线包解压" || die "离线包 /tmp/mihomo.gz 解压失败，文件可能损坏。"
        if ! "$MIHOMO_BIN" -v >/dev/null 2>&1; then
            rm -f "$MIHOMO_BIN"
            warn "离线包中的 mihomo 在本机无法运行（CPU: $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | sed 's/.*: //')）"
            mv /tmp/mihomo.gz "/tmp/mihomo.gz.bad.$(date +%Y%m%d%H%M%S)" 2>/dev/null || rm -f /tmp/mihomo.gz
            die "已清理该离线包；重新执行本脚本即会自动改走在线下载（优先 amd64-compatible 变体）。"
        fi
    elif [ "$OFFLINE" = 1 ]; then
        die "离线模式下未找到 mihomo 内核（$MIHOMO_BIN 不存在且无 /tmp/mihomo.gz）。
             请手动下载 mihomo-linux-<arch>-<ver>.gz 放到 /tmp/mihomo.gz 后重跑。"
    else
        # 变体候选：amd64 优先 compatible（不要求 v3 微架构），老 CPU（如 Celeron J1900）否则起不来
        if [ "$MIHOMO_ARCH" = "amd64" ]; then
            VARIANTS="amd64-compatible amd64"
        else
            VARIANTS="$MIHOMO_ARCH"
        fi
        M_OK=0
        for VARIANT in $VARIANTS; do
            M_URL="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-linux-${VARIANT}-${MIHOMO_VERSION}.gz"
            info "下载 mihomo ${MIHOMO_VERSION} (${VARIANT})..."
            if ! download_with_mirrors "$M_URL" /tmp/mihomo.gz; then
                warn "变体 ${VARIANT} 下载失败，尝试下一个"
                continue
            fi
            if ! gzip -t /tmp/mihomo.gz >/dev/null 2>&1; then
                warn "变体 ${VARIANT} 压缩包校验失败（gzip -t 未通过），尝试下一个"
                rm -f /tmp/mihomo.gz; continue
            fi
            gzip -d -c /tmp/mihomo.gz > "$MIHOMO_BIN" || { warn "变体 ${VARIANT} 解压失败"; continue; }
            chmod +x "$MIHOMO_BIN" || { warn "变体 ${VARIANT} 无法设置可执行权限"; continue; }
            # 实机可执行性验证（关键：v3 构建在不支持 AVX2 的 CPU 上会直接报错退出）
            if "$MIHOMO_BIN" -v >/dev/null 2>&1; then
                rm -f /tmp/mihomo.gz; M_OK=1
                ok "mihomo 内核部署完成: $("$MIHOMO_BIN" -v 2>/dev/null | head -1 || true)"
                break
            fi
            warn "变体 ${VARIANT} 在本机无法运行（多为 CPU 不支持 v3 微架构），已丢弃并尝试下一个"
            rm -f "$MIHOMO_BIN" /tmp/mihomo.gz
        done
        [ "$M_OK" = 1 ] || die "mihomo 内核部署失败（已尝试变体: ${VARIANTS}）。
             解决：手动下载 mihomo-linux-amd64-compatible-${MIHOMO_VERSION}.gz
             重命名为 mihomo.gz 放到 /tmp 后重跑（脚本会自动优先使用离线包）。"
    fi
    # 内核可执行性最终确认
    [ -x "$MIHOMO_BIN" ] || die "mihomo 内核不可执行: $MIHOMO_BIN"
    fi

    # --- 组件 2：Web 控制面板（自定义模式可关闭）---
    if [ "${UU_INSTALL_UI:-1}" = 1 ]; then
    if [ -s "$UI_DIR/index.html" ]; then
        ok "Web 控制面板已就位（$UI_DIR/index.html）"
    elif [ -s /tmp/mxd.tgz ]; then
        mkdir -p "$UI_DIR"
        tar -xzf /tmp/mxd.tgz -C "$UI_DIR" && rm -f /tmp/mxd.tgz \
            && ok "Web 面板已从离线包解压" || die "离线包 /tmp/mxd.tgz 解压失败。"
    elif [ "$OFFLINE" = 1 ]; then
        warn "离线模式下无 Web 面板包，跳过（不影响转发功能，仅 :9090/ui 不可用）"
    else
        U_URL="https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz"
        info "下载 Web 控制面板..."
        mkdir -p "$UI_DIR"
        if download_with_mirrors "$U_URL" /tmp/mxd.tgz; then
            tar -xzf /tmp/mxd.tgz -C "$UI_DIR" || die "Web 面板解压失败。"
            if [ -d "$UI_DIR/compressed-dist" ]; then
                mv "$UI_DIR/compressed-dist/"* "$UI_DIR/" 2>/dev/null || true
                rm -rf "$UI_DIR/compressed-dist" 2>/dev/null || true
            fi
            rm -f /tmp/mxd.tgz
            ok "Web 控制面板部署完成"
        else
            warn "Web 面板下载失败（已尝试多个镜像）。转发功能不受影响，仅 :9090/ui 不可用；可稍后在 uu 面板菜单 2 重新部署。"
        fi
    fi
    fi
fi

# ---------------------------------------------------------------- 步骤 6

# --- 可选：安装阶段一并拉取 mihomo（默认关闭；需显式 --with-mihomo）---
if [ "${WITH_MIHOMO:-0}" = 1 ]; then
    install_mihomo_optimized \
        || warn "mihomo 下载未成功（不影响安装流程；可在 uu 面板【菜单 2 -> 1】重试）"
fi

else
    info "安装器只装环境：mihomo 内核与 Web 面板交由 uu 面板【菜单 2】按需安装（v9.0 职责边界）"
fi
STEP_NO="6/10 权限与入口"
step "步骤 6/10：权限设置与面板入口"
if [ "$CHECK_ONLY" = 0 ]; then
    chmod 755 "$BASE_DIR/manager.sh" "$BASE_DIR/rc.local" "$BASE_DIR/mihomo/mihomo" 2>/dev/null || true
    chmod 755 "$BASE_DIR/scripts/proxy_manager.sh" "$BASE_DIR/scripts/restart_mihomo.sh" "$BASE_DIR/scripts/uu_monitor.sh" 2>/dev/null || true
    chmod 644 "$BASE_DIR/scripts/sync_mihomo_rules.sh" "$BASE_DIR/scripts/watch_rules.sh" 2>/dev/null || true
    chmod 644 "$BASE_DIR/mihomo/config.yaml" 2>/dev/null || true
    [ -f "$BASE_DIR/conf/mihomo_secret" ] && chmod 600 "$BASE_DIR/conf/mihomo_secret" 2>/dev/null || true
    chown -R root:root "$BASE_DIR" 2>/dev/null || true
    ok "权限设置完成"
    stat -c '%a %U:%G %n' "$BASE_DIR/manager.sh" "$BASE_DIR/scripts/"*.sh "$BASE_DIR/rc.local" 2>/dev/null | sed 's/^/    /'
    ln -sf "$BASE_DIR/manager.sh" /usr/local/bin/uu
    chmod 755 "$BASE_DIR/manager.sh"
    ok "面板入口就绪: /usr/local/bin/uu -> $BASE_DIR/manager.sh"

    # 规则集文件预建：provider 文件不存在会导致 mihomo 加载规则集失败
    mkdir -p "$BASE_DIR/mihomo/rules" "$BASE_DIR/conf"
    for _f in fwd_warp163.yaml fwd_warp164.yaml fwd_whitelist.yaml; do
        [ -s "$BASE_DIR/mihomo/rules/$_f" ] || printf 'payload:\n  - IP-CIDR,127.0.0.1/32\n' > "$BASE_DIR/mihomo/rules/$_f"
    done
    [ -s "$BASE_DIR/conf/forward_rules.conf" ] || printf '# 格式: 目标IP或域名:本地监听端口:目标端口:绑定的网卡(可选)\n' > "$BASE_DIR/conf/forward_rules.conf"
    ok "规则集与规则文件已就绪"
fi

# ---------------------------------------------------------------- 步骤 7
# ============================================================================
# v9.0 职责边界：安装器只装环境，业务动作一律交由面板手动触发
#   容器网络编排 / UU 核心注入   ->  uu 面板【菜单 1】
#   mihomo 内核下载与启动        ->  uu 面板【菜单 2】
# 旧的一体化行为可用 LEGACY_FULL=1 复现。
# ============================================================================
# =============================================================================
#  兼容修复 / 持久化 / 开机自动加载模块（新增）
# -----------------------------------------------------------------------------
#  背景（根因）：
#    旧版 rc.local 与 manager.sh 生成模板中，「加载端口转发(reload)」被放在
#    「/etc/init.d/firewall restart」之前。而 fw3 的 restart 会整体清空 nat 表，
#    包括 UU_PORT_FWD 自定义链及其 PREROUTING 跳转；该链不在 fw3 配置中、不会被重建。
#    结果：设备/UU 重启后转发规则失效，必须手动按「5」重载才恢复。
#
#  本模块提供三层保障（全部幂等，可重复执行）：
#    L1 规则源头持久化：forward_rules.conf 落盘在宿主机 $BASE_DIR/conf（bind 进容器）
#    L2 启动顺序纠偏：  保证 rc.local 中「防火墙重启之后」仍有一次 reload
#    L3 宿主机开机兜底： 写入 uu-boot-restore 服务，重启后确保容器在跑并重载规则
#
#  旧设备迁移：运行新脚本时自动检测并补齐上述缺失项，无需人工干预。
# =============================================================================

# ---------------------------------------------------------------- L1 规则源头
migrate_ensure_rules_file() {
    local db="$BASE_DIR/conf/forward_rules.conf"
    mkdir -p "$BASE_DIR/conf" 2>/dev/null || true
    if [ ! -f "$db" ]; then
        printf '# 格式: 目标IP或域名:本地监听端口:目标端口:绑定的网卡(可选)\n' > "$db"
        info "已创建转发规则文件: $db（空规则，请在面板功能3或本文件添加）"
    else
        ok "转发规则文件已存在（$(grep -cvE '^#|^$' "$db" 2>/dev/null || echo 0) 条规则）"
    fi
}

# ---------------------------------------------------------------- L2 顺序纠偏
migrate_fix_boot_order() {
    local rc="$BASE_DIR/rc.local"
    [ -f "$rc" ] || { warn "未找到 rc.local，跳过顺序纠偏"; return 0; }

    local fw_line reload_line
    fw_line="$(grep -n 'init.d/firewall restart' "$rc" 2>/dev/null | head -n1 | cut -d: -f1)"
    reload_line="$(grep -n 'proxy_manager.sh reload' "$rc" 2>/dev/null | tail -n1 | cut -d: -f1)"

    # 判定"正确"：存在防火墙重启，且最后一次 reload 在其之后
    if [ -n "$fw_line" ] && [ -n "$reload_line" ] && [ "${reload_line:-0}" -gt "${fw_line:-0}" ]; then
        ok "rc.local 顺序正确（防火墙重启@${fw_line} 行，转发加载@${reload_line} 行）"
        return 0
    fi

    warn "检测到旧顺序或缺失：转发加载(${reload_line:-无}) 未排在防火墙重启(${fw_line:-无})之后 —— 重启后会失效"
    cp -p "$rc" "${rc}.bak.orderfix.$(date +%Y%m%d%H%M%S)" && info "已备份原 rc.local"

    cat > /tmp/_uu_fix_block <<'BLOCK'
# [兼容修复] 端口转发必须在「防火墙重启之后」加载：
# /etc/init.d/firewall restart 会清空 nat 表（含 UU_PORT_FWD 链与其 PREROUTING 跳转），
# 且该链不在 fw3 配置中不会被重建，故此处在防火墙之后再补一次重载（幂等）。
iptables -C FORWARD -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -j ACCEPT
if [ -x /etc/scripts/proxy_manager.sh ]; then
    /bin/sh /etc/scripts/proxy_manager.sh reload >/dev/null 2>&1
fi
BLOCK

    awk -v blkfile=/tmp/_uu_fix_block '
        { lines[NR] = $0 }
        END {
            pos = 0
            for (i = NR; i >= 1; i--) { if (lines[i] ~ /^exit 0/) { pos = i; break } }
            if (pos == 0) pos = NR + 1
            for (i = 1; i < pos; i++) print lines[i]
            while ((getline line < blkfile) > 0) print line
            for (i = pos; i <= NR; i++) print lines[i]
        }' "$rc" > "${rc}.new" && mv -f "${rc}.new" "$rc"
    rm -f /tmp/_uu_fix_block
    ok "rc.local 已纠偏：在防火墙重启之后补入转发加载"
}

# ---------------------------------------------------------------- L3 开机兜底
migrate_install_boot_restore() {
    local sh="/usr/local/bin/uu-boot-restore.sh"
    echo -e "    ${CYAN}写入文件: ${NC}${sh}"
    cat > "$sh" <<'EOF_BOOT_RESTORE'
#!/bin/bash
# 开机/重启后兜底恢复：确保 uuplugin 容器在运行，并重新加载端口转发规则（幂等）。
# 即使容器 rc.local 因故未生效，本脚本也会在宿主机侧补一次重载。
LOG=/opt/uuplugin/log/boot-restore.log
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
{
  echo "===== $(date '+%F %T') boot-restore start ====="
  for i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done
  docker start uuplugin >/dev/null 2>&1 || true
  for i in $(seq 1 30); do
    docker exec uuplugin sh -c 'test -x /etc/scripts/proxy_manager.sh' >/dev/null 2>&1 && break
    sleep 2
  done
  docker exec uuplugin sh -c '/bin/sh /etc/scripts/proxy_manager.sh reload >/dev/null 2>&1'
  echo "  reload rc=$?"
  echo -n "  PREROUTING->UU_PORT_FWD="
  docker exec uuplugin sh -c 'iptables -t nat -S PREROUTING 2>/dev/null | grep -c "j UU_PORT_FWD"' 2>/dev/null || echo 0
  echo "===== $(date '+%F %T') boot-restore done ====="
} >> "$LOG" 2>&1
exit 0
EOF_BOOT_RESTORE
    chmod +x "$sh"

    if command -v systemctl >/dev/null 2>&1; then
        local unit=/etc/systemd/system/uu-boot-restore.service
        echo -e "    ${CYAN}写入文件: ${NC}${unit}"
        cat > "$unit" <<'EOF_UNIT'
[Unit]
Description=Restore UU port forwarding rules after reboot
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/uu-boot-restore.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_UNIT
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable uu-boot-restore.service >/dev/null 2>&1 \
            && ok "已启用开机恢复服务 uu-boot-restore" || warn "开机恢复服务启用失败"
        systemctl enable docker >/dev/null 2>&1 && ok "docker 已设置开机自启" || true
    else
        warn "未检测到 systemd，已生成 $sh（请自行加入 rc.local 调用）"
    fi

    # 容器层面的重启策略（若容器已存在）
    if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx uuplugin; then
        docker update --restart=always uuplugin >/dev/null 2>&1 \
            && ok "容器 uuplugin 已设置 restart=always" || warn "容器 restart 策略设置失败"
    fi
}

# ---------------------------------------------------------------- 迁移编排
migrate_legacy_deploy() {
    local legacy=0
    [ -f "$BASE_DIR/manager.sh" ] && legacy=1
    echo ""
    step "兼容修复与持久化（旧设备迁移）"
    if [ "$legacy" = 1 ]; then
        info "检测到已有部署（$BASE_DIR），执行增量补齐"
    else
        info "全新部署，建立持久化与开机恢复能力"
    fi

    migrate_ensure_rules_file
    migrate_fix_boot_order
    migrate_install_boot_restore

    # 若容器正在运行，立即应用一次，使本次部署后即可生效（不等重启）
    if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx uuplugin; then
        info "容器在运行，立即重载一次转发规则"
        docker exec uuplugin sh -c '/bin/sh /etc/scripts/proxy_manager.sh reload >/dev/null 2>&1' || true
        sleep 3
        local j
        j="$(docker exec uuplugin sh -c 'iptables -t nat -S PREROUTING 2>/dev/null | grep -c "j UU_PORT_FWD"' 2>/dev/null || echo 0)"
        if [ "${j:-0}" != "0" ]; then
            ok "转发规则已生效（PREROUTING->UU_PORT_FWD 跳转存在）"
        else
            warn "转发链跳转未建立（多为 UU 加速会话未开启或规则为空）"
        fi
    fi
    return 0
}


if [ "${LEGACY_FULL:-0}" != 1 ]; then

    # 安装态校验：只校验「环境类」产物，不触碰容器与 mihomo
    # 注意：不能用 check_cmd——它定义在步骤 10（本块之后），此处调用会 command not found(127)
    FAIL=0
    [ -f "$BASE_DIR/manager.sh" ] || { warn "核心脚本 manager.sh 未落盘"; FAIL=1; }
    [ -f "$BASE_DIR/scripts/proxy_manager.sh" ] || { warn "转发引擎 proxy_manager.sh 未落盘"; FAIL=1; }
    [ -f "$BASE_DIR/scripts/sync_mihomo_rules.sh" ] || { warn "规则同步脚本 sync_mihomo_rules.sh 未落盘"; FAIL=1; }
    [ -x /usr/local/bin/uu ] || { warn "面板入口 /usr/local/bin/uu 不可用"; FAIL=1; }

    echo "12.8" > "$MARKER_FILE" 2>/dev/null || true
    echo ""
    echo -e "${GREEN}=============================================================="
    echo "  安装完成（v12.8）"
    echo "==============================================================${NC}"
    echo ""
    echo -e "  ${CYAN}快捷命令${NC}    : 终端执行 ${YELLOW}uu${NC} 唤出交互面板"
    echo -e "  ${CYAN}安装内容${NC}    : 依赖检查 / 目录结构 / 核心脚本落盘 / uu 命令软链"
    echo -e "  ${CYAN}下一步${NC}      : ${YELLOW}uu${NC} -> 【菜单 1】部署 UU 核心与容器；【菜单 2】安装并启动 mihomo"
    echo -e "  ${CYAN}配置目录${NC}    : ${YELLOW}$BASE_DIR${NC}"
    echo -e "  ${CYAN}部署日志${NC}    : ${YELLOW}$LOG_FILE${NC}"
    echo ""
    if [ "$FAIL" = "0" ]; then
        echo -e "  ${GREEN}环境已就绪。未执行任何业务动作（容器编排 / UU 注入 / mihomo 启动）。${NC}"
    else
        echo -e "  ${YELLOW}存在未通过项（见上方），但不影响后续在面板中操作。${NC}"
    fi
    echo ""
    migrate_legacy_deploy
    exit 0
fi

STEP_NO="7/10 容器编排"
step "步骤 7/10：容器编排（docker-compose）"
if [ "$CHECK_ONLY" = 1 ] || [ "$NO_CONTAINER" = 1 ]; then
    info "自检/不启容器模式：跳过容器编排（不生成 docker-compose.yaml）。"
elif [ -s "$BASE_DIR/docker-compose.yaml" ]; then
    ok "docker-compose.yaml 已存在，保留（如需按新环境重建，请先备份后删除该文件再重跑）"
else
    IFACE="$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    [ -n "$IFACE" ] || die "无法探测默认网卡（ip route show default 无结果），请检查网络配置。"
    HOST_IP="$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)"
    GATEWAY="$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')"
    SUBNET="$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | head -1 | awk -F. '{print $1"."$2"."$3".0/24"}')"
    NETMASK="255.255.255.0"
    for v in IFACE HOST_IP GATEWAY SUBNET; do
        eval "val=\$$v"; [ -n "$val" ] || die "环境探测变量 $v 为空，无法生成 docker-compose.yaml。"
    done
    # 容器 IP：优先用 UU_LAN_IP，否则取同网段 .248 并做冲突探测
    if [ -n "${UU_LAN_IP:-}" ]; then
        LAN_IP="$UU_LAN_IP"
    else
        LAN_IP="$(echo "$HOST_IP" | awk -F. '{print $1"."$2"."$3".248"}')"
    fi
    if ping -c1 -W1 "$LAN_IP" >/dev/null 2>&1; then
        warn "探测到 $LAN_IP 已被占用，仍将按此配置；若启动报地址冲突，请用 UU_LAN_IP=<空闲IP> 重跑"
    fi
    MAC_ADDR="$(gen_mac)"
    info "探测结果: 网卡=$IFACE 宿主IP=$HOST_IP 网关=$GATEWAY 子网=$SUBNET 容器IP=$LAN_IP"

    # 注意：这里绝不主动删除网络。网络名随 compose 项目名（目录名）变化，
    # 硬编码删除会误伤现网正在使用的 macvlan 网络。仅在步骤 8 启动失败时按「空闲」条件清理。
    cat > "$BASE_DIR/docker-compose.yaml" <<EOF_COMPOSE
version: '3.8'
services:
  uuplugin:
    image: ${UU_IMAGE}:${UU_IMAGE_TAG}
    container_name: uuplugin
    restart: always
    privileged: true
    mac_address: "${MAC_ADDR}"
    environment:
      - UU_LAN_IPADDR=${LAN_IP}
      - UU_LAN_GATEWAY=${GATEWAY}
      - UU_LAN_NETMASK=${NETMASK}
    volumes:
      - ./config:/etc/config
      - ./core:/usr/sbin/uu
      - ./rc.local:/etc/rc.local
      - ./mihomo:/etc/mihomo
      - ./conf:/etc/uu_conf
      - ./scripts:/etc/scripts
    networks:
      macnet:
        ipv4_address: ${LAN_IP}
COMPOSE_SIMS_PLACEHOLDER
networks:
  macnet:
    driver: macvlan
    driver_opts:
      parent: ${IFACE}
    ipam:
      config:
        - subnet: ${SUBNET}
          gateway: ${GATEWAY}
EOF_COMPOSE

    if [ "$UU_ENABLE_SIMS" = "1" ]; then
        SIM1="$(echo "$HOST_IP" | awk -F. '{print $1"."$2"."$3".246"}')"
        SIM2="$(echo "$HOST_IP" | awk -F. '{print $1"."$2"."$3".245"}')"
        SIMS_BLOCK="
  ps4_sim_1:
    image: gdfsnhsw/uups:latest
    container_name: PS4
    restart: always
    mac_address: \"$(gen_mac)\"
    networks:
      macnet:
        ipv4_address: ${SIM1}

  ps5_sim_2:
    image: gdfsnhsw/uups:latest
    container_name: PS5
    restart: always
    mac_address: \"$(gen_mac)\"
    networks:
      macnet:
        ipv4_address: ${SIM2}
"
        # 多行文本替换用 awk（sed 处理多行块不可靠）
        awk -v block="$SIMS_BLOCK" '{ if ($0=="COMPOSE_SIMS_PLACEHOLDER") printf "%s", block; else print }' \
            "$BASE_DIR/docker-compose.yaml" > "$BASE_DIR/docker-compose.yaml.tmp" \
            && mv "$BASE_DIR/docker-compose.yaml.tmp" "$BASE_DIR/docker-compose.yaml" \
            || die "写入 PS4/PS5 容器配置失败。"
        ok "已追加 PS4/PS5 模拟容器（${SIM1}/${SIM2}）"
    else
        sed -i "s|COMPOSE_SIMS_PLACEHOLDER||" "$BASE_DIR/docker-compose.yaml"
    fi

    # SELinux（RHEL/CentOS/Fedora）：bind 挂载需加 :z 标签，否则容器无法读写宿主目录
    if command -v getenforce >/dev/null 2>&1; then
        SE_MODE="$(getenforce 2>/dev/null || echo Unknown)"
        if [ "$SE_MODE" = "Enforcing" ] || [ "$SE_MODE" = "Permissive" ]; then
            sed -i -E 's|^([[:space:]]*-[[:space:]]*\./[A-Za-z]+):(/[^[:space:]]+)[[:space:]]*$|\1:\2:z|' \
                "$BASE_DIR/docker-compose.yaml"
            ok "检测到 SELinux=$SE_MODE，已为 bind 挂载追加 :z 标签"
        fi
    fi
    # AppArmor 环境提示（Debian/Ubuntu 默认不影响 macvlan，仅提示）
    if [ -d /sys/kernel/security/apparmor ] && command -v aa-status >/dev/null 2>&1; then
        info "检测到 AppArmor（默认策略不影响本部署；如遇容器权限问题请检查自定义 profile）"
    fi
    ok "docker-compose.yaml 已生成"
fi

# ---------------------------------------------------------------- UCI 配置播种
# docker-compose 把宿主 $BASE_DIR/config bind 到容器 /etc/config。全新安装时宿主目录为空，
# 会【整块遮住镜像自带的 UCI 默认配置】，后果：
#   · fw3  -> "Entry not found / Error: Failed to load /etc/config/firewall" 且 include 段不执行
#   · dnsmasq -> 读不到 /etc/config/dhcp，启动直接失败
# （此前只有 manager.sh 面板菜单会播种，主安装流程没做，属遗漏。）
# 只校验 firewall / dhcp 两项。
# network / system 是 OpenWrt 首次启动时由 config_generate 【运行时生成】的，本就不在镜像里
# （实测新机提取后仍缺这两项，属正常）。若把它们列入清单会永远报"提取不完整"的假警告。
config_seed_needed() {
    local f
    for f in firewall dhcp; do
        [ -s "$BASE_DIR/config/$f" ] || return 0
    done
    return 1
}

# force 参数：即使文件存在也重建（用于 UCI 判定为损坏的场景）
ensure_firewall_uci() {
    local FW="$BASE_DIR/config/firewall" force="${1:-}"
    if [ "$force" = "force" ] || [ ! -s "$FW" ]; then
        cat > "$FW" <<'EOF_UCI_FW'
config defaults
    option syn_flood '0'
    option input 'ACCEPT'
    option output 'ACCEPT'
    option forward 'ACCEPT'

config zone
    option name 'lan'
    option network 'lan'
    option input 'ACCEPT'
    option output 'ACCEPT'
    option forward 'ACCEPT'

config include
    option path '/etc/firewall.user'
EOF_UCI_FW
        chmod 644 "$FW" 2>/dev/null || true
        info "已生成 /etc/config/firewall（最小可用：转发 ACCEPT + include firewall.user）"
    fi
    # 默认转发策略 REJECT -> ACCEPT（本容器只做旁路由，不充当边界防火墙）
    if grep -qE "option[[:space:]]+forward[[:space:]]+'?REJECT" "$FW" 2>/dev/null; then
        cp -a "$FW" "$FW.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        sed -i "s/option[[:space:]]\+forward[[:space:]]*'\{0,1\}REJECT'\{0,1\}/option forward 'ACCEPT'/" "$FW" 2>/dev/null || true
        info "默认转发策略 REJECT 已改为 ACCEPT"
    fi
    # include firewall.user 幂等补齐（缺失才写，重复执行不会堆叠）
    if ! grep -q "/etc/firewall.user" "$FW" 2>/dev/null; then
        printf "\nconfig include\n    option path '/etc/firewall.user'\n" >> "$FW"
        info "已补写 config include -> /etc/firewall.user"
    fi
    return 0
}

ensure_dhcp_uci() {
    local D="$BASE_DIR/config/dhcp"
    [ -s "$D" ] && return 0
    cat > "$D" <<'EOF_UCI_DHCP'
config dnsmasq
    option domainneeded '1'
    option localise_queries '1'
    option rebind_protection '0'
    option local '/lan/'
    option domain 'lan'
    option expandhosts '1'
    option authoritative '1'
    option leasefile '/tmp/dhcp.leases'
    option localservice '1'
    list notinterface 'tun163'
    list notinterface 'tun164'

config dhcp 'lan'
    option interface 'lan'
    option ignore '1'
EOF_UCI_DHCP
    chmod 644 "$D" 2>/dev/null || true
    info "已生成 /etc/config/dhcp（DNS 模式，已关闭 DHCP 避免与主路由冲突）"
    return 0
}

seed_container_config() {
    mkdir -p "$BASE_DIR/config" 2>/dev/null || true
    if ! config_seed_needed; then
        ensure_firewall_uci
        ok "容器 UCI 配置已就绪（firewall/network/dhcp/system 齐备）"
        return 0
    fi
    info "宿主 $BASE_DIR/config 缺少默认配置，正在从镜像 ${UU_IMAGE}:${UU_IMAGE_TAG} 提取..."

    # 先提取到临时目录，再【只补齐缺失文件】——绝不覆盖已存在的配置，
    # 否则会抹掉 UU 写入 /etc/config/firewall 的端口转发规则。
    local TMPSEED="$BASE_DIR/config/.seed.$$"
    mkdir -p "$TMPSEED" 2>/dev/null || true

    # 一级：静态提取（多数镜像 /etc/config/* 是打进镜像的静态文件，无需启动容器）
    docker rm -f uu_tmp_cfg >/dev/null 2>&1 || true
    docker create --name uu_tmp_cfg "${UU_IMAGE}:${UU_IMAGE_TAG}" >/dev/null 2>&1 || true
    docker cp uu_tmp_cfg:/etc/config/. "$TMPSEED/" >/dev/null 2>&1 || true
    docker rm -f uu_tmp_cfg >/dev/null 2>&1 || true

    # 二级：镜像自带为空（部分版本默认值由首次启动生成）-> 起临时容器让 OpenWrt 自己生成
    if [ -z "$(ls -A "$TMPSEED" 2>/dev/null)" ]; then
        info "镜像静态目录下无默认配置，改为启动临时容器由 OpenWrt 生成..."
        docker rm -f uu_tmp_cfg >/dev/null 2>&1 || true
        docker run -d --name uu_tmp_cfg "${UU_IMAGE}:${UU_IMAGE_TAG}" /sbin/init >/dev/null 2>&1 || true
        sleep 8
        docker cp uu_tmp_cfg:/etc/config/. "$TMPSEED/" >/dev/null 2>&1 || true
        docker rm -f uu_tmp_cfg >/dev/null 2>&1 || true
    fi

    local _sf _sb
    for _sf in "$TMPSEED"/* "$TMPSEED"/.[!.]*; do
        [ -e "$_sf" ] || continue
        _sb="$(basename "$_sf")"
        [ -s "$BASE_DIR/config/$_sb" ] && continue
        cp -a "$_sf" "$BASE_DIR/config/$_sb" 2>/dev/null || true
    done
    rm -rf "$TMPSEED" 2>/dev/null || true

    ensure_firewall_uci
    ensure_dhcp_uci
    if config_seed_needed; then
        warn "镜像默认配置提取不完整（仍缺 network/system），容器核心功能以 UU 自身初始化为准"
    else
        ok "容器 UCI 配置已补齐: $(cd "$BASE_DIR/config" && ls -1 2>/dev/null | tr '\n' ' ')"
    fi
    return 0
}

# ---------------------------------------------------------------- 步骤 8
STEP_NO="8/10 启动容器"
step "步骤 8/10：拉取镜像并启动容器"
if [ "$CHECK_ONLY" = 1 ] || [ "$NO_CONTAINER" = 1 ]; then
    info "已跳过容器启动（自检模式或 --no-container）"
else
    cd "$BASE_DIR"
    # 镜像拉取：最多 3 次，失败给出明确原因
    PULLED=0
    for attempt in 1 2 3; do
        if docker compose pull >/dev/null 2>&1 || docker-compose pull >/dev/null 2>&1; then PULLED=1; break; fi
        if docker pull "${UU_IMAGE}:${UU_IMAGE_TAG}" >/dev/null 2>&1; then PULLED=1; break; fi
        warn "第 $attempt 次拉取镜像失败，5 秒后重试..."
        sleep 5
    done
    [ "$PULLED" = 1 ] || die "镜像 ${UU_IMAGE}:${UU_IMAGE_TAG} 拉取失败（已重试 3 次）。
         常见原因：网络不通 / Docker Hub 被限制。可先手动 docker pull 验证，或配置镜像加速器后重跑。"

    # 必须在容器【首次启动之前】播种 UCI 配置：./config bind 到 /etc/config 后，
    # 空宿主目录会遮住镜像自带配置，容器内的 fw3 / dnsmasq 会全部加载失败。
    seed_container_config

    if ! docker compose up -d >/dev/null 2>&1 && ! docker-compose up -d >/dev/null 2>&1; then
        warn "首次启动失败，尝试清理残留的空闲 macvlan 网络后重试（只清理无任何容器挂载的）"
        for _n in $(docker network ls --format '{{.Name}}' 2>/dev/null | grep '_macnet$'); do
            _cnt="$(docker network inspect "$_n" --format '{{len .Containers}}' 2>/dev/null || echo 99)"
            if [ "${_cnt:-99}" = "0" ]; then
                docker network rm "$_n" >/dev/null 2>&1 && info "已清理空闲网络 $_n"
            else
                info "网络 $_n 仍有 ${_cnt} 个容器挂载，保留不动"
            fi
        done
        docker compose up -d >/dev/null 2>&1 || docker-compose up -d >/dev/null 2>&1 \
            || die "容器启动失败（已清理残留网络后仍失败）。
             请执行：cd $BASE_DIR && docker compose up -d 查看具体报错（常见为 macvlan 父网卡错误、IP 冲突或子网不匹配）。"
    fi
    sleep 8
    if ! docker ps --filter name=uuplugin --format '{{.Names}}' | grep -q uuplugin; then
        echo "---- docker logs uuplugin (tail 30) ----"
        docker logs --tail 30 uuplugin 2>/dev/null || true
        die "容器 uuplugin 未进入运行状态，日志见上方。"
    fi
    ok "容器 uuplugin 已运行: $(docker ps --filter name=uuplugin --format '{{.Status}}' | head -1 || true)"
fi

# ---------------------------------------------------------------- 步骤 9
STEP_NO="9/10 系统服务与配置生效"
step "步骤 9/10：系统服务与配置生效"
# 等待容器内在途 restart_mihomo 的上限（rc.local 后台实例最长 60s×3 轮 = 180s，留余量）
MIHOMO_LOCK_WAIT_MAX_SEC="${MIHOMO_LOCK_WAIT_MAX_SEC:-200}"
# 待激活标记：容器内无任何 UU 隧道 -> mihomo 起不来是【预期状态】，不应算部署失败
PENDING_ACTIVATION=0
if [ "$CHECK_ONLY" = 0 ] && [ "$NO_CONTAINER" = 0 ]; then
    # systemd 优先；无 systemd 则写 sysv 风格启动并用 nohup 兜底
    if command -v systemctl >/dev/null 2>&1; then
        cat > /etc/systemd/system/uu-monitor.service <<'EOF_SVC'
[Unit]
Description=UU Plugin Monitor
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/bin/sh /opt/uuplugin/scripts/uu_monitor.sh
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF_SVC
        sed -i "s|/opt/uuplugin/scripts/uu_monitor.sh|$BASE_DIR/scripts/uu_monitor.sh|" /etc/systemd/system/uu-monitor.service
        systemctl daemon-reload
        systemctl enable uu-monitor  >/dev/null 2>&1 || warn "uu-monitor 未设置开机自启"
        systemctl restart uu-monitor >/dev/null 2>&1 || warn "uu-monitor 启动失败（可稍后 systemctl restart uu-monitor）"
        ok "uu-monitor 服务已配置（systemd）"
    else
        warn "未检测到 systemd，使用开机脚本兜底（/etc/rc.local + nohup）"
        grep -q "$BASE_DIR/scripts/uu_monitor.sh" /etc/rc.local 2>/dev/null || \
            echo "nohup /bin/sh $BASE_DIR/scripts/uu_monitor.sh >/dev/null 2>&1 &" >> /etc/rc.local
        chmod +x /etc/rc.local 2>/dev/null || true
        pgrep -f "$BASE_DIR/scripts/uu_monitor.sh" >/dev/null 2>&1 || \
            ( nohup /bin/sh "$BASE_DIR/scripts/uu_monitor.sh" >/dev/null 2>&1 & ) || true
        ok "uu-monitor 已用 rc.local + nohup 兜底启动"
    fi

    cat > /etc/logrotate.d/uu_logs <<EOF_LOGROTATE
$BASE_DIR/log/*.log $BASE_DIR/conf/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
EOF_LOGROTATE
    ok "日志轮转规则已配置"

    # 规则守护：已在运行则不重复拉起
    if docker exec uuplugin sh -c 'ps w 2>/dev/null | grep -q "[w]atch_rules.sh"' 2>/dev/null; then
        ok "转发规则守护 watch_rules 已在运行"
    else
        docker exec -d uuplugin sh -c 'sh /etc/scripts/watch_rules.sh' 2>/dev/null \
            && ok "转发规则守护 watch_rules 已拉起" || warn "watch_rules 拉起失败（不影响手动重载）"
    fi

    docker exec uuplugin sh /etc/scripts/proxy_manager.sh reload >/dev/null 2>&1 \
        && ok "转发引擎已重载" || warn "转发引擎重载未成功（多为 UU 隧道未建立，属正常）"
    # [修复] restart_mihomo.sh 的 acquire_lock 在撞锁时走的是
    #   "已有实例正在执行，本次退出" + exit 0  -> 退出码【0】表示"没干活"，而不是"干成了"。
    # 容器 rc.local 开机就会后台起一个 TUN_WAIT_STRICT=1 的实例，默认要等 60s×3 轮（最多 180s），
    # 期间一直占着 /var/lock/uu_mihomo.lock。步骤 9 恰好落在这个窗口里 -> 撞锁退出 -> rc=0
    # -> 这里误报"已安全重启"，但 mihomo 从未被启动（实测新机显示 OK、进程数却是 0）。
    # 对策：①等容器内在途的 restart_mihomo 收尾；②用短超时参数执行；③以【进程是否真的在】判定。
    MIHOMO_TUN_CNT="$(docker exec uuplugin sh -c 'ip link show tun163 >/dev/null 2>&1 && echo x; ip link show tun164 >/dev/null 2>&1 && echo x' 2>/dev/null | grep -c x || true)"
    MIHOMO_TUN_CNT="${MIHOMO_TUN_CNT:-0}"

    if [ "$MIHOMO_TUN_CNT" = "0" ]; then
        # 无隧道时【刻意不启动 mihomo】：此时启动会让 WG 外层套接字绑定到尚不存在的
        # tun163/tun164，失败后被缓存成 stale bind，之后即便隧道出现也不自愈。
        # 交给 uu-monitor 在隧道上线时拉起，才是正确路径。
        PENDING_ACTIVATION=1
        info "容器无 UU 隧道（tun163/tun164 均不存在）-> 本次【不启动】mihomo，避免 stale bind"
        info "→ 在 UU App 端绑定并开启加速后，uu-monitor 会自动拉起 mihomo，无需重跑本脚本"
    else
        _waited=0
        while docker exec uuplugin sh -c 'ps w 2>/dev/null | grep -q "[r]estart_mihomo.sh"' 2>/dev/null; do
            if [ "$_waited" -ge "$MIHOMO_LOCK_WAIT_MAX_SEC" ]; then
                warn "等待在途 restart_mihomo 超过 ${MIHOMO_LOCK_WAIT_MAX_SEC}s，不再等待"
                break
            fi
            sleep 5
            _waited=$((_waited + 5))
        done
        if [ "$_waited" -gt 0 ]; then info "已等待在途 restart_mihomo 收尾 ${_waited}s（避免撞锁空转）"; fi

        docker exec uuplugin sh -c 'TUN_WAIT_STRICT=0 TUN_WAIT_TIMEOUT_SEC=20 TUN_WAIT_RETRY=1 /bin/sh /etc/scripts/restart_mihomo.sh' >/dev/null 2>&1 || true

        # 判定一律看【进程是否真的在】，不看退出码（撞锁路径 exit 0 但什么也没做）
        if docker exec uuplugin sh -c 'ps w 2>/dev/null | grep -q "[e]tc/mihomo/mihomo"' 2>/dev/null; then
            _mcnt="$(docker exec uuplugin sh -c 'ps w 2>/dev/null | grep -c "[e]tc/mihomo/mihomo"' 2>/dev/null | tr -d ' \n' || true)"
            ok "mihomo 已启动（实际进程数 ${_mcnt:-1}）"
        else
            # 不在此处改 FAIL：步骤 10 会重置 FAIL=0 后按三态规则再判一次，避免两处口径不一致
            warn "mihomo 未启动：隧道已在线（${MIHOMO_TUN_CNT} 条）却没起来，请查看 /etc/uu_conf/mihomo.log"
        fi
    fi
fi

# ---------------------------------------------------------------- 步骤 10
STEP_NO="10/10 验证"
step "步骤 10/10：部署验证"
if [ "$CHECK_ONLY" = 1 ]; then
    echo -e "${GREEN}自检完成：脚本语法、内嵌内容、依赖与平台检查均通过。${NC}"
    echo -e "${CYAN}正式部署请执行：bash $0${NC}"
    exit 0
fi
echo "12.8" > "$MARKER_FILE"

FAIL=0
check_cmd() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else warn "$desc"; FAIL=1; fi; }

check_cmd "manager.sh 存在且可执行"                  test -x "$BASE_DIR/manager.sh"
check_cmd "面板入口 /usr/local/bin/uu 可用"           test -x /usr/local/bin/uu
check_cmd "转发引擎存在且含 TUN 修复标记"             grep -qF "$PROTECT_PROXY_MARKER" "$BASE_DIR/scripts/proxy_manager.sh"
check_cmd "安全重启脚本存在"                          test -x "$BASE_DIR/scripts/restart_mihomo.sh"
check_cmd "mihomo 内核已就位"                         test -x "$BASE_DIR/mihomo/mihomo"
check_cmd "mihomo 配置为 TUN 捕获模式"                grep -q 'device: *mihomo0' "$BASE_DIR/mihomo/config.yaml"
check_cmd "manager.sh 内嵌引擎模板已含 TUN 修复"        grep -qF "$PROTECT_MANAGER_MARKER" "$BASE_DIR/manager.sh"

if [ "$NO_CONTAINER" = 1 ]; then
    warn "已跳过容器相关校验（--no-container）"
else
    check_cmd "容器 uuplugin 运行中"                   sh -c 'docker ps --filter name=uuplugin --format "{{.Names}}" | grep -q uuplugin'
    MIHOMO_PROC="$(docker exec uuplugin sh -c 'ps w 2>/dev/null | grep "[/]etc/mihomo/mihomo" | grep -v grep | wc -l' 2>/dev/null | tr -d ' \n' || true)"
    MIHOMO_PROC="${MIHOMO_PROC:-0}"
    TUN_CNT="$(docker exec uuplugin sh -c 'ip link show tun163 >/dev/null 2>&1 && echo x; ip link show tun164 >/dev/null 2>&1 && echo x' 2>/dev/null | grep -c x || true)"
    TUN_CNT="${TUN_CNT:-0}"
    info "容器内 mihomo 进程数 = ${MIHOMO_PROC}（期望 1）；在线 UU 隧道数 = ${TUN_CNT}"
    # [修复] 旧实现只看进程数：未激活的新设备必然是 0，于是被当成"异常"计入 FAIL，
    # 而实际上隧道都没起来时 mihomo 本就不该运行（否则会 stale bind）。
    # 现在三态判定：正常 / 待激活（不算失败）/ 隧道在线却没起来（真故障）。
    if [ "$MIHOMO_PROC" = "1" ]; then
        ok "mihomo 单实例运行"
    elif [ "$TUN_CNT" = "0" ]; then
        PENDING_ACTIVATION=1
        info "mihomo 未运行：容器无 UU 隧道 -> 判定为「待激活」，不计入失败项"
    else
        warn "mihomo 进程数异常（${MIHOMO_PROC}），且已有 ${TUN_CNT} 条隧道在线 —— 属真实故障"
        FAIL=1
    fi
    # 关键：必须 || true。规则文件为空或只有注释时 grep -v 零匹配 -> 退出码 1，
    # 在 set -o pipefail 下会让整条管道返回非 0 -> 赋值失败 -> 误触发 ERR 陷阱中止部署。
    # 实测：全新设备默认 forward_rules.conf 仅一行注释头，曾在此处直接 die 掉。
    RULE_CNT="$(grep -vE '^[[:space:]]*(#|$)' "$BASE_DIR/conf/forward_rules.conf" 2>/dev/null | wc -l | tr -d ' \n' || true)"
    RULE_CNT="${RULE_CNT:-0}"
    # 逐条规则核对：解析目标后查 mihomo0 是否有对应 /32 路由。
    # 注意「规则数 > 路由数」是正常现象（多条规则可能解析到同一 IP），故按去重目标比对。
    HIT=0; MISS=0
    while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        THOST="$(echo "$line" | cut -d: -f1)"
        [ -n "$THOST" ] || continue
        if echo "$THOST" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            TIP="$THOST"
        else
            # 容器内是 BusyBox：没有 getent（实测 getent: not found），且 awk 对嵌套转义
            # '{print \$1}' 会报非法转义返回非 0（在 set -e 下会误触发中止）。
            # 这里改用与 proxy_manager.sh 一致的 ping 解析路径，并用 cut 取括号内的 IP。
            _pline="$(docker exec uuplugin sh -c "ping -c 1 -W 2 '$THOST' 2>/dev/null | head -1" 2>/dev/null </dev/null || true)"
            case "$_pline" in
                *'('*')'*) TIP="$(echo "$_pline" | cut -d'(' -f2 | cut -d')' -f1 | tr -d ' \n')" ;;
                *)         TIP="" ;;
            esac
        fi
        [ -n "$TIP" ] || { MISS=$((MISS+1)); warn "规则目标无法解析: $THOST"; continue; }
        if docker exec uuplugin sh -c "ip route show dev mihomo0 2>/dev/null | grep -q '^${TIP} '" 2>/dev/null </dev/null; then
            HIT=$((HIT+1))
        else
            MISS=$((MISS+1)); warn "规则目标缺少 mihomo0 路由: $THOST -> $TIP"
        fi
    done < "$BASE_DIR/conf/forward_rules.conf"
    info "逐条核对结果: 命中=${HIT} 缺失=${MISS} （规则数=${RULE_CNT}，去重后目标可能少于规则数，属正常）"
    # 待激活状态下（无隧道 -> mihomo 未启动 -> mihomo0 不存在）规则必然零命中，
    # 这是预期状态，不能计为失败项，否则"首次运行"永远报红。
    if [ "${PENDING_ACTIVATION:-0}" = "1" ]; then
        info "待激活状态：无 UU 隧道（mihomo 引擎已运行但未接管 WARP），跳过 mihomo0 路由命中判定（激活后自动生效）"
    elif [ "${RULE_CNT:-0}" -gt 0 ] && [ "${HIT:-0}" -eq 0 ]; then
        warn "已配置转发规则但 mihomo0 无任何目标路由（多为 UU 加速会话未开启）"; FAIL=1
    else
        ok "转发目标路由状态正常"
    fi
fi

CONT_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' uuplugin 2>/dev/null || echo '未获取')"
echo ""
echo -e "${GREEN}=============================================================="
echo "  部署完成（v12.8）"
echo "==============================================================${NC}"
echo ""
echo -e "  ${CYAN}面板入口${NC}    : 终端执行 ${YELLOW}uu${NC}"
echo -e "  ${CYAN}mihomo 后台${NC} : ${YELLOW}http://${CONT_IP}:9090/ui${NC}  （必须带 :9090 端口）"
echo -e "  ${CYAN}规则文件${NC}    : ${YELLOW}$BASE_DIR/conf/forward_rules.conf${NC}（= 容器内 /etc/uu_conf/forward_rules.conf）"
echo -e "  ${CYAN}本次备份${NC}    : ${YELLOW}$BACKUP_DIR${NC}"
echo -e "  ${CYAN}部署日志${NC}    : ${YELLOW}$LOG_FILE${NC}"
echo -e "  ${CYAN}回滚方式${NC}    : 从 ${YELLOW}$BASE_DIR/backups/<时间戳>/${NC} 取回 .bak 文件覆盖并 chmod 755"
echo ""
if [ "$FAIL" = "0" ] && [ "${PENDING_ACTIVATION:-0}" = "1" ]; then
    echo -e "  ${GREEN}部署全部通过；当前处于「待激活」状态（容器内尚无 UU 隧道）。${NC}"
    echo -e "  ${CYAN}下一步：在 UU App 端绑定本机并开启加速。${NC}"
    echo -e "  ${CYAN}隧道 tun163/tun164 出现后，uu-monitor 会自动拉起 mihomo，无需重跑本脚本。${NC}"
    echo -e "  ${CYAN}自检  : docker exec uuplugin sh -c 'ip link show tun163; ip link show tun164'${NC}"
    echo -e "  ${CYAN}复查  : docker exec uuplugin sh -c 'ps w | grep [/]etc/mihomo/mihomo'${NC}"
elif [ "$FAIL" = "0" ]; then
    echo -e "  ${GREEN}全部校验项通过。${NC}"
else
    echo -e "  ${YELLOW}存在未通过项（见上方 [警告]）。${NC}"
    if [ "${PENDING_ACTIVATION:-0}" = "1" ]; then
        echo -e "  ${YELLOW}注意：本设备当前未激活 UU 加速会话（无 tun163/tun164），mihomo 暂时起不来属预期。${NC}"
    fi
    echo -e "  ${YELLOW}若已开启加速仍失败，请重跑本脚本或执行 uu -> 功能3 -> 5) 重载。${NC}"
fi
echo ""

# =============================================================================
#  [稳定性加固] 落地 firewall.user 并拉起 service_guard 守护
#  纯新增步骤，置于所有原有部署与校验之后；任何失败只告警，不改变原部署结果。
# =============================================================================
deploy_stability_guard() {
    info "部署稳定性加固组件（firewall.user + service_guard 守护）"
    mkdir -p "$BASE_DIR/conf" 2>/dev/null || true
    cat > "$BASE_DIR/conf/firewall.user" <<'EOF_FWUSER_V121'
#!/bin/sh
# 修复脚本：由 fw3 在每次防火墙 (re)start/reload 时执行。
# 根因：/etc/config/firewall 的 wan 区因无法解析设备（无 wan 接口）而未生成 MASQUERADE；
#       且 UU/代理在运行期会重载防火墙（fw3 reload），清空 nat 表，使手动加的规则丢失，
#       导致「手机以本容器为网关时无网络」（出网包无地址伪装，回程不经本容器）。
# 本文件幂等补插 MASQUERADE，并确保 dnsmasq 提供 DNS、稳定性守护在运行。

# 1) 转发出 br-lan/eth0 的流量必须 MASQUERADE（幂等：存在则跳过）
iptables -t nat -C POSTROUTING -o br-lan -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -o br-lan -j MASQUERADE
iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -o eth0 -j MASQUERADE

# 2) 确保 dnsmasq 提供 DNS（dhcp.lan.ignore=1 已关闭 DHCP，不会抢主路由 DHCP）
/etc/init.d/dnsmasq enabled 2>/dev/null && /etc/init.d/dnsmasq start 2>/dev/null || true

# 3) [稳定性加固] 幂等拉起 service_guard 守护
#    覆盖：dnsmasq 存活守护 / WARP alive 恢复即刷新 / 域名定期重解析
#    本文件是唯一能同时扛住「运行期 fw3 reload」与「容器重启」的落点（rc.local 会被 UU 重写）。
if [ -x /etc/scripts/service_guard.sh ]; then
    sh /etc/scripts/service_guard.sh ensure >/dev/null 2>&1 || true
fi

# 4) [E4 修复] 幂等拉起 watch_rules 守护
#    职责：轮询 forward_rules.conf 的 md5，变更即自动同步规则并重载。
#    实测该守护未在运行（且脚本原为 644 无执行位），导致规则文件被手动/第三方
#    修改后不会自动同步。此处与 service_guard 同一幂等模式，且不依赖会被 UU 重写的 rc.local。
#    注意：必须后台脱离执行，绝不能阻塞防火墙重启流程。
if [ -x /etc/scripts/watch_rules.sh ]; then
    if ! ps w 2>/dev/null | grep -q "[w]atch_rules.sh"; then
        ( sh /etc/scripts/watch_rules.sh >/dev/null 2>&1 & )
    fi
fi

exit 0
EOF_FWUSER_V121
    chmod 644 "$BASE_DIR/conf/firewall.user" 2>/dev/null || true

    # firewall.user 不在 bind 挂载列表内（容器 /etc/firewall.user 为独立文件），需 docker cp
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx uuplugin; then
        docker cp "$BASE_DIR/conf/firewall.user" uuplugin:/etc/firewall.user >/dev/null 2>&1 \
            || warn "firewall.user 复制进容器失败"
        docker exec uuplugin sh -c 'chmod 644 /etc/firewall.user' >/dev/null 2>&1 || true

        # 前置自检：/etc/config/firewall 连 uci 都加载不了时，fw3 必然失败。
        # 先备份再重建最小可用配置，让 fw3 走“正常成功”路径，而不是每次都靠兜底。
        if docker exec uuplugin sh -c 'uci -q show firewall >/dev/null 2>&1'; then
            ok "容器 UCI 防火墙配置可正常加载"
        else
            warn "容器 /etc/config/firewall 无法被 uci 加载（可能是 bind 目录为空或文件损坏），备份后重建"
            docker exec uuplugin sh -c 'ls -l /etc/config/ 2>&1 | head -10' 2>/dev/null | sed 's/^/      /' || true
            cp -a "$BASE_DIR/config/firewall" "$BASE_DIR/config/firewall.bad.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
            ensure_firewall_uci force
        fi

        # 关键：MASQUERADE / dnsmasq / service_guard 全部挂在 firewall.user 里，
        # 而 fw3 只有在 restart 成功（rc=0）时才会去执行 include 段。OpenWrt 在 macvlan 容器里
        # 对并不存在的 wan/wan6 网络必然告警（实测 Wilson / trixie 新机一致）：
        #   Warning: Section @zone[1] (wan) cannot resolve device of network 'wan'
        #   Warning: Section @zone[1] (wan) cannot resolve device of network 'wan6'
        # 另有一种更糟的情况：./config bind 后宿主目录为空 -> fw3 直接报
        #   Entry not found / Error: Failed to load /etc/config/firewall
        # 结果：restart 返回非 0（甚至长时间挂住）-> firewall.user 从不执行 -> 守护起不来，
        # 于是出现「防火墙重载失败 / service_guard 未运行 / dnsmasq 未运行」三连警告。
        # 对策：①先修 UCI 配置本身；②用 timeout 兜住可能的挂起；③失败/超时则绕过 fw3 直接执行 firewall.user。
        # [v12.7 关键重构] 不再把 fw3 的成功当作前置条件。
        # 实测：纯净临时容器里 fw3 restart 只要 2s（rc=0）；但在运行中的 uuplugin 容器里
        # 会【间歇性挂住 >90s】（rc=124），且 xtables 锁并不总是被占用 —— 属偶发、外部不可控。
        # 而真正需要的东西（MASQUERADE / dnsmasq / service_guard / watch_rules）全在
        # /etc/firewall.user 里，直接执行它只要 1 秒且幂等。
        # 新顺序：①先执行 firewall.user 保证功能到位；②后台限时跑一次 fw3（保持其自身规则集
        # 一致，不阻塞主流程）；③fw3 若中途 flush 过 nat，最后再补一次 firewall.user。
        FW_RESTART_TMO="${FW_RESTART_TMO:-30}"

        docker exec uuplugin sh -c 'sh /etc/firewall.user' >/dev/null 2>&1 \
            && ok "firewall.user 已执行（MASQUERADE / dnsmasq / 守护 一次到位）" \
            || warn "firewall.user 执行失败"

        local _fw_out _fw_rc
        _fw_out="/tmp/uu_fw3_out.$$"
        : > "$_fw_out" 2>/dev/null || _fw_out=/dev/null
        _fw_rc=0
        if command -v timeout >/dev/null 2>&1; then
            timeout "$FW_RESTART_TMO" docker exec uuplugin /etc/init.d/firewall restart >"$_fw_out" 2>&1 || _fw_rc=$?
        else
            docker exec uuplugin /etc/init.d/firewall restart >"$_fw_out" 2>&1 || _fw_rc=$?
        fi
        if [ "$_fw_rc" -eq 0 ]; then
            ok "防火墙已重载（fw3 restart 成功）"
        elif [ "$_fw_rc" -eq 124 ]; then
            warn "fw3 restart 超时（> ${FW_RESTART_TMO}s）—— 已跳过，核心规则不受影响"
            tail -n 3 "$_fw_out" 2>/dev/null | sed 's/^/      /' || true
        else
            warn "fw3 restart 返回 ${_fw_rc}（多为 \"cannot resolve device of network 'wan'\"）—— 已跳过，核心规则不受影响"
            tail -n 3 "$_fw_out" 2>/dev/null | sed 's/^/      /' || true
        fi
        # fw3 重启过程会清空 nat 表；无论它成功与否，最后再补一次确保终态正确（幂等）
        docker exec uuplugin sh -c 'sh /etc/firewall.user' >/dev/null 2>&1 \
            && ok "firewall.user 复核执行完成（终态一致）" \
            || warn "firewall.user 复核执行失败"

        # service_guard 兜底：无论 firewall.user 是否生效，这里再确保一次（幂等）
        docker exec uuplugin sh -c 'sh /etc/scripts/service_guard.sh ensure' >/dev/null 2>&1 || true
        sleep 3

        if docker exec uuplugin sh -c 'sh /etc/scripts/service_guard.sh status' 2>/dev/null | grep -q "运行中"; then
            ok "service_guard 守护已运行"
        else
            # [修复] 原来这里用容器内的 nohup 兜底，但 uuplugin 容器【根本没有 nohup】
            # （实测 command -v nohup -> MISSING），该命令必然失败，兜底形同虚设。
            # 改用 docker exec -d：由 Docker 守护进程托管分离执行，不依赖容器内任何外部命令。
            docker exec -d uuplugin /bin/sh -c 'sh /etc/scripts/service_guard.sh ensure' >/dev/null 2>&1 || true
            sleep 3
            docker exec uuplugin sh -c 'sh /etc/scripts/service_guard.sh status' 2>/dev/null | grep -q "运行中" \
                && ok "service_guard 守护已拉起（docker exec -d 兜底）" \
                || warn "service_guard 守护未运行，可手动执行: docker exec uuplugin sh /etc/scripts/service_guard.sh ensure"
        fi

        if docker exec uuplugin sh -c 'ps w 2>/dev/null | grep -q [d]nsmasq'; then
            ok "dnsmasq 已运行"
        else
            docker exec uuplugin /etc/init.d/dnsmasq start >/dev/null 2>&1 || true
            sleep 2
            docker exec uuplugin sh -c 'ps w 2>/dev/null | grep -q [d]nsmasq' \
                && ok "dnsmasq 已启动（兜底方式）" \
                || warn "dnsmasq 未运行（守护将在下一个检查周期自动拉起）"
        fi

        # ---- 开机自愈钩子（不依赖 fw3）----
        # 上面的兜底只解决「本次安装」。容器重启后 fw3 依旧会因 wan 告警失败，
        # firewall.user 照样不执行 -> MASQUERADE / 守护全部丢失。
        # 故另挂一个 START=99 的 init 脚本，由 OpenWrt 开机序列末尾直接补执行。
        cat > "$BASE_DIR/conf/uu_guard_boot" <<'EOF_BOOTGUARD_V121'
#!/bin/sh /etc/rc.common
# uu_guard_boot —— 独立于 fw3 的开机兜底
# 背景：macvlan 容器里没有 wan/wan6 网络，fw3 必然报
#   "Section @zone[1] (wan) cannot resolve device of network 'wan'"
# 并使 restart 返回非 0，导致 /etc/firewall.user（firewall include 段）不执行，
# MASQUERADE / dnsmasq / service_guard 全部丢失。本脚本在开机序列末尾直接补执行。
START=99
STOP=01

start() {
    [ -f /etc/firewall.user ] && sh /etc/firewall.user >/dev/null 2>&1
    [ -x /etc/scripts/service_guard.sh ] && sh /etc/scripts/service_guard.sh ensure >/dev/null 2>&1
    return 0
}

stop() {
    return 0
}

restart() {
    start
}
EOF_BOOTGUARD_V121
        chmod 755 "$BASE_DIR/conf/uu_guard_boot" 2>/dev/null || true
        docker cp "$BASE_DIR/conf/uu_guard_boot" uuplugin:/etc/init.d/uu_guard_boot >/dev/null 2>&1 || true
        docker exec uuplugin sh -c 'chmod 755 /etc/init.d/uu_guard_boot 2>/dev/null; /etc/init.d/uu_guard_boot enable' >/dev/null 2>&1 || true
        docker exec uuplugin sh -c 'ls /etc/rc.d/S99uu_guard_boot' >/dev/null 2>&1 \
            && ok "开机自愈钩子已启用（/etc/rc.d/S99uu_guard_boot -> firewall.user + service_guard）" \
            || warn "开机自愈钩子启用失败（不影响本次部署，重跑本脚本可重试）"
    else
        warn "容器 uuplugin 未运行，跳过 firewall.user 落地（容器启动后 fw3 会自动执行）"
    fi

    # ---- [E2] dnsmasq 不再监听 tun163/tun164 ----
    # 隧道仅在 UU 加速会话激活时存在，dnsmasq 尝试绑定其地址会报
    # "failed to create listening socket ... Address not available"（实测 12 条）。
    # 幂等：已含 notinterface 则跳过。
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx uuplugin; then
        docker cp uuplugin:/etc/config/dhcp "$BASE_DIR/conf/dhcp.orig" 2>/dev/null || true
        if [ -f "$BASE_DIR/conf/dhcp.orig" ] && ! grep -q "notinterface" "$BASE_DIR/conf/dhcp.orig" 2>/dev/null; then
            printf "\tlist notinterface 'tun163'\n\tlist notinterface 'tun164'\n" > "$BASE_DIR/conf/dhcp.notinterface"
            sed '/^config dnsmasq[[:space:]]*$/r '"$BASE_DIR/conf/dhcp.notinterface" "$BASE_DIR/conf/dhcp.orig" > "$BASE_DIR/conf/dhcp.new"
            if [ -s "$BASE_DIR/conf/dhcp.new" ]; then
                docker cp "$BASE_DIR/conf/dhcp.new" uuplugin:/etc/config/dhcp 2>/dev/null || true
                docker exec uuplugin /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
                echo "[uu-monitor] 已为 dnsmasq 添加 notinterface(tun163/tun164)"
            fi
            rm -f "$BASE_DIR/conf/dhcp.new" "$BASE_DIR/conf/dhcp.notinterface" 2>/dev/null
        else
            echo "[uu-monitor] dnsmasq 已配置 notinterface，跳过"
        fi
        rm -f "$BASE_DIR/conf/dhcp.orig" 2>/dev/null

        # ---- [E1] 收敛 uuplugin_monitor 为单实例 ----
        # 容器 init 与 UU 自启动会各拉起一次，实测出现 2 个实例
        # （PID 1511 路径 uu/ 、PID 3706 路径 uu//），主进程崩溃时会并发拉起。
        # 脚本自身已加 flock 自锁；此处再做一次实例收敛作为兜底（幂等）。
        docker exec uuplugin sh -c '
            cnt=$(ps w 2>/dev/null | grep -c "[u]uplugin_monitor")
            if [ "$cnt" -gt 1 ]; then
                keep=$(ps w 2>/dev/null | grep "[u]uplugin_monitor" | sed "s/^[[:space:]]*//" | cut -d" " -f1 | head -n1)
                for p in $(ps w 2>/dev/null | grep "[u]uplugin_monitor" | sed "s/^[[:space:]]*//" | cut -d" " -f1); do
                    [ "$p" = "$keep" ] || kill "$p" 2>/dev/null
                done
                echo "[uu-monitor] 已收敛 uuplugin_monitor 实例数: $cnt -> 1"
            fi
        ' 2>/dev/null || true
    fi

}
deploy_stability_guard || true

exit 0

# =============================================================================
#  变更说明（v11.0 → v12.0，2026-09-23）
# -----------------------------------------------------------------------------
#  改动点：
#    1) 新增备份保留策略变量：KEEP_CONFIG_BACKUPS（默认 3）、BACKUP_KEEP_MARKER（默认 .keep）
#    2) 内嵌 sync_mihomo_rules.sh 新增 prune_config_backups()：
#       备份创建成功后按时间戳滚动删除最旧的，仅保留最新 KEEP_CONFIG_BACKUPS 份
#    3) 严格匹配范围：仅处理 config.yaml.bak.<ts> / config.yaml.<ts>.bak，
#       绝不触碰 config.yaml 本体、mihomo 二进制、rules/*.yaml 及其它 .bak
#    4) 豁免：文件名含 BACKUP_KEEP_MARKER 的备份永不删除且不占保留名额
#    5) 例外：目录不存在 / 无备份 / 备份数 ≤ N 时跳过；rm 失败只告警不中断主流程
#    6) 头部补充修改日期，并修正 MIHOMO_VERSION 文档（v1.19.21 → v1.19.31，与实现一致）
#
#  版本号变更： v11.0 → v12.0（.deploy_version 标记文件同步为 12.0）
#
#  与新策略冲突 / 写死的保留参数及建议值：
#    · UU_RETAIN_BACKUPS（第 47 行附近，默认 10）
#        作用域：$BASE_DIR/backups/<时间戳>/ （部署级整目录备份）
#        与新策略不冲突（作用域不同），但数值偏大，建议 10 → 5，减少磁盘占用
#    · 头部注释 MIHOMO_VERSION 默认 v1.19.21（已修正为 v1.19.31，与代码一致）
#    · sync_mihomo_rules.sh 中 fwd_warp163/164.yaml.bak.<ts> 目前【无保留策略】，
#        实测已堆积 267 份，建议复用同一清理函数并设 KEEP_RULES_BACKUPS=5
# =============================================================================
