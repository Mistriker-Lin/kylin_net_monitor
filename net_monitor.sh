#!/bin/bash

# -----------------------------
# 配置区
# -----------------------------
GATEWAY=""  # 如果为空，将自动检测 USB 网卡的网关
LOG_DIR="/var/log/net_monitor"
CHECK_INTERVAL=5  # 正常检查间隔（秒）
DOWN_CHECK_INTERVAL=10  # 网络中断时的检查间隔（秒）
MAX_LOG_FILES=10  # 保留的最大日志文件数量
HTTP_CHECK_HOST="www.bing.com"  # HTTP检测主机名
HTTP_CHECK_URL="https://$HTTP_CHECK_HOST"  # 使用HTTPS进行检测

# 添加多个检测目标
CHECK_TARGETS=("8.8.8.8" "1.1.1.1" "114.114.114.114")  # 多个公共DNS服务器

# -----------------------------
# 创建日志目录和新的日志文件
# -----------------------------
if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR"
    echo "创建日志目录: $LOG_DIR"
fi

# 生成带时间戳的日志文件名
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOGFILE="$LOG_DIR/net_monitor_$TIMESTAMP.log"

# 清理旧的日志文件
if [ $(ls -1 $LOG_DIR/net_monitor_*.log 2>/dev/null | wc -l) -ge $MAX_LOG_FILES ]; then
    ls -t $LOG_DIR/net_monitor_*.log | tail -n +$(($MAX_LOG_FILES + 1)) | xargs rm -f
fi

# -----------------------------
# 自动识别 USB 网卡（改进版）
# -----------------------------
USB_NETCARD=""
# 多种方法检测USB网卡
for iface in $(ls /sys/class/net | grep -E '^enx|^eth|^enp|^usb'); do
    # 方法1: 检查设备路径是否包含USB
    if [ -d "/sys/class/net/$iface/device" ]; then
        if readlink -f "/sys/class/net/$iface/device" | grep -q "usb"; then
            USB_NETCARD="$iface"
            break
        fi
    fi
    
    # 方法2: 检查驱动是否为常见USB网卡驱动
    if [ -f "/sys/class/net/$iface/device/modalias" ]; then
        if grep -q "usb" "/sys/class/net/$iface/device/modalias"; then
            USB_NETCARD="$iface"
            break
        fi
    fi
    
    # 方法3: 使用ethtool检查驱动
    if command -v ethtool >/dev/null 2>&1; then
        if ethtool -i "$iface" 2>/dev/null | grep -q "driver: r8152\|driver: asix\|driver: cdc_ether"; then
            USB_NETCARD="$iface"
            break
        fi
    fi
done

if [ -z "$USB_NETCARD" ]; then
    echo "未检测到 USB 网卡，日志将记录所有相关网卡信息。" >> "$LOGFILE"
    USB_KEYWORD="usb|eth|enp|enx|r815|asix"
else
    USB_KEYWORD="$USB_NETCARD"
    echo "检测到 USB 网卡: $USB_NETCARD" >> "$LOGFILE"
fi

# -----------------------------
# 自动检测网关
# -----------------------------
if [ -z "$GATEWAY" ]; then
    if [ -n "$USB_NETCARD" ]; then
        GATEWAY=$(ip route | grep default | grep "$USB_NETCARD" | awk '{print $3}')
    fi
    
    if [ -z "$GATEWAY" ]; then
        GATEWAY=$(ip route | grep default | awk '{print $3}' | head -n 1)
    fi
    
    if [ -z "$GATEWAY" ]; then
        echo "未找到默认网关，将使用公共DNS服务器进行检测" >> "$LOGFILE"
    else
        echo "使用网关: $GATEWAY" >> "$LOGFILE"
        # 将网关添加到检测目标
        CHECK_TARGETS=("$GATEWAY" "${CHECK_TARGETS[@]}")
    fi
fi

# 添加HTTP检测主机到目标列表
CHECK_TARGETS+=("$HTTP_CHECK_HOST")

