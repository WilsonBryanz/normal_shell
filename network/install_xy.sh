#!/bin/bash

# ================= 颜色定义 =================
C_RED='\033[1;31m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[1;36m'
C_CYAN='\033[1;36m'
C_PURPLE='\033[1;35m'
C_RESET='\033[0m'
# ============================================

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${C_RED}[错误] 请使用 root 权限运行此脚本！(sudo bash install.sh)${C_RESET}"
  exit 1
fi

# ================= 全局快捷命令部署 =================
mkdir -p /opt/xunyou
if [ "$(readlink -f "$0")" != "/opt/xunyou/manager.sh" ]; then
    cp "$0" /opt/xunyou/manager.sh
    chmod +x /opt/xunyou/manager.sh
    ln -sf /opt/xunyou/manager.sh /usr/local/bin/xy
    echo -e "${C_CYAN}==================================================${C_RESET}"
    echo -e "${C_GREEN}[提示] 快捷启动命令部署成功！${C_RESET}"
    echo -e "${C_YELLOW}以后在终端任意位置直接输入 ${C_GREEN}xy${C_YELLOW} 并回车，即可快速打开本面板！${C_RESET}"
    echo -e "${C_CYAN}==================================================${C_RESET}"
    sleep 2
fi

cd /opt/xunyou

# 兼容 docker-compose 命令 (优先 V2，兼容 V1)
DOCKER_CMD="docker compose"
if docker compose version &> /dev/null; then
    DOCKER_CMD="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_CMD="docker-compose"
else
    DOCKER_CMD=""
fi

# ================= 依赖检查模块 =================
function check_dependencies() {
    echo -e "${C_BLUE}>>> 正在检查系统依赖环境...${C_RESET}"
    local MISSING_PKGS=()
    for cmd in curl wget tar awk ip; do
        if ! command -v $cmd &> /dev/null; then
            local pkg=$cmd
            [ "$cmd" == "ip" ] && pkg="iproute2"
            [ "$cmd" == "awk" ] && pkg="gawk"
            MISSING_PKGS+=($pkg)
        fi
    done

    if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
        echo -e "${C_YELLOW}发现缺失基础组件: ${MISSING_PKGS[*]}，正在自动安装...${C_RESET}"
        apt-get update -y -q > /dev/null 2>&1
        apt-get install -y -q ${MISSING_PKGS[@]} > /dev/null 2>&1
    fi

    if ! command -v docker &> /dev/null; then
        echo -e "${C_YELLOW}未检测到 Docker，正在自动安装...${C_RESET}"
        curl -fsSL https://get.docker.com | bash
        systemctl enable docker; systemctl start docker
    fi

    if [ -z "$DOCKER_CMD" ]; then
        echo -e "${C_YELLOW}未检测到 Docker Compose，正在自动安装...${C_RESET}"
        apt-get update -y -q > /dev/null 2>&1
        apt-get install -y -q docker-compose-plugin > /dev/null 2>&1
        if docker compose version &> /dev/null; then
            DOCKER_CMD="docker compose"
        else
            DOCKER_CMD="docker-compose"
        fi
    fi
}

# ================= 端口转发脚本生成模块 =================
function generate_port_forward_script() {
    cat > /opt/xunyou/port_forward.sh << 'EOF'
#!/bin/bash
# ================= 颜色定义 =================
C_RED='\033[1;31m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[1;36m'
C_PURPLE='\033[1;35m'
C_CYAN='\033[1;36m'
C_RESET='\033[0m'
# ============================================

CONTAINER_NAME="xunyou_sim"
VPN_IF="tun199"
CONF_DIR="/opt/xunyou"
CONF_FILE="${CONF_DIR}/forward_rules.conf"

mkdir -p "$CONF_DIR" 2>/dev/null || { echo -e "${C_RED}[错误] 无法创建目录 $CONF_DIR，请使用 sudo${C_RESET}"; exit 1; }
touch "$CONF_FILE"

function check_env() {
    if ! docker ps --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}\$"; then
        echo -e "${C_RED}[错误] 容器 ${CONTAINER_NAME} 未运行！${C_RESET}"
        return 1
    fi
    if ! docker exec $CONTAINER_NAME ip link show $VPN_IF > /dev/null 2>&1; then
        echo -e "${C_RED}[错误] 容器内未找到 $VPN_IF 网卡！${C_RESET}"
        return 1
    fi
    return 0
}

