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
  echo -e "${C_RED}[错误] 请使用 root 权限运行此脚本！${C_RESET}"
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

# 兼容 docker-compose 命令
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
    for cmd in curl wget tar awk ip cron; do
        if [ "$cmd" == "cron" ] && ! command -v crontab &> /dev/null; then
            MISSING_PKGS+=("cron")
        elif ! command -v $cmd &> /dev/null && [ "$cmd" != "cron" ]; then
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

# ================= 日志时间轮询管理器 (终极版) =================
function setup_log_manager() {
    local MODE=${1:-7}
    
    cat > /opt/xunyou/log_cleaner.sh << 'EOF'
#!/bin/bash
MODE=$1
X_LOG=$(docker inspect --format='{{.LogPath}}' xunyou_sim 2>/dev/null)
M_LOG=$(docker inspect --format='{{.LogPath}}' mihomo_core 2>/dev/null)

function process_log() {
    local file=$1
    if [ -n "$file" ] && [ -f "$file" ]; then
        if [ "$MODE" == "7" ]; then
            cp "$file" "${file}.bak"
        else
            rm -f "${file}.bak" 2>/dev/null
        fi
        # 使用更底层的置空命令，避免 Docker 读取稀疏文件
        : > "$file"
    fi
}

process_log "$X_LOG"
process_log "$M_LOG"

if [ -d "/opt/xunyou/xunyou_logs" ]; then
    for l in /opt/xunyou/xunyou_logs/*.log; do
        process_log "$l"
    done
fi
EOF
    chmod +x /opt/xunyou/log_cleaner.sh

    if [ "$MODE" == "3" ]; then
        echo "0 4 */3 * * root /opt/xunyou/log_cleaner.sh 3" > /etc/cron.d/xunyou_logs
        echo -e "${C_GREEN}[成功] 已设为: 每 3 天凌晨清理一次 (无备份)。${C_RESET}"
    else
        echo "0 4 */7 * * root /opt/xunyou/log_cleaner.sh 7" > /etc/cron.d/xunyou_logs
        echo -e "${C_GREEN}[成功] 已设为: 每 7 天凌晨清理一次 (保留 1 份旧备份)。${C_RESET}"
    fi
    systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null
}

function menu_logs() {
    while true; do
        clear
        echo -e "${C_CYAN}==================================================${C_RESET}"
        echo -e "${C_YELLOW}             >>> 容器日志轮询设置 <<<             ${C_RESET}"
        echo -e "${C_CYAN}==================================================${C_RESET}"
        
        local CURRENT="未设置"
        if grep -q " 3" /etc/cron.d/xunyou_logs 2>/dev/null; then
            CURRENT="${C_RED}每 3 天清理 (不保留备份)${C_RESET}"
        elif grep -q " 7" /etc/cron.d/xunyou_logs 2>/dev/null; then
            CURRENT="${C_GREEN}每 7 天清理 (保留 1 份备份)${C_RESET}"
        fi
        
        echo -e " 当前运行状态: $CURRENT"
        echo -e "${C_CYAN}--------------------------------------------------${C_RESET}"
        echo -e " ${C_GREEN}[1]${C_RESET} 设为 7天轮询，保留1份旧备份 (默认推荐)"
        echo -e " ${C_GREEN}[2]${C_RESET} 设为 3天轮询，不保留任何备份 (极致省空间)"
        echo -e " ${C_GREEN}[3]${C_RESET} 立即执行一次彻底清理 (自动重启容器释放指针)"
        echo -e " ${C_GREEN}[0]${C_RESET} 返回主菜单"
        echo -e "${C_CYAN}==================================================${C_RESET}"
        echo -en "${C_YELLOW}请选择 [0-3]: ${C_RESET}"
        read choice
        case $choice in
            1) setup_log_manager 7; echo -en "按回车继续... "; read -r ;;
            2) setup_log_manager 3; echo -en "按回车继续... "; read -r ;;
            3) 
                echo -e "${C_BLUE}>>> 正在清空物理硬盘日志...${C_RESET}"
                bash /opt/xunyou/log_cleaner.sh 3 2>/dev/null
                echo -e "${C_BLUE}>>> 正在重启容器以彻底重置 Docker 日志指针...${C_RESET}"
                docker restart xunyou_sim mihomo_core > /dev/null 2>&1
                echo -e "${C_GREEN}[成功] 清理完成，现在查看日志绝对干干净净！${C_RESET}"
                echo -en "按回车继续... "
                read -r 
                ;;
            0) break ;;
        esac
    done
}