echo "检测目标: ${CHECK_TARGETS[*]}" >> "$LOGFILE"
echo "==== 网络监控启动 $(date) ====" >> "$LOGFILE"
echo "日志文件: $LOGFILE" >> "$LOGFILE"

# -----------------------------
# 网络状态检测函数（优先使用curl）
# -----------------------------
check_network_status() {
    local online=false
    local http_ok=false
    local ping_ok=false
    
    # 首先尝试使用curl检测HTTP(S)连通性
    if curl -s --connect-timeout 3 -I "$HTTP_CHECK_URL" >/dev/null 2>&1; then
        http_ok=true
        online=true
        echo "HTTP检测成功" >> "$LOGFILE"
    else
        echo "HTTP检测失败，尝试ping检测..." >> "$LOGFILE"
        # 如果curl失败，尝试ping多个目标
        for target in "${CHECK_TARGETS[@]}"; do
            if ping -c 1 -W 2 "$target" >/dev/null 2>&1; then
                ping_ok=true
                online=true
                echo "ping $target 成功" >> "$LOGFILE"
                break
            fi
        done
    fi
    
    # 记录检测结果
    if $online; then
        if $http_ok; then
            echo "网络状态: HTTP正常" >> "$LOGFILE"
        else
            echo "网络状态: HTTP失败但网络连通性正常" >> "$LOGFILE"
        fi
    else
        echo "网络状态: 完全断开" >> "$LOGFILE"
    fi
    
    echo $online
}

# 检查DNS解析功能
check_dns_resolution() {
    if nslookup "$HTTP_CHECK_HOST" >/dev/null 2>&1; then
        echo "正常"
    else
        echo "失败"
    fi
}

# -----------------------------
# 状态变量
# -----------------------------
NETWORK_DOWN=false
LAST_DOWN_TIME=""
PARTIAL_OUTAGE=false  # 部分中断状态