function apply_rules() {
    check_env || return 1
    echo -e "${C_BLUE}>>> 重置容器转发规则...${C_RESET}"
    docker exec $CONTAINER_NAME iptables -t nat -F PREROUTING 2>/dev/null
    docker exec $CONTAINER_NAME iptables -t nat -F POSTROUTING 2>/dev/null
    docker exec $CONTAINER_NAME iptables -t nat -A POSTROUTING -o $VPN_IF -j MASQUERADE

    local count=0
    while IFS=':' read -r TARGET_HOST LOCAL_PORT REMOTE_PORT; do
        [ -z "$TARGET_HOST" ] && continue
        REAL_IP=$(getent ahostsv4 "$TARGET_HOST" | awk '{ print $1 }' | head -n 1)
        if [ -z "$REAL_IP" ]; then
            echo -e "${C_RED}  -> [跳过] 无法解析: $TARGET_HOST${C_RESET}"
            continue
        fi
        REMOTE_PORT=${REMOTE_PORT:-$LOCAL_PORT}
        echo -e "  -> 映射: [${C_GREEN}$LOCAL_PORT${C_RESET}] -> ${C_YELLOW}$REAL_IP:$REMOTE_PORT${C_RESET}"
        docker exec $CONTAINER_NAME iptables -t nat -A PREROUTING -p tcp --dport $LOCAL_PORT -j DNAT --to-destination $REAL_IP:$REMOTE_PORT
        docker exec $CONTAINER_NAME iptables -t nat -A PREROUTING -p udp --dport $LOCAL_PORT -j DNAT --to-destination $REAL_IP:$REMOTE_PORT
        docker exec $CONTAINER_NAME ip route add $REAL_IP dev $VPN_IF metric 1 2>/dev/null
        ((count++))
    done < "$CONF_FILE"
    echo -e "${C_GREEN}[成功] 已加载 $count 条规则。${C_RESET}"
}

function interactive_add() {
    echo -e "${C_PURPLE}----------------------------------------${C_RESET}"
    echo -en "1. 落地机 IP/域名: "
    read host
    [ -z "$host" ] && { echo "已取消"; return; }
    echo -en "2. 容器本地监听端口: "
    read l_port
    [ -z "$l_port" ] && { echo "已取消"; return; }
    echo -en "3. 落地机目标端口 (回车默认同本地端口): "
    read r_port
    [ -z "$r_port" ] && r_port=$l_port

    local RULE="${host}:${l_port}:${r_port}"
    if grep -q "^${RULE}$" "$CONF_FILE"; then
        echo -e "${C_YELLOW}规则已存在。${C_RESET}"
    else
        echo "$RULE" >> "$CONF_FILE"
        echo -e "${C_GREEN}[记录] 新增: $RULE${C_RESET}"
        apply_rules
    fi
}

function interactive_del() {
    echo -e "${C_PURPLE}----------------------------------------${C_RESET}"
    if [ ! -s "$CONF_FILE" ]; then 
        echo -e "${C_YELLOW}(暂无规则)${C_RESET}"; return
    fi
    local index=1
    while IFS=':' read -r HOST L_PORT R_PORT; do
        [ -z "$HOST" ] && continue
        echo -e "${C_GREEN}${index})${C_RESET} 本地 ${L_PORT} -> ${C_YELLOW}${HOST}:${R_PORT}${C_RESET}"
        ((index++))
    done < "$CONF_FILE"
    echo -en "请输入要删除的编号: "
    read num
    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -lt "$index" ]; then
        sed -i "${num}d" "$CONF_FILE"
        echo -e "${C_GREEN}规则已删除。${C_RESET}"
        apply_rules
    else
        echo -e "${C_YELLOW}输入无效。${C_RESET}"
    fi
}

function list_rules() {
    echo -e "${C_PURPLE}------------------------------------------------${C_RESET}"
    printf "${C_BLUE}%-20s | %-10s | %-10s${C_RESET}\n" "目标主机" "本地端口" "远程端口"
    echo -e "${C_PURPLE}------------------------------------------------${C_RESET}"
    if [ ! -s "$CONF_FILE" ]; then
        echo -e "${C_YELLOW}(暂无规则)${C_RESET}"
    else
        while IFS=':' read -r HOST L_PORT R_PORT; do
            [ -z "$HOST" ] && continue
            printf "%-20s | %-10s | %-10s\n" "$HOST" "$L_PORT" "$R_PORT"
        done < "$CONF_FILE"
    fi
    echo -e "${C_PURPLE}------------------------------------------------${C_RESET}"
}