# ================= 端口转发脚本生成模块 =================
function generate_port_forward_script() {
    cat > /opt/xunyou/port_forward.sh << 'EOF'
#!/bin/bash
C_RED='\033[1;31m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[1;36m'
C_PURPLE='\033[1;35m'
C_CYAN='\033[1;36m'
C_RESET='\033[0m'

CONTAINER_NAME="xunyou_sim"
VPN_IF="tun199"
CONF_DIR="/opt/xunyou"
CONF_FILE="${CONF_DIR}/forward_rules.conf"

mkdir -p "$CONF_DIR" 2>/dev/null
touch "$CONF_FILE"

function apply_rules() {
    docker exec $CONTAINER_NAME iptables -t nat -F PREROUTING 2>/dev/null
    docker exec $CONTAINER_NAME iptables -t nat -F POSTROUTING 2>/dev/null
    docker exec $CONTAINER_NAME iptables -t nat -A POSTROUTING -o $VPN_IF -j MASQUERADE

    local count=0
    while IFS=':' read -r TARGET_HOST LOCAL_PORT REMOTE_PORT; do
        [ -z "$TARGET_HOST" ] && continue
        REAL_IP=$(getent ahostsv4 "$TARGET_HOST" | awk '{ print $1 }' | head -n 1)
        if [ -z "$REAL_IP" ]; then continue; fi
        REMOTE_PORT=${REMOTE_PORT:-$LOCAL_PORT}
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
    [ -z "$host" ] && return
    echo -en "2. 容器本地监听端口: "
    read l_port
    [ -z "$l_port" ] && return
    echo -en "3. 落地机目标端口 (回车默认同本地): "
    read r_port
    [ -z "$r_port" ] && r_port=$l_port

    local RULE="${host}:${l_port}:${r_port}"
    if ! grep -q "^${RULE}$" "$CONF_FILE"; then
        echo "$RULE" >> "$CONF_FILE"
        echo -e "${C_GREEN}[记录] 新增: $RULE${C_RESET}"
        apply_rules
    fi
}

function interactive_del() {
    echo -e "${C_PURPLE}----------------------------------------${C_RESET}"
    if [ ! -s "$CONF_FILE" ]; then return; fi
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
    fi
}

function list_rules() {
    echo -e "${C_PURPLE}------------------------------------------------${C_RESET}"
    printf "${C_BLUE}%-20s | %-10s | %-10s${C_RESET}\n" "目标主机" "本地端口" "远程端口"
    echo -e "${C_PURPLE}------------------------------------------------${C_RESET}"
    if [ -s "$CONF_FILE" ]; then
        while IFS=':' read -r HOST L_PORT R_PORT; do
            [ -z "$HOST" ] && continue
            printf "%-20s | %-10s | %-10s\n" "$HOST" "$L_PORT" "$R_PORT"
        done < "$CONF_FILE"
    fi
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
            6) systemctl restart xunyou-forward 2>/dev/null; echo -e "${C_GREEN}已重启${C_RESET}"; echo -en "按回车继续... "; read -r ;;
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
        echo -e "${C_GREEN}[提示] 迅游容器已存在！请先卸载旧容器。${C_RESET}"
        echo -en "${C_PURPLE}按回车键继续... ${C_RESET}"; read -r; return
    fi

    echo -e "\n${C_BLUE}>>> 请配置迅游参数...${C_RESET}"
    echo -en "${C_GREEN}1. 迅游镜像版本 ${C_YELLOW}[默认: v2.0]${C_RESET}: "
    read XUNYOU_VER; XUNYOU_VER=${XUNYOU_VER:-v2.0}

    DEFAULT_IFACE=$(ip route get 1 | awk '{print $5; exit}')
    DEFAULT_GATEWAY=$(ip route show default | awk '/default/ {print $3}')
    DEFAULT_SUBNET=$(ip -o -f inet addr show $DEFAULT_IFACE | awk '{print $4}' | head -n 1 | sed 's/\.[0-9]*\//\.0\//')
    
    echo -en "${C_GREEN}2. 局域网子网段 ${C_YELLOW}[默认: ${DEFAULT_SUBNET:-10.10.0.0/24}]${C_RESET}: "
    read SUBNET; SUBNET=${SUBNET:-${DEFAULT_SUBNET:-10.10.0.0/24}}

    echo -en "${C_GREEN}3. 局域网网关 IP ${C_YELLOW}[默认: ${DEFAULT_GATEWAY:-10.10.0.1}]${C_RESET}: "
    read GATEWAY; GATEWAY=${GATEWAY:-${DEFAULT_GATEWAY:-10.10.0.1}}

    echo -en "${C_GREEN}4. 网关容器独立 IP ${C_YELLOW}[默认: 10.10.0.254]${C_RESET}: "
    read CONTAINER_IP; CONTAINER_IP=${CONTAINER_IP:-10.10.0.254}

    echo -en "${C_GREEN}5. 物理网卡名称 ${C_YELLOW}[默认: $DEFAULT_IFACE]${C_RESET}: "
    read IFACE; IFACE=${IFACE:-$DEFAULT_IFACE}

    echo "$CONTAINER_IP" > /opt/xunyou/.xunyou_ip
    mkdir -p /opt/xunyou/xunyou_logs

    # 为防止日志刷屏爆满硬盘，在保留 cron 轮询的前提下，加入 max-size=100m 极限制锁 (禁止自带备份)
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
        max-size: "100m"
        max-file: "1"

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

    # 默认触发 7 天日志轮询
    [ ! -f /etc/cron.d/xunyou_logs ] && setup_log_manager 7 > /dev/null

    echo -e "${C_GREEN}[成功] 迅游加速核心安装完成！IP: ${C_YELLOW}$CONTAINER_IP${C_RESET}"
    echo -en "${C_PURPLE}按回车键继续... ${C_RESET}"; read -r
}

