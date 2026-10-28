#!/bin/bash
# DSH 部署自检（doctor）。把"兼容性体检报告"里的人工检查固化成一条命令。
#
# 用法:
#   ./doctor.sh                 # 检查当前安装（默认 /deepseek-harness）
#   ./doctor.sh /opt/dsh        # 指定安装目录
#   DSH_DEST=/opt/dsh ./doctor.sh
#
# 结论用 [PASS]/[WARN]/[FAIL] 标注；出现 FAIL 时退出码为 1。
# 需要 root 的检查（iptables）在无权限时标 SKIP，不影响其它项。
set -u

DEST="${1:-${DSH_DEST:-/deepseek-harness}}"
NODE_BIN="$DEST/node/bin/node"
[ -x "$NODE_BIN" ] || NODE_BIN="/var/tmp/dsh-node/bin/node"
PROFILE_HOME="${DSH_HOME:-$HOME/.dsh}/profiles/web"
# 插件是独立发布单元，装在自己的目录；旧布局（插件混在本体树里）自动回落。
PLUGIN_ROOT="$DEST/plugins/app"
[ -d "$PLUGIN_ROOT/node_modules" ] || PLUGIN_ROOT="$DEST/app"
# 某个包实际落在哪棵树：插件树优先，其次本体树。
modpath() {
  local name="$1"
  if [ -d "$PLUGIN_ROOT/node_modules/$name" ]; then
    printf '%s\n' "$PLUGIN_ROOT/node_modules/$name"
  else
    printf '%s\n' "$DEST/app/node_modules/$name"
  fi
}
PASS=0; WARN=0; FAIL=0; SKIP=0