function setup_systemd() {
    cat > /etc/systemd/system/xunyou-forward.service << SYSTEMD_EOF
[Unit]
Description=Xunyou Auto Port Forwarding Monitor
After=docker.service
Requires=docker.service
[Service]
Type=simple
ExecStart=/bin/bash $(readlink -f $0) monitor
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
SYSTEMD_EOF
    systemctl daemon-reload && systemctl enable xunyou-forward && systemctl restart xunyou-forward
    echo -e "${C_GREEN}[成功] 监控服务已开机自启！${C_RESET}"
}

function restart_monitor() {
    if systemctl is-active --quiet xunyou-forward; then
        echo -e "${C_BLUE}>>> 正在重启后台守护服务...${C_RESET}"
        systemctl restart xunyou-forward
        echo -e "${C_GREEN}[成功] 守护服务已成功重启！${C_RESET}"
    else
        echo -e "${C_YELLOW}[提示] 守护服务未运行，请先选择 [5] 部署守护。${C_RESET}"
    fi
}

# 主逻辑
if [ "$1" == "monitor" ]; then
    while true; do
        if docker ps -q -f name=^${CONTAINER_NAME}$ | grep -q . && docker exec $CONTAINER_NAME ip link show $VPN_IF > /dev/null 2>&1; then
            apply_rules > /dev/null 2>&1
        fi
        sleep 30
    done
else
    while true; do
        clear
        echo -e "${C_CYAN}==================================================${C_RESET}"
        echo -e "${C_YELLOW}          迅游 Docker 端口转发管理面板            ${C_RESET}"
        echo -e "${C_CYAN}==================================================${C_RESET}"
        echo -e " ${C_GREEN}[1]${C_RESET} 列表 - 查看当前映射规则"
        echo -e " ${C_GREEN}[2]${C_RESET} 添加 - 添加新的映射规则"
        echo -e " ${C_GREEN}[3]${C_RESET} 删除 - 删除已有映射规则"
        echo -e " ${C_GREEN}[4]${C_RESET} 刷新 - 强制生效所有规则"
        echo -e " ${C_GREEN}[5]${C_RESET} 守护 - 部署开机自启监控"
        echo -e " ${C_GREEN}[6]${C_RESET} 重启 - 重启后台守护进程"
        echo -e " ${C_GREEN}[0]${C_RESET} 返回 - 返回主菜单"
        echo -e "${C_CYAN}==================================================${C_RESET}"
        echo -en "${C_YELLOW}请选择 [0-6]: ${C_RESET}"
        read choice
        case $choice in
            1) list_rules; echo -en "按回车继续... "; read -r ;;
            2) interactive_add; echo -en "按回车继续... "; read -r ;;
            3) interactive_del; echo -en "按回车继续... "; read -r ;;
            4) apply_rules; echo -en "按回车继续... "; read -r ;;
            5) setup_systemd; echo -en "按回车继续... "; read -r ;;
            6) restart_monitor; echo -en "按回车继续... "; read -r ;;
            0) break ;;
        esac
    done
fi
EOF
    chmod +x /opt/xunyou/port_forward.sh
}

