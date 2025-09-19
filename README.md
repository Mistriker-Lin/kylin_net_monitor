
##  简介
自用麒麟系统网络监测脚本，持续检测 USB 网卡和网络连接状态，区分完全中断和部分中断（能 ping 通但 HTTP 不通）
自动记录详细诊断信息：
  - 网卡状态（`ip a`）
  - 路由表（`ip route`）
  - DNS 配置（`/etc/resolv.conf` + `nslookup`）
  - 连接跟踪（`conntrack`）
  - ARP 表（`arp -n`）
  - USB 设备信息（`lsusb` + `dmesg`）
  - 网卡流量统计（`ip -s link`）
  - DHCP/NetworkManager 日志（`journalctl`）
  - `curl` 和 `ping` 的详细测试
- 日志文件自动轮换，避免磁盘被占满。
- 网络恢复时在日志中标记。

- ##  日志说明
- 日志目录：`/var/log/net_monitor`
- 文件格式：`net_monitor_YYYYMMDD_HHMMSS.log`
- 默认最多保留 `10` 个日志文件（可在脚本中修改 `MAX_LOG_FILES` 参数）。

##  依赖环境
脚本使用了以下命令，请确保系统已安装：
- `bash`
- `curl`
- `ping`
- `ip`（来自 `iproute2` 包）
- `nslookup`（来自 `dnsutils` 或 `bind-utils`）
- `ethtool`（可选，用于识别网卡驱动）
- `conntrack`（可选，连接跟踪）
- `lsusb`（可选，USB 设备检测）
- `journalctl`（systemd 环境下可用）

##  使用方法
- 安装`conntrack`:sudo apt install conntrack
- 将脚本保存为 net_monitor.sh
- 进入脚本存放目录
- chmod +x net_monitor.sh
- sudo bash net_monitor.sh
