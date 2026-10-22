#!/bin/bash
# 打包现场诊断信息，便于远端排查（发回开发侧即可复现问题）。
#
# 用法: ./collect-logs.sh [安装目录]
# 产物: ~/dsh-logs-<时间戳>.tar.gz
set -u

DEST="${1:-${DSH_DEST:-/deepseek-harness}}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/dsh-logs-$STAMP.tar.gz"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/profile"
{
  echo "=== 主机 ==="
  uname -a
  echo
  echo "=== glibc ==="
  ldd --version 2>/dev/null | head -1
  echo
  echo "=== 安装目录 ==="
  ls -la "$DEST" 2>/dev/null
  echo
  echo "=== node/dsh 版本 ==="
  "$DEST/node/bin/node" --version 2>/dev/null || echo "node 不可用"
  "$DEST/node/bin/node" "$DEST/app/node_modules/@deepseek-ai/dsh/lib/bin.js" --version 2>/dev/null | tail -1
  echo
  echo "=== 端口与地址 ==="
  ss -ltnp 2>/dev/null | grep -E '3080|LISTEN' | head -20
  ip -4 -o addr show scope global
  echo
  echo "=== iptables nat ==="
  sudo -n iptables -t nat -S 2>/dev/null || echo "无 sudo 权限"
  echo
  echo "=== route_localnet ==="
  cat /proc/sys/net/ipv4/conf/all/route_localnet 2>/dev/null
  echo
  echo "=== 浏览器 ==="
  dpkg -l 2>/dev/null | grep -iE 'browser' || true
  ls -l /usr/bin/browser /usr/bin/browser360ent-cn-stable 2>/dev/null
  echo
  echo "=== 进程 ==="
  pgrep -af '[b]in.js web' || echo "dsh web 未运行"
} > "$WORK/system.txt" 2>&1

# 启动日志（最近两份）与 profile 配置
mkdir -p "$WORK/logs"
if [ -d "$HOME/.dsh/logs" ]; then
  ls -t "$HOME/.dsh/logs"/startup-*.log 2>/dev/null | head -2 | while read -r f; do cp "$f" "$WORK/logs/" 2>/dev/null; done
fi
[ -f "$HOME/web.log" ] && cp "$HOME/web.log" "$WORK/logs/web.log" 2>/dev/null
for f in cordis.patch.yml package.json cordis.yml; do
  [ -f "$HOME/.dsh/profiles/web/$f" ] && cp "$HOME/.dsh/profiles/web/$f" "$WORK/profile/$f" 2>/dev/null
done
[ -f "$HOME/web.log" ] && cp "$HOME/web.log" "$WORK/../web.log" 2>/dev/null

# doctor 输出
if [ -x "$DEST/doctor.sh" ]; then
  "$DEST/doctor.sh" "$DEST" > "$WORK/doctor.txt" 2>&1 || true
fi

tar czf "$OUT" -C "$WORK" . 2>/dev/null
echo "已生成: $OUT"
echo "大小: $(du -h "$OUT" | cut -f1)"
echo "内容: system.txt / doctor.txt / logs/ / profile/"