# ================= 迅游核心 操作模块 =================
function install_xunyou() {
    clear
    echo -e "${C_CYAN}==================================================${C_RESET}"
    echo -e "${C_YELLOW}             >>> 迅游加速核心安装 <<<             ${C_RESET}"
    echo -e "${C_CYAN}==================================================${C_RESET}"
    
    check_dependencies
    if docker ps -a --format '{{.Names}}' | grep -Eq "^xunyou_sim$"; then
        echo -e "${C_GREEN}[提示] 迅游容器 (xunyou_sim) 已存在！${C_RESET}"
        echo -e "如需更换版本或配置，请先卸载或手动删除配置。"
        echo -en "${C_PURPLE}按回车键继续... ${C_RESET}"
        read -r
        return
    fi

    echo -e "\n${C_BLUE}>>> 请配置迅游参数...${C_RESET}"
    echo -en "${C_GREEN}1. 迅游镜像版本 ${C_YELLOW}[默认: v2.0]${C_RESET}: "
    read XUNYOU_VER
    XUNYOU_VER=${XUNYOU_VER:-v2.0}

    DEFAULT_IFACE=$(ip route get 1 | awk '{print $5; exit}')
    DEFAULT_GATEWAY=$(ip route show default | awk '/default/ {print $3}')
    DEFAULT_SUBNET=$(ip -o -f inet addr show $DEFAULT_IFACE | awk '{print $4}' | head -n 1 | sed 's/\.[0-9]*\//\.0\//')
    
    echo -en "${C_GREEN}2. 局域网子网段 ${C_YELLOW}[默认: ${DEFAULT_SUBNET:-10.10.0.0/24}]${C_RESET}: "
    read SUBNET
    SUBNET=${SUBNET:-${DEFAULT_SUBNET:-10.10.0.0/24}}

    echo -en "${C_GREEN}3. 局域网网关 IP ${C_YELLOW}[默认: ${DEFAULT_GATEWAY:-10.10.0.1}]${C_RESET}: "
    read GATEWAY
    GATEWAY=${GATEWAY:-${DEFAULT_GATEWAY:-10.10.0.1}}

    echo -en "${C_GREEN}4. 网关容器独立 IP ${C_YELLOW}[默认: 10.10.0.254]${C_RESET}: "
    read CONTAINER_IP
    CONTAINER_IP=${CONTAINER_IP:-10.10.0.254}

    echo -en "${C_GREEN}5. 物理网卡名称 ${C_YELLOW}[默认: $DEFAULT_IFACE]${C_RESET}: "
    read IFACE
    IFACE=${IFACE:-$DEFAULT_IFACE}

    echo "$CONTAINER_IP" > /opt/xunyou/.xunyou_ip

    echo -e "\n${C_BLUE}>>> 正在生成配置并启动迅游容器 (版本: ${XUNYOU_VER})...${C_RESET}"
    mkdir -p /opt/xunyou/xunyou_logs

    # 包含 ipv6 转发参数
    cat > /opt/xunyou/docker-compose-xunyou.yml << EOF
version: '3'
services:
  xunyou-sim:
    image: wstxwd007/xunyou-sim-deck:${XUNYOU_VER}
    container_name: xunyou_sim
    restart: unless-stopped
    privileged: true
    environment:
      - STEAM_DECK=1
      - HOME=/home/deck
      - TZ=Asia/Shanghai
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.rp_filter=0
      - net.ipv4.conf.default.rp_filter=0
      - net.ipv6.conf.all.forwarding=1
    networks:
      xunyou_net:
        ipv4_address: ${CONTAINER_IP}
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - /lib/modules:/lib/modules:ro
      - ./xunyou_logs:/tmp/xunyou/log
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

networks:
  xunyou_net:
    driver: macvlan
    driver_opts:
      parent: ${IFACE}
    ipam:
      config:
        - subnet: ${SUBNET}
          gateway: ${GATEWAY}
          ip_range: ${CONTAINER_IP}/32
EOF

    generate_port_forward_script
    $DOCKER_CMD -f /opt/xunyou/docker-compose-xunyou.yml up -d

    echo -e "${C_GREEN}==================================================${C_RESET}"
    echo -e "${C_GREEN}[成功] 迅游加速核心安装完成！${C_RESET}"
    echo -e "容器 IP: ${C_YELLOW}$CONTAINER_IP${C_RESET}"
    echo -e "请在手机迅游 App 上找到设备并点击【开启加速】。"
    echo -e "${C_GREEN}==================================================${C_RESET}"
    echo -en "${C_PURPLE}按回车键继续... ${C_RESET}"
    read -r
}

function update_xunyou() {
    if [ ! -f "/opt/xunyou/docker-compose-xunyou.yml" ]; then
        echo -e "${C_RED}[错误] 找不到迅游配置文件！请先执行安装。${C_RESET}"
        echo -en "${C_PURPLE}按回车键继续... ${C_RESET}"
        read -r
        return
    fi

    local CURRENT_IMAGE=$(grep -E 'image:.*xunyou-sim-deck' /opt/xunyou/docker-compose-xunyou.yml | awk '{print $2}')
    local CURRENT_TAG=$(echo $CURRENT_IMAGE | awk -F':' '{print $2}')
    CURRENT_TAG=${CURRENT_TAG:-v2.0}

    echo -e "${C_BLUE}>>> 当前版本: ${C_YELLOW}${CURRENT_TAG}${C_RESET}"
    echo -en "${C_GREEN}请输入新版本号 (回车则仅拉取最新): ${C_RESET}"
    read NEW_TAG

    if [ -n "$NEW_TAG" ] && [ "$NEW_TAG" != "$CURRENT_TAG" ]; then
        echo -e "${C_BLUE}正在切换版本: ${CURRENT_TAG} -> ${NEW_TAG}${C_RESET}"
        sed -i "s|image: wstxwd007/xunyou-sim-deck:.*|image: wstxwd007/xunyou-sim-deck:${NEW_TAG}|g" /opt/xunyou/docker-compose-xunyou.yml
    fi

    $DOCKER_CMD -f /opt/xunyou/docker-compose-xunyou.yml pull
    $DOCKER_CMD -f /opt/xunyou/docker-compose-xunyou.yml up -d
    docker image prune -f
    echo -e "${C_GREEN}[成功] 迅游更新完毕！${C_RESET}"
    echo -en "${C_PURPLE}按回车键继续... ${C_RESET}"
    read -r
}

