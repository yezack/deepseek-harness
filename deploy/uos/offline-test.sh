#!/bin/bash
# UOS 离线包的端到端验证：在无网络命名空间内全新安装、拉起 web、
# 确认预装插件与 chrome-devtools MCP 都可用。
# 用法: sudo unshare -n bash offline-test.sh
set +e
DEST="${DSH_DEST:-/deepseek-harness}"
HOME_DIR=/tmp/offline-home
LOG=/tmp/offline-web.log

echo "############ 离线环境测试 $(date) ############"

ip link set lo up
echo "=== 1. 网络状态确认 ==="
echo "--- 外网探测（应当全部失败）---"
curl -sS -o /dev/null -w "  npmjs -> %{http_code}\n" --max-time 6 https://registry.npmjs.org/ 2>&1 || echo "  npmjs -> 不可达"
curl -sS -o /dev/null -w "  github -> %{http_code}\n" --max-time 6 https://github.com/ 2>&1 || echo "  github -> 不可达"
curl -sS -o /dev/null -w "  1.1.1.1 -> %{http_code}\n" --max-time 6 http://1.1.1.1/ 2>&1 || echo "  1.1.1.1 -> 不可达"
echo "  DNS: $(getent hosts registry.npmjs.org >/dev/null 2>&1 && echo 可解析 || echo 不可解析)"

echo "=== 2. 全新 DSH_HOME 启动 web（模拟首次运行）==="
rm -rf "$HOME_DIR"; mkdir -p "$HOME_DIR"
rm -f "$LOG"
( nohup setsid env DSH_HOME="$HOME_DIR" "$DEST/start-web.sh" > "$LOG" 2>&1 & )
for i in $(seq 1 30); do sleep 3; grep -q 'token=' "$LOG" 2>/dev/null && break; done
echo "--- 启动日志 ---"; cat "$LOG"
echo "--- 监听 ---"; ss -ltn 2>/dev/null | grep 3080 || echo "  3080 未监听"

echo "=== 3. 预装插件是否进入 web profile ==="
MAN="$HOME_DIR/profiles/web/package.json"
if [ -f "$MAN" ]; then
  echo "  profile manifest: $MAN"
  for p in dsh-capability-panel '@michengai/dsh-archive-manager' '@lemoncat7/dsh-ssh'; do
    if grep -q "\"$p\"" "$MAN"; then echo "    ✓ $p"; else echo "    ✗ $p 不在 bundles 列表"; fi
  done
else
  echo "  ✗ 未生成 $MAN"
fi

echo "=== 4. 页面与接口 ==="
T=$(grep -o 'token=[A-Za-z0-9_-]*' "$LOG" 2>/dev/null | head -1 | cut -d= -f2)
if [ -n "$T" ]; then
  curl -sS -o /dev/null -w "  无token=%{http_code}  " --max-time 8 http://127.0.0.1:3080/ 2>&1
  curl -sS -o /dev/null -w "带token=%{http_code}\n" --max-time 8 "http://127.0.0.1:3080/?token=$T" 2>&1
  curl -sS -L --max-time 15 -c /tmp/offline-cj.txt -o /tmp/offline-page.html \
    -w "  首页=%{http_code} size=%{size_download}\n" "http://127.0.0.1:3080/?token=$T" 2>&1
  echo "  兼容层注入: $(grep -c 'data-dsh-web-compat' /tmp/offline-page.html)"
  curl -sS -o /dev/null -w "  /api/session/list=%{http_code}\n" --max-time 15 -b /tmp/offline-cj.txt \
    -X POST -H 'content-type: application/json' -d '{}' http://127.0.0.1:3080/api/session/list 2>&1
else
  echo "  ⚠️ 未取到 token"
fi

echo "=== 5. chrome-devtools MCP 冒烟（stdio 直连，含真实开页）==="
# Chrome 拒绝以 root 启动，root 也拿不到桌面会话的 X 授权，所以以 root 跑这个
# 测试时浏览器必然起不来。真实部署里 start-web.sh 由用户自己运行，因此这里在
# root 下改用 SUDO_USER 复现真实身份，否则测试会报出与产品无关的失败。
RUN_AS=""
if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  RUN_AS="$SUDO_USER"
fi
NODE_BIN="$(command -v node)"
[ -x "$NODE_BIN" ] || NODE_BIN=/var/tmp/dsh-node/bin/node
MCP="$DEST/app/node_modules/@yezack/chrome-devtools-mcp-108/build/src/bin/chrome-devtools-mcp.js"
echo "  node: $NODE_BIN"
echo "  mcp : $MCP"
echo "  运行身份: ${RUN_AS:-当前用户}   浏览器: ${DSH_CHROME_PATH:-/usr/bin/browser}   DISPLAY=${DISPLAY:-:0}"
if [ -f "$MCP" ]; then
  # 保持 stdin 打开，否则服务端在请求处理完前就随 EOF 退出。
  { printf '%s\n' \
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}' \
      '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 8
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    sleep 4
    printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"new_page","arguments":{"url":"about:blank"}}}'
    sleep 60
  } > /tmp/mcp-in.jsonl
  if [ -n "$RUN_AS" ]; then
    chmod 644 /tmp/mcp-in.jsonl
    sudo -n -u "$RUN_AS" env "DISPLAY=${DISPLAY:-:0}" "XAUTHORITY=$(getent passwd "$RUN_AS" | cut -d: -f6)/.Xauthority" \
      "PATH=$(dirname "$NODE_BIN"):/usr/bin:/bin" \
      timeout 150 "$NODE_BIN" "$MCP" --executablePath "${DSH_CHROME_PATH:-/usr/bin/browser}" --isolated \
      < /tmp/mcp-in.jsonl > /tmp/mcp-out.json 2>/tmp/mcp-err.txt
  else
    timeout 150 "$NODE_BIN" "$MCP" --executablePath "${DSH_CHROME_PATH:-/usr/bin/browser}" --isolated \
      < /tmp/mcp-in.jsonl > /tmp/mcp-out.json 2>/tmp/mcp-err.txt
  fi
  echo "  退出码=$?"
  echo "  工具数: $(grep -o '"name":"[a-z_]*"' /tmp/mcp-out.json | sort -u | wc -l)"
  echo "  工具样例:"; grep -o '"name":"[a-z_]*"' /tmp/mcp-out.json | sort -u | head -5 | sed 's/^/    /'
  echo "  真实开页(new_page):"
  if grep -aq 'isError":true' /tmp/mcp-out.json; then
    echo "    ✗ 失败:"; grep -ao '"text":"[^"]*' /tmp/mcp-out.json | tail -1 | head -c 300 | sed 's/^/      /'
    echo
  else
    echo "    ✓ $(grep -oa '"text":"## Pages[^"]*' /tmp/mcp-out.json | head -1)"
  fi
else
  echo "  ✗ 未找到 MCP 脚本"
fi

echo "############ 结束 $(date) ############"