function update_xunyou() {
    if [ ! -f "/opt/xunyou/docker-compose-xunyou.yml" ]; then
        echo -e "${C_RED}[错误] 找不到配置！${C_RESET}"; echo -en "按回车... "; read -r; return
    fi
    local CURRENT_TAG=$(grep -E 'image:.*xunyou-sim-deck' /opt/xunyou/docker-compose-xunyou.yml | awk -F':' '{print $3}')
    echo -en "${C_GREEN}输入新版本号 (当前 ${CURRENT_TAG:-v2.0}，回车保持不变): ${C_RESET}"
    read NEW_TAG
    [ -n "$NEW_TAG" ] && sed -i "s|image: wstxwd007/xunyou-sim-deck:.*|image: wstxwd007/xunyou-sim-deck:${NEW_TAG}|g" /opt/xunyou/docker-compose-xunyou.yml
    $DOCKER_CMD -f /opt/xunyou/docker-compose-xunyou.yml pull
    $DOCKER_CMD -f /opt/xunyou/docker-compose-xunyou.yml up -d
    docker image prune -f
    echo -e "${C_GREEN}[成功] 更新完毕！${C_RESET}"; echo -en "按回车... "; read -r
}

function restart_xunyou() {
    echo -e "${C_BLUE}>>> 重启容器中...${C_RESET}"
    docker restart xunyou_sim > /dev/null 2>&1
    echo -e "${C_GREEN}[成功] 已重启！${C_RESET}"; echo -en "按回车... "; read -r
}

function uninstall_xunyou() {
    echo -en "${C_RED}确认卸载迅游吗？(y/n): ${C_RESET}"; read confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        [ -f "/opt/xunyou/docker-compose-xunyou.yml" ] && $DOCKER_CMD -f /opt/xunyou/docker-compose-xunyou.yml down && rm -f /opt/xunyou/docker-compose-xunyou.yml
        docker rm -f xunyou_sim 2>/dev/null
        rm -f /opt/xunyou/.xunyou_ip
    fi
    echo -en "按回车... "; read -r
}

