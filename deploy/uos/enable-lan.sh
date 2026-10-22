#!/bin/bash
# 让 dsh web 同时服务 127.0.0.1 与局域网 IP。
#
# 0.2.1 起 webserver 只接受一个具体地址，且只 listen 一次：绑回环就局域网进不来，
# 绑局域网 IP 就本机 127.0.0.1 不通（旧版 0.2.0 可以 0.0.0.0 全绑，这个能力没了）。
# 这里保持回环绑定不变，把局域网流量 DNAT 到回环：源地址仍是真实客户端 IP，
# dsh-remote-mobile 的配对门禁照常拦截并放行，本机 127.0.0.1 也直连。
#
# 用法（root）:
#   sudo ./enable-lan.sh [端口]     # 默认 3080
# 规则在重启后失效；要开机恢复，把本脚本放进 root 的启动项（见 README）。
set -e

PORT="${1:-3080}"

if [ "$(id -u)" != "0" ]; then
  echo "请用 root 运行： sudo $0"
  exit 1
fi

# 取第一个非回环局域网 IPv4。
IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.' | head -1)"
if [ -z "$IP" ]; then
  echo "[错误] 找不到局域网 IPv4 地址（ip -4 addr 里没有非回环的 global 地址）"
  exit 1
fi

if ! command -v iptables >/dev/null 2>&1; then
  echo "[错误] 缺少 iptables"
  exit 1
fi

echo "=== 启用局域网访问: http://$IP:$PORT/ ==="

# 内核默认丢弃来自非本地网段、目标是 127.0.0.0/8 的包，DNAT 到回环必须放开。
sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null

add_rule() {
  table_chain="$1"; shift
  # 幂等：已存在就不重复加。
  if iptables -t nat -C "$table_chain" "$@" 2>/dev/null; then
    echo "  已存在: -t nat $table_chain $*"
  else
    iptables -t nat -A "$table_chain" "$@"
    echo "  已添加: -t nat $table_chain $*"
  fi
}

# 局域网客户端 -> 本机 IP:端口，转给回环；源地址保持不变。
add_rule PREROUTING -d "$IP" -p tcp --dport "$PORT" -j DNAT --to-destination "127.0.0.1:$PORT"
# 本机进程访问 本机 IP:端口（例如浏览器直接开 http://$IP:$PORT/）也转给回环。
add_rule OUTPUT -d "$IP" -p tcp --dport "$PORT" -j REDIRECT --to-ports "$PORT"

echo
echo "  本机:   http://127.0.0.1:$PORT/"
echo "  局域网: http://$IP:$PORT/   （首次访问要输入 dsh-remote-mobile 的配对码）"
echo
echo "注意：iptables 规则与 route_localnet 在重启后失效。开机自动恢复的方式："
echo "  1) 本脚本追加到 /etc/rc.local（若存在），或"
echo "  2) 建一个 root 的 systemd 单元，ExecStart 指向本脚本，或"
echo "  3) 每次重启后手动执行本脚本。"