function restart_xunyou() {
    echo -e "${C_BLUE}>>> 正在重启迅游核心容器...${C_RESET}"
    if docker restart xunyou_sim > /dev/null 2>&1; then
        echo -e "${C_GREEN}[成功] 迅游容器已重启！${C_RESET}"
    else
        echo -e "${C_RED}[错误] 容器重启失败，请检查是否已安装。${C_RESET}"
    fi
    echo -en "${C_PURPLE}按回车键继续... ${C_RESET}"
    read -r
}

function uninstall_xunyou() {
    echo -en "${C_RED}[警告] 这将删除迅游容器。确认吗？(yes/no): ${C_RESET}"
    read confirm
    if [[ "$confirm" == "yes" || "$confirm" == "y" ]]; then
        if [ -f "/opt/xunyou/docker-compose-xunyou.yml" ]; then
            $DOCKER_CMD -f /opt/xunyou/docker-compose-xunyou.yml down
            rm -f /opt/xunyou/docker-compose-xunyou.yml
            systemctl stop xunyou-forward 2>/dev/null
            systemctl disable xunyou-forward 2>/dev/null
        else
            docker rm -f xunyou_sim 2>/dev/null
        fi
        rm -f /opt/xunyou/.xunyou_ip
        echo -e "${C_GREEN}[成功] 迅游容器已卸载。${C_RESET}"
    fi
    echo -en "${C_PURPLE}按回车键继续... ${C_RESET}"
    read -r
}