# ================= Mihomo核心 操作模块 =================
function install_mihomo() {
    clear
    echo -e "${C_CYAN}==================================================${C_RESET}"
    echo -e "${C_YELLOW}             >>> Mihomo 代理核心安装 <<<          ${C_RESET}"
    echo -e "${C_CYAN}==================================================${C_RESET}"

    check_dependencies
    if ! docker ps -a --format '{{.Names}}' | grep -Eq "^xunyou_sim$"; then
        echo -e "${C_RED}[错误] 请先安装迅游！${C_RESET}"; echo -en "按回车... "; read -r; return
    fi
    if docker ps -a --format '{{.Names}}' | grep -Eq "^mihomo_core$"; then
        echo -e "${C_GREEN}[提示] 容器已存在！${C_RESET}"; echo -en "按回车... "; read -r; return
    fi

    local CONTAINER_IP=$(cat /opt/xunyou/.xunyou_ip 2>/dev/null || echo "10.10.0.254")

    echo -e "\n${C_BLUE}>>> 请配置代理与节点参数...${C_RESET}"
    echo -en "${C_GREEN}1. Shadowsocks 密码 ${C_YELLOW}[默认: MySecretSSPassword123]${C_RESET}: "
    read SS_PASS; SS_PASS=${SS_PASS:-MySecretSSPassword123}

    echo -en "${C_GREEN}2. WARP IPv6 地址 ${C_YELLOW}[例: 2606.../128]${C_RESET}: "
    read WARP_IPV6; WARP_IPV6=${WARP_IPV6:-"2606:4700:110:8528:8b5b:66d3:e6d9:8930/128"}

    echo -en "${C_GREEN}3. WARP 私钥: ${C_RESET}"
    read WARP_KEY; WARP_KEY=${WARP_KEY:-"OPPUcAY5cUD7JdPgMmiKHlrDtCH0="}

    echo -en "${C_GREEN}4. WARP Reserved 字段 ${C_YELLOW}[默认: 123,40,227]${C_RESET}: "
    read RAW_RESERVED; RAW_RESERVED=${RAW_RESERVED:-"123,40,227"}
    CLEAN_RESERVED=$(echo "$RAW_RESERVED" | tr -d '[] ')
    WARP_RESERVED="[$CLEAN_RESERVED]"

    echo -en "${C_GREEN}5. 机场订阅链接 URL: ${C_RESET}"
    read AIRPORT_URL; AIRPORT_URL=${AIRPORT_URL:-"https://example.com/subscribe/xxxxxx"}

    echo -e "\n${C_BLUE}>>> 部署面板并生成配置...${C_RESET}"
    mkdir -p /opt/xunyou/mihomo/ui
    wget -q --show-progress -O metacubexd.tgz https://github.com/MetacubeX/metacubexd/releases/download/v1.141.1/compressed-dist.tgz
    [ $? -eq 0 ] && tar -xzf metacubexd.tgz -C ./mihomo/ui && rm metacubexd.tgz

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
        max-size: "100m"
        max-file: "1"
EOF

    # 核心修复：MTU 默认由 1400 调整为极其稳定的 1280 避免超载
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
    mtu: 1280
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
    
    # 默认触发 7 天日志轮询
    [ ! -f /etc/cron.d/xunyou_logs ] && setup_log_manager 7 > /dev/null

    echo -e "${C_GREEN}[成功] Mihomo 安装完成！MTU 默认已优化至 1280。${C_RESET}"
    echo -e "管理面板: ${C_YELLOW}http://${CONTAINER_IP}:9090/ui${C_RESET}"
    echo -en "${C_PURPLE}按回车键继续... ${C_RESET}"; read -r
}

function update_mihomo() {
    if [ ! -f "/opt/xunyou/docker-compose-mihomo.yml" ]; then
        echo -e "${C_RED}[错误] 找不到配置！${C_RESET}"; echo -en "按回车... "; read -r; return
    fi
    $DOCKER_CMD -f /opt/xunyou/docker-compose-mihomo.yml pull
    $DOCKER_CMD -f /opt/xunyou/docker-compose-mihomo.yml up -d
    wget -q --show-progress -O metacubexd.tgz https://github.com/MetacubeX/metacubexd/releases/download/v1.141.1/compressed-dist.tgz
    [ $? -eq 0 ] && tar -xzf metacubexd.tgz -C ./mihomo/ui && rm metacubexd.tgz
    docker image prune -f
    echo -e "${C_GREEN}[成功] 更新完毕！${C_RESET}"; echo -en "按回车... "; read -r
}

