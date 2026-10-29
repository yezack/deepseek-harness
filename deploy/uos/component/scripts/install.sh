#!/bin/bash
# dsh 脚本组件（scripts）：安装器、自检、profile 播种、启动/卸载/预检脚本生成。
#
# 组件包结构（tar.gz）：
#   package/component.json
#   package/install.sh
#   package/payload/scripts/   installer.sh、seed-profile.sh、doctor.sh、maintain-profile.mjs、
#                              collect-logs.sh、enable-lan.sh、README.txt
#
# 这一层刻意保持很小（几十 KB）：改脚本只需要发一个新的 scripts 组件，不必重下本体。
#
# 用法： ./install.sh --component <组件包.tar.gz> [--upgrade]
set -e

DEST="${DSH_DEST:-/deepseek-harness}"
PLUGINS_DIR="$DEST/plugins"
INSTALL_NODE_DIR="${DSH_NODE_DIR:-/var/tmp/dsh-node}"
GLIBC_DIR="${DSH_GLIBC_DIR:-/var/tmp/dsh-glibc}"

COMPONENT="${DSH_COMPONENT_FILE:-}"
UPGRADE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --component) COMPONENT="${2:-}"; shift 2 ;;
    --upgrade) UPGRADE=1; shift ;;
    --help|-h) echo "用法: ./install.sh --component <组件包.tar.gz> [--upgrade]"; exit 0 ;;
    *) shift ;;
  esac
done
if [ -z "$COMPONENT" ] || [ ! -f "$COMPONENT" ]; then
  echo "[错误] 需要组件包： --component <tar.gz>" >&2; exit 1
fi

STAGE="$DEST/.install-stage-scripts"
rm -rf "$STAGE"; mkdir -p "$STAGE"
trap 'rm -rf "$STAGE"' EXIT
tar xzf "$COMPONENT" -C "$STAGE" --strip-components=1 package/payload 2>/dev/null || {
  echo "[错误] 组件包结构异常：缺 package/payload" >&2; exit 1; }
PAYLOAD="$STAGE/payload"
[ -d "$PAYLOAD/scripts" ] || { echo "[错误] payload 里没有 scripts/" >&2; exit 1; }
[ -f "$PAYLOAD/scripts/seed-profile.sh" ] || { echo "[错误] payload/scripts 里没有 seed-profile.sh（组件包结构异常）" >&2; exit 1; }

TARGET_USER="${DSH_USER:-${SUDO_USER:-}}"
TARGET_HOME=""
[ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ] && TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"

echo "== 安装脚本组件 =="