# -----------------------------
# 监控循环
# -----------------------------
while true; do
    if $(check_network_status); then
        # 网络正常
        if $NETWORK_DOWN; then
            # 网络刚恢复
            echo "[$(date)] 网络已恢复" >> "$LOGFILE"
            echo "------------------------------" >> "$LOGFILE"
            NETWORK_DOWN=false
            PARTIAL_OUTAGE=false
        fi
        sleep $CHECK_INTERVAL
        continue
    fi

    # 网络中断或部分中断
    CURRENT_TIME=$(date +%s)
    
    if ! $NETWORK_DOWN; then
        # 首次检测到网络问题
        NETWORK_DOWN=true
        LAST_DOWN_TIME=$CURRENT_TIME
        
        # 检查是否是部分中断（HTTP失败但网络连通性正常）
        PARTIAL_OUTAGE=false
        # 尝试ping网关和其他目标
        for target in "${CHECK_TARGETS[@]}"; do
            if ping -c 1 -W 2 "$target" >/dev/null 2>&1; then
                PARTIAL_OUTAGE=true
                break
            fi
        done
        
        # -----------------------------
        # 网络问题，开始记录详细信息
        # -----------------------------
        if $PARTIAL_OUTAGE; then
            echo "[$(date)] 网络部分中断（HTTP失败但网络连通性正常）" >> "$LOGFILE"
        else
            echo "[$(date)] 网络完全中断，开始记录信息..." >> "$LOGFILE"
        fi

        # 记录详细信息
        echo "=== 网络接口状态 ===" >> "$LOGFILE"
        ip a >> "$LOGFILE" 2>&1

        echo "=== 路由表 ===" >> "$LOGFILE"
        ip route >> "$LOGFILE" 2>&1

        echo "=== DNS 配置 ===" >> "$LOGFILE"
        cat /etc/resolv.conf >> "$LOGFILE" 2>&1

        echo "=== DNS 解析测试 ($HTTP_CHECK_HOST) ===" >> "$LOGFILE"
        nslookup "$HTTP_CHECK_HOST" >> "$LOGFILE" 2>&1
        echo "DNS 解析状态: $(check_dns_resolution)" >> "$LOGFILE"

        echo "=== 连接跟踪 ===" >> "$LOGFILE"
        if command -v conntrack >/dev/null 2>&1; then
            conntrack -L 2>/dev/null | head -20 >> "$LOGFILE" 2>&1
        else
            echo "conntrack 命令未安装" >> "$LOGFILE"
        fi

        echo "=== ARP表 ===" >> "$LOGFILE"
        arp -n >> "$LOGFILE" 2>&1

        echo "=== USB设备状态 ===" >> "$LOGFILE"
        if command -v lsusb >/dev/null 2>&1; then
            lsusb >> "$LOGFILE" 2>&1
            echo "--- USB设备树 ---" >> "$LOGFILE"
            lsusb -t >> "$LOGFILE" 2>&1
        else
            echo "lsusb 命令未安装" >> "$LOGFILE"
        fi

        echo "=== 内核日志 (USB网卡相关) ===" >> "$LOGFILE"
        dmesg | grep -E "$USB_KEYWORD" | tail -30 >> "$LOGFILE" 2>&1

        echo "=== 网络统计信息 ===" >> "$LOGFILE"
        if [ -n "$USB_NETCARD" ]; then
            echo "--- 接口 $USB_NETCARD 统计 ---" >> "$LOGFILE"
            ip -s link show "$USB_NETCARD" >> "$LOGFILE" 2>&1
        fi

        echo "=== DHCP网络协议日志 (最近2分钟) ===" >> "$LOGFILE"
        journalctl -u NetworkManager --since "2 minutes ago" >> "$LOGFILE" 2>&1

        echo "=== 尝试curl和ping各目标详细信息 ===" >> "$LOGFILE"
        echo "--- curl $HTTP_CHECK_URL ---" >> "$LOGFILE"
        curl -s -I --connect-timeout 3 "$HTTP_CHECK_URL" >> "$LOGFILE" 2>&1
        echo "curl退出代码: $?" >> "$LOGFILE"
        
        for target in "${CHECK_TARGETS[@]}"; do
            echo "--- ping $target ---" >> "$LOGFILE"
            ping -c 2 -W 1 "$target" >> "$LOGFILE" 2>&1
            echo "" >> "$LOGFILE"
        done

        echo "------------------------------" >> "$LOGFILE"
    else
        # 网络持续中断，只记录简单状态
        ELAPSED_TIME=$((CURRENT_TIME - LAST_DOWN_TIME))
        if $PARTIAL_OUTAGE; then
            echo "[$(date)] 网络仍然部分中断（HTTP失败但网络连通性正常），已持续 ${ELAPSED_TIME} 秒" >> "$LOGFILE"
        else
            echo "[$(date)] 网络仍然完全中断，已持续 ${ELAPSED_TIME} 秒" >> "$LOGFILE"
            
            # 每5分钟重新记录一次详细信息
            if [ $((ELAPSED_TIME % 300)) -lt 10 ]; then
                echo "=== 重新检测网络状态 ===" >> "$LOGFILE"
                echo "curl $HTTP_CHECK_URL: $(curl -s -I --connect-timeout 3 "$HTTP_CHECK_URL" >/dev/null 2>&1 && echo "成功" || echo "失败")" >> "$LOGFILE"
                for target in "${CHECK_TARGETS[@]}"; do
                    echo "ping $target: $(ping -c 1 -W 2 "$target" >/dev/null 2>&1 && echo "成功" || echo "失败")" >> "$LOGFILE"
                done
                echo "DNS 解析状态: $(check_dns_resolution)" >> "$LOGFILE"
                echo "------------------------------" >> "$LOGFILE"
            fi
        fi
    fi

    # 等待一段时间再继续检查
    sleep $DOWN_CHECK_INTERVAL
done