function restart_mihomo() {
    echo -e "${C_BLUE}>>> 重启容器中...${C_RESET}"
    docker restart mihomo_core > /dev/null 2>&1
    echo -e "${C_GREEN}[成功] 已重启！${C_RESET}"; echo -en "按回车... "; read -r
}

function uninstall_mihomo() {
    echo -en "${C_RED}确认卸载 Mihomo 吗？(y/n): ${C_RESET}"; read confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        [ -f "/opt/xunyou/docker-compose-mihomo.yml" ] && $DOCKER_CMD -f /opt/xunyou/docker-compose-mihomo.yml down && rm -f /opt/xunyou/docker-compose-mihomo.yml
        docker rm -f mihomo_core 2>/dev/null
    fi
    echo -en "按回车... "; read -r
}

# ================= 一键清理模块 =================
function uninstall_all() {
    clear
    echo -e "${C_CYAN}==================================================${C_RESET}"
    echo -e "${C_RED}        >>> ⚠️ 危险操作：彻底清理系统 ⚠️ <<<      ${C_RESET}"
    echo -e "${C_CYAN}==================================================${C_RESET}"
    echo -e "${C_YELLOW}这将会彻底删除：${C_RESET}"
    echo -e " 1. 迅游加速核心 和 Mihomo 代理容器"
    echo -e " 2. 端口转发开机守护 和 日志轮询守护"
    echo -e " 3. /opt/xunyou 目录下的所有文件"
    echo -e " 4. 'xy' 快捷启动命令"
    echo -e "${C_CYAN}==================================================${C_RESET}"
    echo -en "${C_RED}确定彻底卸载吗？(输入 yes 确认): ${C_RESET}"
    read confirm
    
    if [ "$confirm" == "yes" ]; then
        echo -e "${C_BLUE}>>> 删除容器...${C_RESET}"
        [ -f "/opt/xunyou/docker-compose-mihomo.yml" ] && $DOCKER_CMD -f /opt/xunyou/docker-compose-mihomo.yml down 2>/dev/null
        [ -f "/opt/xunyou/docker-compose-xunyou.yml" ] && $DOCKER_CMD -f /opt/xunyou/docker-compose-xunyou.yml down 2>/dev/null
        docker rm -f xunyou_sim mihomo_core 2>/dev/null

        echo -e "${C_BLUE}>>> 清理守护进程...${C_RESET}"
        systemctl stop xunyou-forward 2>/dev/null; systemctl disable xunyou-forward 2>/dev/null
        rm -f /etc/systemd/system/xunyou-forward.service /etc/cron.d/xunyou_logs
        systemctl daemon-reload
        systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null

        echo -e "${C_BLUE}>>> 抹除目录和命令...${C_RESET}"
        cd /; rm -rf /opt/xunyou /usr/local/bin/xy

        echo -e "${C_GREEN}[成功] 清理完毕，江湖再见！${C_RESET}"
        exit 0
    else
        echo -en "${C_PURPLE}已取消，按回车返回... ${C_RESET}"; read -r
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
    echo -e " ${C_GREEN}[4]${C_RESET} 容器日志轮询守护设置"
    echo -e " ${C_RED}[5]${C_RESET} 一键彻底清理系统       ${C_YELLOW}(卸载全部容器及文件)${C_RESET}"
    echo -e " ${C_GREEN}[0]${C_RESET} 退出脚本"
    echo -e "${C_CYAN}==================================================${C_RESET}"
    
    echo -en "${C_YELLOW}请选择操作 [0-5]: ${C_RESET}"
    read main_choice
    
    case $main_choice in
        1) menu_xunyou ;;
        2) menu_mihomo ;;
        3)
            if [ -f "/opt/xunyou/port_forward.sh" ]; then
                bash /opt/xunyou/port_forward.sh
            else
                echo -e "${C_RED}[错误] 请先安装迅游核心！${C_RESET}"; sleep 2
            fi
            ;;
        4) menu_logs ;;
        5) uninstall_all ;;
        0)
            echo -e "${C_GREEN}已退出。提示: 随时输入 ${C_YELLOW}xy${C_GREEN} 即可重新唤出此面板。${C_RESET}"
            exit 0
            ;;
        *)
            echo -e "${C_RED}无效选择！${C_RESET}"; sleep 1
            ;;
    esac
done