# ---------- 1. 随装脚本 ----------
echo "[1/4] 安装脚本 ..."
for script in "$PAYLOAD"/scripts/*; do
  [ -f "$script" ] || continue
  base="$(basename "$script")"
  cp "$script" "$DEST/$base"
  case "$base" in
    *.sh) chmod 755 "$DEST/$base" ;;
    *) chmod 644 "$DEST/$base" ;;
  esac
done
[ -f "$DEST/seed-profile.sh" ] || { echo "[错误] 组件包缺 seed-profile.sh" >&2; exit 1; }

# ---------- 2. 系统浏览器探测 ----------
echo "[2/4] 浏览器检测 ..."
if [ -n "${DSH_CHROME_PATH:-}" ]; then
  CHROME_BIN="$DSH_CHROME_PATH"
else
  CHROME_BIN=""
  for candidate in /usr/bin/browser /usr/bin/browser360ent-cn-stable /usr/bin/chromium /usr/bin/google-chrome; do
    if [ -x "$candidate" ]; then CHROME_BIN="$candidate"; break; fi
  done
fi
if [ -n "$CHROME_BIN" ]; then
  echo "      系统浏览器: $CHROME_BIN"
else
  echo "      [警告] 未找到可用的系统浏览器；MCP / 浏览器类插件将不可用（安装继续）"
  CHROME_BIN="/usr/bin/browser"
fi
CHROME_HOME="/var/tmp/dsh-chrome-home"
mkdir -p "$CHROME_HOME"
chmod 1777 "$CHROME_HOME" 2>/dev/null || true

# ---------- 3. 预检 / 启动 / 卸载脚本 ----------
echo "[3/4] 生成 preflight / start-web / uninstall ..."
cat > "$DEST/preflight.sh" <<'PREFLIGHT_TEMPLATE'
#!/bin/bash
# 启动前只读预检。不写任何文件；发现问题只打印提示与修复命令。
set -u
PREFLIGHT_DEST="__DEST__"
export DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
PREFLIGHT_NODE="__NODE__"
PROFILE="$DSH_HOME/profiles/web"
PATCH="$PROFILE/cordis.patch.yml"
problems=0
note() { echo "  [预检] $*"; }
fix()  { echo "          修复: $*"; }
if [ ! -f "$PROFILE/package.json" ]; then
  note "profile 不存在（$PROFILE）"
  fix "sudo $PREFLIGHT_DEST/installer.sh seed"
  problems=$((problems + 1))
else
  MISSING="$("$PREFLIGHT_NODE" -e '
const fs = require("node:fs")
const path = require("node:path")
const profile = process.argv[1]
let manifest
try { manifest = JSON.parse(fs.readFileSync(path.join(profile, "package.json"), "utf8")) } catch (error) { process.exit(0) }
const bundles = (manifest.dsh && manifest.dsh.profile && manifest.dsh.profile.bundles) || []
const thirdParty = bundles.filter((name) => !name.startsWith("@deepseek-ai/"))
const missing = thirdParty.filter((name) => !fs.existsSync(path.join(profile, "node_modules", name, "package.json")))
if (missing.length > 0) console.log(missing.join(" "))
' "$PROFILE" 2>/dev/null)"
  if [ -n "$MISSING" ]; then
    note "已安装插件未链接到 profile: $MISSING"
    fix "sudo $PREFLIGHT_DEST/installer.sh seed"
    problems=$((problems + 1))
  fi
  if grep -qE '^\s*host:\s*["'"'"']?(0\.0\.0\.0|::)' "$PATCH" 2>/dev/null; then
    note "webserver 仍绑定 0.0.0.0（0.2.1 会拒绝启动）"
    fix "sudo $PREFLIGHT_DEST/installer.sh seed"
    problems=$((problems + 1))
  fi
  if [ -f "$PROFILE/.dsh-offline-state.json" ]; then
    SEEDED="$("$PREFLIGHT_NODE" -p 'JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).dshVersion' "$PROFILE/.dsh-offline-state.json" 2>/dev/null)"
    WANT="$("$PREFLIGHT_NODE" -p 'require(process.argv[1]).version' "$PREFLIGHT_DEST/app/node_modules/@deepseek-ai/dsh/package.json" 2>/dev/null)"
    if [ -n "$SEEDED" ] && [ -n "$WANT" ] && [ "$SEEDED" != "$WANT" ]; then
      note "profile 由 dsh $SEEDED 播种，当前安装是 $WANT"
      fix "sudo $PREFLIGHT_DEST/installer.sh seed"
      problems=$((problems + 1))
    fi
  else
    note "profile 没有播种标记（.dsh-offline-state.json）"
    fix "sudo $PREFLIGHT_DEST/installer.sh seed"
    problems=$((problems + 1))
  fi
fi
if [ "$problems" -gt 0 ]; then
  echo "  [预检] 共 $problems 个问题；服务仍会启动，但插件可能不完整"
fi
exit 0
PREFLIGHT_TEMPLATE
sed -i "s|__DEST__|$DEST|g; s|__NODE__|$INSTALL_NODE_DIR/bin/node|g" "$DEST/preflight.sh"
chmod 755 "$DEST/preflight.sh"

cat > "$DEST/start-web.sh" <<LAUNCH
#!/bin/bash
DEST="$DEST"
PLUGINS="$PLUGINS_DIR"
export DSH_HOME="\${DSH_HOME:-\$HOME/.dsh}"
export PATH="$INSTALL_NODE_DIR/bin:\$PATH"
export NARB_NATIVE_CACHE_DIR=/var/tmp/dsh-native-cache
export DSH_CHROME_DEVTOOLS_MCP="$DEST/app/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js"
export DSH_CHROME_PATH="\${DSH_CHROME_PATH:-$CHROME_BIN}"
export DSH_CHROME_HOME="\${DSH_CHROME_HOME:-$CHROME_HOME}"
export DISPLAY="\${DISPLAY:-:0}"
mkdir -p "\$DSH_HOME" "\$DSH_CHROME_HOME" /var/tmp/dsh-native-cache 2>/dev/null
"\$DEST/preflight.sh" || true
cd "\$DEST"
export UNIVER_NODE_BINARY="\${UNIVER_NODE_BINARY:-$INSTALL_NODE_DIR/bin/node-glibc}"
export DSH_NODE_GLIBC="\${DSH_NODE_GLIBC:-$INSTALL_NODE_DIR/bin/node-glibc}"
if [ -n "\${DSH_CHROME_PATH:-}" ]; then echo "  拉起用浏览器: \$DSH_CHROME_PATH"; fi
if [ -x "$INSTALL_NODE_DIR/bin/node-glibc" ]; then
  echo "  兼容运行时:   \$DSH_NODE_GLIBC（glibc $("$GLIBC_DIR/ld-linux-x86-64.so.2" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)）"
fi
COUNT=\$(ls -d "\$PLUGINS"/*/ 2>/dev/null | wc -l)
echo "  已安装插件:   \$COUNT 个（\$PLUGINS）"
echo "============================================"
echo "  DeepSeek Harness - Web 服务"
echo "  浏览器打开下面打印的带 token 的地址"
echo "  关闭本窗口即停止服务"
echo "============================================"
exec "$INSTALL_NODE_DIR/bin/node" "$DEST/app/node_modules/@deepseek-ai/dsh/lib/bin.js" web --port 3080 "\$@"
LAUNCH
chmod 755 "$DEST/start-web.sh"