# ================= Mihomo核心 操作模块 =================
function install_mihomo() {
    clear
    echo -e "${C_CYAN}==================================================${C_RESET}"
    echo -e "${C_YELLOW}             >>> Mihomo 代理核心安装 <<<          ${C_RESET}"
    echo -e "${C_CYAN}==================================================${C_RESET}"

    check_dependencies

    if ! docker ps -a --format '{{.Names}}' | grep -Eq "^xunyou_sim$"; then
        echo -e "${C_RED}[错误] 未检测到迅游容器，请先安装迅游！${C_RESET}"
        echo -en "${C_PURPLE}按回车键继续... ${C_RESET}"
        read -r
        return
    fi

    if docker ps -a --format '{{.Names}}' | grep -Eq "^mihomo_core$"; then
        echo -e "${C_GREEN}[提示] Mihomo 容器 (mihomo_core) 已存在！${C_RESET}"
        echo -en "${C_PURPLE}按回车键继续... ${C_RESET}"
        read -r
        return
    fi

    local CONTAINER_IP="10.10.0.254"
    [ -f "/opt/xunyou/.xunyou_ip" ] && CONTAINER_IP=$(cat /opt/xunyou/.xunyou_ip)

    echo -e "\n${C_BLUE}>>> 请配置代理与节点参数...${C_RESET}"
    
    echo -en "${C_GREEN}1. Shadowsocks 入站密码 ${C_YELLOW}[默认: MySecretSSPassword123]${C_RESET}: "
    read SS_PASS
    SS_PASS=${SS_PASS:-MySecretSSPassword123}

    echo -en "${C_GREEN}2. WARP IPv6 地址 ${C_YELLOW}[例: 2606.../128]${C_RESET}: "
    read WARP_IPV6
    WARP_IPV6=${WARP_IPV6:-"2606:4700:110:8528:8b5b:66d3:e6d9:8930/128"}

    echo -en "${C_GREEN}3. WARP Private Key (私钥) ${C_RESET}: "
    read WARP_KEY
    WARP_KEY=${WARP_KEY:-"OPPUcAY5cUD7JdPgMmiKHlrDtCH0="}

    # 修复项：数组方括号处理逻辑，去除了错误的引号
    echo -en "${C_GREEN}4. WARP Reserved 字段 ${C_YELLOW}[默认: 123,40,227]${C_RESET}: "
    read RAW_RESERVED
    RAW_RESERVED=${RAW_RESERVED:-"123,40,227"}
    CLEAN_RESERVED=$(echo "$RAW_RESERVED" | tr -d '[] ')
    WARP_RESERVED="[$CLEAN_RESERVED]"

    echo -en "${C_GREEN}5. 机场订阅链接 URL ${C_RESET}: "
    read AIRPORT_URL
    AIRPORT_URL=${AIRPORT_URL:-"https://example.com/subscribe/xxxxxx"}

    echo -e "\n${C_BLUE}>>> 正在部署离线 Web 面板...${C_RESET}"
    mkdir -p /opt/xunyou/mihomo/ui
    wget -q --show-progress -O metacubexd.tgz https://github.com/MetacubeX/metacubexd/releases/download/v1.141.1/compressed-dist.tgz
    if [ $? -eq 0 ]; then
        tar -xzf metacubexd.tgz -C ./mihomo/ui
        rm metacubexd.tgz
    else
        echo -e "${C_YELLOW}[警告] Web 面板下载失败。${C_RESET}"
    fi

    echo -e "${C_BLUE}>>> 正在生成 Mihomo 配置...${C_RESET}"
    cat > /opt/xunyou/docker-compose-mihomo.yml << EOF
version: '3'
services:
  mihomo:
    image: metacubex/mihomo:latest
    container_name: mihomo_core
    restart: unless-stopped
    network_mode: "container:xunyou_sim"
    environment:
      - TZ=Asia/Shanghai
    volumes:
      - ./mihomo:/root/.config/mihomo
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    cat > /opt/xunyou/mihomo/config.yaml << EOF
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

listeners:
  - name: ss-in199
    type: shadowsocks
    port: 10086
    listen: 0.0.0.0
    cipher: aes-256-gcm
    password: "$SS_PASS"
    udp: true
    proxy: WARP199

proxies:
  - name: "WARP199"
    type: wireguard
    server: engage.cloudflareclient.com
    port: 2408
    ip: "172.16.0.2/32"
    ipv6: "$WARP_IPV6"
    private-key: "$WARP_KEY"
    public-key: "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
    udp: true
    reserved: $WARP_RESERVED
    mtu: 1400
    remote-dns-resolve: true
    dns:
      - https://dns.cloudflare.com/dns-query
    interface-name: tun199

proxy-providers:
  my_airport:
    type: http
    url: "$AIRPORT_URL"
    interval: 86400
    path: ./providers/airport.yaml
    health-check:
      enable: true
      interval: 600
      url: http://www.gstatic.com/generate_204

proxy-groups:
  - name: "PROXIES"
    type: select
    proxies:
      - DIRECT
      - WARP199
    use:
      - my_airport

rules:
  - MATCH,PROXIES
EOF

    $DOCKER_CMD -f /opt/xunyou/docker-compose-mihomo.yml up -d

    echo -e "${C_GREEN}==================================================${C_RESET}"
    echo -e "${C_GREEN}[成功] Mihomo 代理分流核心安装完成！${C_RESET}"
    echo -e "管理面板: ${C_YELLOW}http://${CONTAINER_IP}:9090/ui${C_RESET}"
    echo -e "${C_GREEN}==================================================${C_RESET}"
    echo -en "${C_PURPLE}按回车键继续... ${C_RESET}"
    read -r
}

function update_mihomo() {
    if [ ! -f "/opt/xunyou/docker-compose-mihomo.yml" ]; then
        echo -e "${C_RED}[错误] 找不到 Mihomo 配置文件！${C_RESET}"
        echo -en "${C_PURPLE}按回车键继续... ${C_RESET}"
        read -r
        return
    fi
    echo -e "${C_BLUE}>>> 正在更新 Mihomo 及面板...${C_RESET}"
    $DOCKER_CMD -f /opt/xunyou/docker-compose-mihomo.yml pull
    $DOCKER_CMD -f /opt/xunyou/docker-compose-mihomo.yml up -d
    wget -q --show-progress -O metacubexd.tgz https://github.com/MetacubeX/metacubexd/releases/download/v1.141.1/compressed-dist.tgz
    if [ $? -eq 0 ]; then
        tar -xzf metacubexd.tgz -C ./mihomo/ui
        rm metacubexd.tgz
    fi
    docker image prune -f
    echo -e "${C_GREEN}[成功] 更新完毕！${C_RESET}"
    echo -en "${C_PURPLE}按回车键继续... ${C_RESET}"
    read -r
}