ok()   { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
warn() { echo "  [WARN] $*"; WARN=$((WARN + 1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }
skip() { echo "  [SKIP] $*"; SKIP=$((SKIP + 1)); }

echo "============================================"
echo "  DSH 部署自检"
echo "  安装目录: $DEST"
echo "  DSH_HOME: ${DSH_HOME:-$HOME/.dsh}"
echo "============================================"

echo
echo "[1/9] 系统与运行时"
GLIBC="$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$' || true)"
echo "      glibc: ${GLIBC:-未知}"
if [ -x "$NODE_BIN" ]; then
  ok "node $("$NODE_BIN" --version 2>/dev/null)"
else
  bad "找不到 node（$NODE_BIN）"
fi
if [ -f "$DEST/app/node_modules/@deepseek-ai/dsh/lib/bin.js" ]; then
  ok "dsh $("$NODE_BIN" "$DEST/app/node_modules/@deepseek-ai/dsh/lib/bin.js" --version 2>/dev/null | tail -1)"
else
  bad "找不到 dsh 应用（$DEST/app）"
fi
if [ -n "$GLIBC" ] && [ "$(printf '%s\n' "2.29" "$GLIBC" | sort -V | head -1)" = "2.29" ]; then
  : # glibc >= 2.29
else
  warn "glibc ${GLIBC:-未知} < 2.29：系统 glibc 偏旧；univer 等需要新 glibc 的插件靠兼容运行时（见第 8 项）"
fi

echo
echo "[2/9] 原生模块（dlopen 实测）"
NM_FAIL=0
for mod in \
  "@univerjs-pro/engine-formula-rust-binding" \
  "@univerjs-pro/exchange-node-binding" \
  "libsql" \
  "node-pty" \
  "koffi" \
  "sharp"; do
  MOD_PATH="$(modpath "$mod")"
  if "$NODE_BIN" -e "require('$MOD_PATH')" >/dev/null 2>&1; then
    echo "      OK   $mod"
  else
    MSG="$("$NODE_BIN" -e "try{require('$MOD_PATH')}catch(e){console.log(e.message.split('\n')[0])}" 2>&1 | tail -1)"
    case "$mod" in
      @univerjs-pro/*) warn "$mod 加载失败（univer 功能不可用）: $MSG";;
      *) echo "      FAIL $mod: $MSG"; NM_FAIL=$((NM_FAIL + 1));;
    esac
  fi
done
[ "$NM_FAIL" -eq 0 ] && ok "核心原生模块全部可加载" || bad "$NM_FAIL 个核心原生模块加载失败"

echo
echo "[3/9] 预装插件版本（对比安装包清单）"
if [ -f "$DEST/seed-profile.sh" ]; then
  BUNDLES="$(grep -m1 '^BUNDLES=' "$DEST/seed-profile.sh" | sed -E 's/^BUNDLES="//; s/"$//')"
  if [ -z "$BUNDLES" ]; then
    skip "seed-profile.sh 里没有 BUNDLES 清单"
  else
    MISMATCH=0
    for item in $BUNDLES; do
      name="${item%@*}"; want="${item##*@}"
      got="$("$NODE_BIN" -p "require('$(modpath "$name")/package.json').version" 2>/dev/null || true)"
      if [ -z "$got" ]; then
        echo "      MISS $name（未安装，期望 $want）"; MISMATCH=$((MISMATCH + 1))
      elif [ "$got" = "$want" ]; then
        echo "      OK   $name@$got"
      else
        echo "      DIFF $name 期望 $want，实际 $got"; MISMATCH=$((MISMATCH + 1))
      fi
    done
    [ "$MISMATCH" -eq 0 ] && ok "12 个预装插件版本与清单一致" || warn "$MISMATCH 个插件与清单不一致"
    echo "      插件单元: $PLUGIN_ROOT"
    if [ -f "$DEST/plugins/.installed-version" ]; then
      PLUG_VER="$(grep -o '"version": *"[^"]*"' "$DEST/plugins/.installed-version" 2>/dev/null | head -1 | cut -d'"' -f4)"
      ok "插件单元版本: ${PLUG_VER:-未知}"
    elif [ "$PLUGIN_ROOT" = "$DEST/app" ]; then
      warn "插件混在本体树里（旧布局；新包会把插件装到 $DEST/plugins）"
    fi
  fi
else
  skip "找不到 $DEST/seed-profile.sh"
fi

echo
echo "[4/9] 浏览器"
SYS_BROWSER=""
for candidate in /usr/share/browser/browser /usr/bin/browser; do
  [ -x "$candidate" ] && { SYS_BROWSER="$candidate"; break; }
done
if [ -n "$SYS_BROWSER" ]; then
  PKG_VER="$(dpkg-query -W -f='${Version}' org.deepin.browser 2>/dev/null || true)"
  ok "系统浏览器 $SYS_BROWSER（org.deepin.browser ${PKG_VER:-未安装为 deb}）"
else
  warn "没找到系统浏览器（/usr/share/browser/browser）"
fi
if [ -x /usr/bin/browser360ent-cn-stable ]; then
  ok "拉起用浏览器 360: $(/usr/bin/browser360ent-cn-stable --version 2>/dev/null | tail -1)"
else
  warn "没找到 360 企业浏览器（/usr/bin/browser360ent-cn-stable）"
fi
CHROME_EXPORT="$(grep -o 'DSH_CHROME_PATH="[^"]*"' "$DEST/start-web.sh" 2>/dev/null | head -1)"
if [ -n "$CHROME_EXPORT" ]; then
  echo "      start-web.sh: $CHROME_EXPORT"
  case "$CHROME_EXPORT" in
    *browser360ent*) ok "MCP/univer 使用 360（Chrome 108）";;
    *) warn "MCP/univer 未指向 360，实际: $CHROME_EXPORT";;
  esac
else
  warn "start-web.sh 里没有 DSH_CHROME_PATH 导出"
fi

echo
echo "[5/9] 服务状态"
if ss -ltn 2>/dev/null | grep -q ':3080'; then
  BIND="$(ss -ltn 2>/dev/null | grep ':3080' | awk '{print $4}' | head -1)"
  ok "监听 $BIND"
  case "$BIND" in
    127.0.0.1:*) echo "      仅回环：本机可用；局域网访问需要 enable-lan.sh 的 DNAT 规则";;
    0.0.0.0:*)   warn "绑定通配地址（0.2.1 本应拒绝，配置可能异常）";;
    *) echo "      绑定具体地址：局域网可直连，本机 127.0.0.1 不可用（需 DNAT 或改为回环）";;
  esac
else
  warn "没有进程监听 3080（服务未启动？）"
fi
LOG="$HOME/web.log"
if [ -f "$LOG" ]; then
  # grep -c 在 0 匹配时退出码为 1，不能接 `|| echo 0`（会把 "0\n0" 塞进变量）。
  FAILED="$(grep -ac 'startup failed' "$LOG" 2>/dev/null | head -1 || true)"
  FAILED="${FAILED:-0}"
  INADT="$(grep -ac 'did not activate' "$LOG" 2>/dev/null | head -1 || true)"
  INADT="${INADT:-0}"
  [ "$FAILED" -eq 0 ] && ok "最近启动无 startup failed" || bad "最近启动有 $FAILED 条 startup failed"
  [ "$INADT" -eq 0 ] && ok "没有未激活的插件" || warn "$INADT 条 did not activate（插件被跳过）"
  TOKEN_LINE="$(grep -a 'dsh web:' "$LOG" 2>/dev/null | tail -1)"
  [ -n "$TOKEN_LINE" ] && echo "      $TOKEN_LINE"
else
  skip "找不到 $LOG（用 start-web.sh 启动才有）"
fi

echo
echo "[6/9] 网络（局域网访问）"
LAN_IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.' | head -1)"
[ -n "$LAN_IP" ] && echo "      局域网 IP: $LAN_IP" || warn "没有局域网 IPv4 地址"
if sudo -n iptables -t nat -S >/dev/null 2>&1; then
  RULES="$(sudo -n iptables -t nat -S 2>/dev/null | grep -c 'DNAT\|REDIRECT' || true)"
  [ "${RULES:-0}" -gt 0 ] && ok "转发规则 $RULES 条" || warn "没有 DNAT/REDIRECT 规则（局域网访问不通，跑 sudo ./enable-lan.sh）"
  echo "      route_localnet: $(cat /proc/sys/net/ipv4/conf/all/route_localnet 2>/dev/null || echo '?')"
else
  skip "无 sudo 权限，跳过 iptables 检查"
fi

echo
echo "[7/9] profile 配置"
PATCH="$PROFILE_HOME/cordis.patch.yml"
if [ -f "$PATCH" ]; then
  ok "存在 $PATCH"
  for mark in 'default-disabled plugins' 'render browser'; do
    B="$(grep -c ">>> dsh-offline: $mark" "$PATCH" 2>/dev/null | head -1 || true)"
    E="$(grep -c "<<< dsh-offline: $mark" "$PATCH" 2>/dev/null | head -1 || true)"
    [ "${B:-0}" = "${E:-0}" ] && echo "      标记块「$mark」配对正常（${B:-0} 对）" || bad "标记块「$mark」不配对：>>> ${B:-0} 个，<<< ${E:-0} 个"
  done
  if grep -qE '^\s*host:\s*["'"'"']?(0\.0\.0\.0|::)' "$PATCH" 2>/dev/null; then
    bad "仍有 0.0.0.0 通配绑定（0.2.1 会启动失败）"
  else
    ok "没有 0.0.0.0 通配绑定"
  fi
  # 孤儿判定：entry 多数来自各 bundle 的 cordis.patch.yml（webserver/univer/dream-skin
  # 都不在 profile 的 cordis.yml 文本里），必须把 bundle patch 的 id 一并算作已知。
  KNOWN="$(find "$DEST/app/node_modules" "$PLUGIN_ROOT/node_modules" -maxdepth 3 -name 'cordis.patch.yml' -exec grep -hoE '^\s*-\s*id:\s*\S+' {} + 2>/dev/null | sed -E 's/^\s*-\s*id:\s*//' | sort -u)"
  KNOWN="$KNOWN$(printf '\n%s' "$(grep -oE '^\s*-\s*id:\s*\S+' "$PROFILE_HOME/cordis.yml" 2>/dev/null | sed -E 's/^\s*-\s*id:\s*//')")"
  if [ -z "$KNOWN" ]; then
    skip "无法枚举已知 entry，跳过孤儿行检查"
  else
    export KNOWN_IDS="$KNOWN"
    ORPHANS="$("$NODE_BIN" -e '
const fs = require("node:fs")
const [patchFile] = process.argv.slice(1)
const text = fs.readFileSync(patchFile, "utf8")
const known = new Set((process.env.KNOWN_IDS || "").split("\n").map((s) => s.trim()).filter(Boolean))
const lines = text.split("\n")
// insert: 块内的 - id 行定义新 entry（例如模型配置），不是孤儿。
const stack = []
const suspicious = []
for (let i = 0; i < lines.length; i += 1) {
  const raw = lines[i]
  const trimmed = raw.trim()
  if (trimmed === "" || trimmed.startsWith("#")) continue
  const indent = raw.search(/\S/u)
  while (stack.length > 0 && indent <= stack[stack.length - 1]) stack.pop()
  if (/^-?\s*insert:/u.test(trimmed)) { stack.push(indent); continue }
  const m = /^-\s*id:\s*(\S+)/u.exec(trimmed)
  if (m === null) continue
  if (stack.length > 0) continue
  if (known.has(m[1])) continue
  suspicious.push(m[1])
}
if (suspicious.length > 0) console.log(suspicious.join(" "))
' "$PATCH" 2>/dev/null)"
    if [ -n "$ORPHANS" ]; then
      warn "可疑 patch 行（没有 bundle/cordis.yml 提供该 entry，仅供核对，不会被自动删除）: $(echo "$ORPHANS" | tr '\n' ' ')"
    else
      ok "没有可疑 patch 行"
    fi
  fi
  if "$NODE_BIN" -e '
const fs = require("node:fs")
const yaml = require(process.argv[1])
const jsTag = new yaml.Type("tag:yaml.org,2002:js", { kind: "scalar", construct: (d) => d })
yaml.load(fs.readFileSync(process.argv[2], "utf8"), { schema: yaml.DEFAULT_SCHEMA.extend([jsTag]) })
' "$DEST/app/node_modules/js-yaml" "$PATCH" >/dev/null 2>&1; then
    ok "cordis.patch.yml 语法正确"
  else
    bad "cordis.patch.yml 语法错误（YAML 解析失败）"
  fi
  # 播种标记：profile 由安装阶段写入（start 不再改配置），标记与当前安装版本对不上
  # 说明插件版本没同步，需要重跑 seed-profile.sh。
  STATE="$PROFILE_HOME/.dsh-offline-state.json"
  if [ -f "$STATE" ]; then
    SEEDED="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["dshVersion"])' "$STATE" 2>/dev/null || true)"
    WANT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$DEST/app/node_modules/@deepseek-ai/dsh/package.json" 2>/dev/null || true)"
    if [ -n "$SEEDED" ] && [ -n "$WANT" ] && [ "$SEEDED" = "$WANT" ]; then
      ok "profile 播种版本与安装一致（dsh $SEEDED）"
    else
      warn "profile 由 dsh ${SEEDED:-未知} 播种，当前安装 ${WANT:-未知}（运行 seed-profile.sh 同步）"
    fi
  else
    warn "没有播种标记 .dsh-offline-state.json（旧 profile；安装阶段会写入）"
  fi
else
  warn "没有 $PATCH（安装阶段应由 seed-profile.sh 创建）"
fi

echo
echo "[8/9] 兼容运行时（新 glibc，供插件子进程）"
GLIBC_DIR="/var/tmp/dsh-glibc"
NODE_GLIBC="/var/tmp/dsh-node/bin/node-glibc"
if [ -x "$GLIBC_DIR/ld-linux-x86-64.so.2" ] && [ -x "$NODE_GLIBC" ]; then
  ok "兼容运行时已安装: $("$GLIBC_DIR/ld-linux-x86-64.so.2" --version 2>/dev/null | head -1)"
  if "$NODE_GLIBC" --version >/dev/null 2>&1; then
    ok "wrapper 可运行: $("$NODE_GLIBC" --version 2>/dev/null)"
  else
    bad "wrapper 无法运行（$NODE_GLIBC）"
  fi
  # 这是最关键的一项：宿主 glibc 太旧时，univer 的绑定只能靠兼容运行时加载。
  UNIVER_FORMULA="$(modpath '@univerjs-pro/engine-formula-rust-binding')"
  UNIVER_EXCHANGE="$(modpath '@univerjs-pro/exchange-node-binding')"
  if "$NODE_GLIBC" -e "require('$UNIVER_FORMULA')" >/dev/null 2>&1 \
     && "$NODE_GLIBC" -e "require('$UNIVER_EXCHANGE')" >/dev/null 2>&1; then
    ok "univer 两个原生绑定在兼容运行时下可加载（office 内容读写可用）"
  else
    warn "univer 原生绑定在兼容运行时下仍加载失败"
  fi
  if "$NODE_GLIBC" -e "require('dns').lookup('localhost',(e)=>process.exit(e?1:0))" >/dev/null 2>&1; then
    ok "兼容运行时下 DNS 解析正常（NSS 模块完整）"
  else
    warn "兼容运行时下 DNS 解析失败（缺 NSS 模块）"
  fi
  if grep -q 'UNIVER_NODE_BINARY' "$DEST/start-web.sh" 2>/dev/null; then
    ok "start-web.sh 已导出 UNIVER_NODE_BINARY / DSH_NODE_GLIBC"
  else
    warn "start-web.sh 未导出兼容运行时变量（univer 会回落到宿主 glibc）"
  fi
else
  warn "没有兼容运行时（/var/tmp/dsh-glibc 或 node-glibc 缺失）"
fi

echo
echo "[9/9] 桌面壳（可选，Electron：主窗口 + 托盘）"
ELECTRON_DIR="/var/tmp/dsh-electron"
if [ -x "$ELECTRON_DIR/electron" ] && [ -f "$ELECTRON_DIR/app/main.js" ]; then
  ok "桌面壳已安装: Electron $("$ELECTRON_DIR/electron" --no-sandbox --version 2>/dev/null | head -1)"
  if [ -f "$DEST/desktop.sh" ]; then ok "启动器: $DEST/desktop.sh"; else warn "缺少 $DEST/desktop.sh"; fi
  if ldconfig -p 2>/dev/null | grep -qi 'appindicator'; then
    ok "托盘库存在（libappindicator/ayatana）"
  else
    warn "缺少 libappindicator（托盘图标可能不显示）"
  fi
  ENTRY="$HOME/.local/share/applications/dsh-desktop.desktop"
  if [ -f "$ENTRY" ]; then ok "桌面入口: $ENTRY"; else warn "没有桌面入口（可直接运行 desktop.sh）"; fi
else
  warn "未安装桌面壳（安装时 DSH_DESKTOP=1 可启用）"
fi

echo
echo "============================================"
echo "  结论: PASS $PASS / WARN $WARN / FAIL $FAIL / SKIP $SKIP"
echo "============================================"
if [ "$FAIL" -gt 0 ]; then
  echo "  有 $FAIL 项 FAIL，请按上面的提示处理；日志打包可用 collect-logs.sh"
  exit 1
fi
exit 0