cat > "$DEST/uninstall.sh" <<UNINST
#!/bin/bash
echo "将删除：$DEST（含全部插件组件）以及 $INSTALL_NODE_DIR"
read -p "确认？(y/N) " a
[ "\$a" = "y" ] || exit 0
rm -rf "$DEST" "$INSTALL_NODE_DIR" /var/tmp/dsh-native-cache
echo "已删除。"
UNINST
chmod 755 "$DEST/uninstall.sh"

# ---------- 4. 单独安装时的 profile 播种 ----------
echo "[4/4] profile 播种 ..."
if [ "${DSH_SKIP_SEED:-0}" != "1" ] && [ -f "$DEST/seed-profile.sh" ]; then
  if [ "$(id -u)" = "0" ] && [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ] && [ -n "$TARGET_HOME" ] && [ -d "$TARGET_HOME" ]; then
    install -d -m 700 -o "$TARGET_USER" "$TARGET_HOME/.dsh" 2>/dev/null || true
    sudo -u "$TARGET_USER" -H env DSH_HOME="$TARGET_HOME/.dsh" SEED_NODE="$INSTALL_NODE_DIR/bin/node" \
      bash "$DEST/seed-profile.sh" "$DEST" || echo "      [警告] profile 播种失败"
  else
    SEED_NODE="$INSTALL_NODE_DIR/bin/node" bash "$DEST/seed-profile.sh" "$DEST" \
      || echo "      [警告] profile 播种失败（请以桌面用户身份手动重跑 seed-profile.sh）"
  fi
else
  echo "      已跳过（由 installer 统一播种）"
fi

echo
echo "============================================"
echo "  脚本组件安装完成"
echo "  启动 Web:  $DEST/start-web.sh"
echo "  组件管理:  sudo $DEST/installer.sh status"
echo "============================================"