function restart_mihomo() {
    echo -e "${C_BLUE}>>> 正在重启 Mihomo 核心容器...${C_RESET}"
    if docker restart mihomo_core > /dev/null 2>&1; then
        echo -e "${C_GREEN}[成功] Mihomo 容器已重启！${C_RESET}"
    else
        echo -e "${C_RED}[错误] 容器重启失败，请检查是否已安装。${C_RESET}"
    fi
    echo -en "${C_PURPLE}按回车键继续... ${C_RESET}"
    read -r
}

function uninstall_mihomo() {
    echo -en "${C_RED}[警告] 这将删除 Mihomo 容器和配置。确认吗？(yes/no): ${C_RESET}"
    read confirm
    if [[ "$confirm" == "yes" || "$confirm" == "y" ]]; then
        if [ -f "/opt/xunyou/docker-compose-mihomo.yml" ]; then
            $DOCKER_CMD -f /opt/xunyou/docker-compose-mihomo.yml down
            rm -f /opt/xunyou/docker-compose-mihomo.yml
        else
            docker rm -f mihomo_core 2>/dev/null
        fi
        echo -e "${C_GREEN}[成功] Mihomo 容器已卸载。${C_RESET}"
    fi
    echo -en "${C_PURPLE}按回车键继续... ${C_RESET}"
    read -r
}

# ================= 一键清理模块 =================
function uninstall_all() {
    clear
    echo -e "${C_CYAN}==================================================${C_RESET}"
    echo -e "${C_RED}        >>> ⚠️ 危险操作：彻底清理系统 ⚠️ <<<      ${C_RESET}"
    echo -e "${C_CYAN}==================================================${C_RESET}"
    echo -e "${C_YELLOW}这将会彻底删除：${C_RESET}"
    echo -e " 1. 迅游加速核心 和 Mihomo 代理分流核心 (Docker容器)"
    echo -e " 2. 端口转发开机守护进程"
    echo -e " 3. /opt/xunyou 目录下的所有配置文件、UI 面板、日志"
    echo -e " 4. 'xy' 快捷启动命令"
    echo -e "${C_CYAN}==================================================${C_RESET}"
    echo -en "${C_RED}确定要执行一键彻底卸载吗？(输入 yes 确认): ${C_RESET}"
    read confirm
    
    if [ "$confirm" == "yes" ]; then
        echo -e "${C_BLUE}>>> 正在停止并删除所有容器...${C_RESET}"
        if [ -f "/opt/xunyou/docker-compose-mihomo.yml" ]; then
            $DOCKER_CMD -f /opt/xunyou/docker-compose-mihomo.yml down 2>/dev/null
        fi
        if [ -f "/opt/xunyou/docker-compose-xunyou.yml" ]; then
            $DOCKER_CMD -f /opt/xunyou/docker-compose-xunyou.yml down 2>/dev/null
        fi
        docker rm -f xunyou_sim mihomo_core 2>/dev/null

        echo -e "${C_BLUE}>>> 正在移除端口转发守护服务...${C_RESET}"
        systemctl stop xunyou-forward 2>/dev/null
        systemctl disable xunyou-forward 2>/dev/null
        rm -f /etc/systemd/system/xunyou-forward.service
        systemctl daemon-reload

        echo -e "${C_BLUE}>>> 正在清理 /opt/xunyou 安装目录...${C_RESET}"
        cd /
        rm -rf /opt/xunyou

        echo -e "${C_BLUE}>>> 正在移除快捷命令...${C_RESET}"
        rm -f /usr/local/bin/xy

        echo -e "${C_GREEN}[成功] 系统清理完毕！没有留下一片云彩。${C_RESET}"
        exit 0
    else
        echo -e "${C_GREEN}已取消操作。${C_RESET}"
        echo -en "${C_PURPLE}按回车键返回... ${C_RESET}"
        read -r
    fi
}

# ================= 菜单系统 =================
function menu_xunyou() {
    while true; do
        clear
        echo -e "${C_CYAN}==================================================${C_RESET}"
        echo -e "${C_YELLOW}             >>> 迅游核心 管理菜单 <<<            ${C_RESET}"
        echo -e "${C_CYAN}==================================================${C_RESET}"
        echo -e " ${C_GREEN}[1]${C_RESET} 安装 / 重装 迅游核心"
        echo -e " ${C_GREEN}[2]${C_RESET} 更新 迅游核心镜像"
        echo -e " ${C_GREEN}[3]${C_RESET} 卸载 迅游核心容器"
        echo -e " ${C_GREEN}[4]${C_RESET} 重启 迅游核心容器 (修复卡顿)"
        echo -e " ${C_GREEN}[0]${C_RESET} 返回主菜单"
        echo -e "${C_CYAN}==================================================${C_RESET}"
        echo -en "${C_YELLOW}请选择 [0-4]: ${C_RESET}"
        read choice
        case $choice in
            1) install_xunyou ;;
            2) update_xunyou ;;
            3) uninstall_xunyou ;;
            4) restart_xunyou ;;
            0) break ;;
        esac
    done
}

function menu_mihomo() {
    while true; do
        clear
        echo -e "${C_CYAN}==================================================${C_RESET}"
        echo -e "${C_YELLOW}            >>> Mihomo核心 管理菜单 <<<           ${C_RESET}"
        echo -e "${C_CYAN}==================================================${C_RESET}"
        echo -e " ${C_GREEN}[1]${C_RESET} 安装 / 重装 Mihomo 核心"
        echo -e " ${C_GREEN}[2]${C_RESET} 更新 Mihomo 镜像与面板"
        echo -e " ${C_GREEN}[3]${C_RESET} 卸载 Mihomo 核心容器"
        echo -e " ${C_GREEN}[4]${C_RESET} 重启 Mihomo 核心容器 (修复节点卡死)"
        echo -e " ${C_GREEN}[0]${C_RESET} 返回主菜单"
        echo -e "${C_CYAN}==================================================${C_RESET}"
        echo -en "${C_YELLOW}请选择 [0-4]: ${C_RESET}"
        read choice
        case $choice in
            1) install_mihomo ;;
            2) update_mihomo ;;
            3) uninstall_mihomo ;;
            4) restart_mihomo ;;
            0) break ;;
        esac
    done
}

# ================= 主控制逻辑 =================
while true; do
    clear
    echo -e "${C_CYAN}==================================================${C_RESET}"
    echo -e "${C_YELLOW}      双擎网关 (迅游加速+Mihomo) 综合管理助手     ${C_RESET}"
    echo -e "${C_CYAN}==================================================${C_RESET}"
    
    X_STATUS="${C_RED}未安装${C_RESET}"
    M_STATUS="${C_RED}未安装${C_RESET}"
    docker ps -a --format '{{.Names}}' | grep -Eq "^xunyou_sim$" && X_STATUS="${C_GREEN}已运行${C_RESET}"
    docker ps -a --format '{{.Names}}' | grep -Eq "^mihomo_core$" && M_STATUS="${C_GREEN}已运行${C_RESET}"

    echo -e " ${C_GREEN}[1]${C_RESET} 迅游加速核心管理       [状态: $X_STATUS]"
    echo -e " ${C_GREEN}[2]${C_RESET} Mihomo代理分流管理     [状态: $M_STATUS]"
    echo -e " ${C_GREEN}[3]${C_RESET} 端口转发与规则管理面板"
    echo -e " ${C_RED}[4]${C_RED} 一键彻底清理           ${C_YELLOW}[卸载全部容器及文件]${C_RESET}"
    echo -e " ${C_GREEN}[0]${C_RESET} 退出脚本"
    echo -e "${C_CYAN}==================================================${C_RESET}"
    
    echo -en "${C_YELLOW}请选择操作 [0-4]: ${C_RESET}"
    read main_choice
    
    case $main_choice in
        1) menu_xunyou ;;
        2) menu_mihomo ;;
        3)
            if [ -f "/opt/xunyou/port_forward.sh" ]; then
                bash /opt/xunyou/port_forward.sh
            else
                echo -e "${C_RED}[错误] 请先安装迅游核心！${C_RESET}"
                sleep 2
            fi
            ;;
        4) uninstall_all ;;
        0)
            echo -e "${C_GREEN}已退出。提示: 随时输入 ${C_YELLOW}xy${C_GREEN} 即可重新唤出此面板。${C_RESET}"
            exit 0
            ;;
        *)
            echo -e "${C_RED}无效选择！${C_RESET}"
            sleep 1
            ;;
    esac
done
