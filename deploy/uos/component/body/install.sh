#!/bin/bash
# dsh 本体组件的独立安装脚本。
#
# 组件包结构（tar.gz）：
#   package/component.json      组件元数据（name/version/dshVersion）
#   package/install.sh          本脚本
#   package/payload/app/        dsh 与全部官方依赖（node_modules）
#   package/payload/node/       Node 运行时
#   package/payload/scripts/    seed-profile.sh 等随装脚本（installer 也在其中）
#   package/payload/desktop/    （可选）Electron 壳：app/ + electron-v*.zip
#   package/payload/tools/      （可选）pnpm / glibc 兼容运行时
#   （浏览器 deb 不再随包携带：界面用 Electron，MCP 用系统浏览器探测）
#
# 装到 $DSH_DEST：app/ node/ 脚本。**不碰 $DSH_DEST/plugins**（插件是独立组件）。
#
# 用法： ./install.sh --component <组件包.tar.gz> [--upgrade]
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${DSH_DEST:-/deepseek-harness}"
PLUGINS_DIR="$DEST/plugins"
INSTALL_NODE_DIR="${DSH_NODE_DIR:-/var/tmp/dsh-node}"
GLIBC_DIR="${DSH_GLIBC_DIR:-/var/tmp/dsh-glibc}"
ELECTRON_DIR="${DSH_ELECTRON_DIR:-/var/tmp/dsh-electron}"
DEFAULT_UPDATE_URL="http://autoupdate.kxzd.sjq.sh/deepseek_harness/latest.json"

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
  echo "[错误] 需要组件包： --component <tar.gz>（或环境变量 DSH_COMPONENT_FILE）" >&2
  exit 1
fi
COMPONENT="$(cd "$(dirname "$COMPONENT")" && pwd)/$(basename "$COMPONENT")"


STAGE="$DEST/.install-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
trap 'rm -rf "$STAGE"' EXIT

echo "== 安装 dsh 本体组件 =="
echo "   安装位置: $DEST"
echo "   组件包:   $COMPONENT"
echo "   解包（约 1.7GB，请稍候）..."
tar xzf "$COMPONENT" -C "$STAGE" --strip-components=1 package/payload 2>/dev/null || {
  echo "[错误] 组件包结构异常：缺 package/payload" >&2
  exit 1
}
PAYLOAD="$STAGE/payload"
[ -d "$PAYLOAD/app/node_modules" ] || { echo "[错误] payload 里没有 app/node_modules" >&2; exit 1; }
[ -x "$PAYLOAD/node/bin/node" ] || { echo "[错误] payload 里没有 node/bin/node" >&2; exit 1; }

# 元数据（版本、来源组件包）
META="$STAGE/package/component.json"
tar xzf "$COMPONENT" -C "$STAGE" package/component.json 2>/dev/null || true

# ---------- 1. 本体依赖树 ----------
echo "[1/6] 安装本体 app/ ..."
rm -rf "$DEST/app"
mv "$PAYLOAD/app" "$DEST/app"

# ---------- 2. Node 运行时 + 白名单 ----------
echo "[2/6] 安装 Node 运行时 ..."
rm -rf "$DEST/node"
mv "$PAYLOAD/node" "$DEST/node"
rm -rf "$INSTALL_NODE_DIR"
mkdir -p "$INSTALL_NODE_DIR"
cp -r "$DEST/node/." "$INSTALL_NODE_DIR/"

mkdir -p /var/tmp/dsh-native-cache
chmod 1777 /var/tmp/dsh-native-cache 2>/dev/null || true

# koffi 的原生 .node 必须从白名单路径加载。
KOROMIX_SRC="$DEST/app/node_modules/@koromix/koffi-linux-x64"
KOROMIX_WH="/var/tmp/dsh-native-cache/koromix/koffi-linux-x64"
if [ -d "$KOROMIX_SRC" ]; then
  mkdir -p /var/tmp/dsh-native-cache/koromix
  rm -rf "$KOROMIX_WH"
  cp -r "$KOROMIX_SRC" "$KOROMIX_WH"
  mkdir -p "$DEST/app/node_modules/koffi/build/koffi"
  ln -sfn "$KOROMIX_WH/linux_x64" "$DEST/app/node_modules/koffi/build/koffi/linux_x64"
  echo "      koffi 原生模块已链接到白名单路径"
fi

# npm/npx shim：官方 tarball 里是相对符号链接，cp -r 后会退化，这里无条件重建。
NPM_CLI="$INSTALL_NODE_DIR/lib/node_modules/npm/bin/npm-cli.js"
if [ -f "$NPM_CLI" ]; then
  printf '#!/bin/sh\nexec "%s/bin/node" "%s" "$@"\n' "$INSTALL_NODE_DIR" "$NPM_CLI" > "$INSTALL_NODE_DIR/bin/npm"
  chmod 755 "$INSTALL_NODE_DIR/bin/npm"
  NPX_CLI="$INSTALL_NODE_DIR/lib/node_modules/npm/bin/npx-cli.js"
  if [ -f "$NPX_CLI" ]; then
    printf '#!/bin/sh\nexec "%s/bin/node" "%s" "$@"\n' "$INSTALL_NODE_DIR" "$NPX_CLI" > "$INSTALL_NODE_DIR/bin/npx"
    chmod 755 "$INSTALL_NODE_DIR/bin/npx"
  fi
  echo "      npm shim 已修正: $("$INSTALL_NODE_DIR/bin/npm" --version 2>/dev/null || echo '仍不可用')"
fi

# 内置 pnpm（plugin-manager 用）
PNPM_TGZ=""
for candidate in "$PAYLOAD"/tools/pnpm-*.tgz; do [ -f "$candidate" ] && { PNPM_TGZ="$candidate"; break; }; done
if [ -n "$PNPM_TGZ" ] && [ -f "$INSTALL_NODE_DIR/lib/node_modules/npm/package.json" ]; then
  PNPM_DEST="$INSTALL_NODE_DIR/lib/node_modules/pnpm"
  rm -rf "$PNPM_DEST"; mkdir -p "$PNPM_DEST"
  if tar xzf "$PNPM_TGZ" -C "$PNPM_DEST" --strip-components=1 2>/dev/null && [ -f "$PNPM_DEST/bin/pnpm.mjs" ]; then
    printf '#!/bin/sh\nexec "%s/bin/node" "%s/bin/pnpm.mjs" "$@"\n' "$INSTALL_NODE_DIR" "$PNPM_DEST" > "$INSTALL_NODE_DIR/bin/pnpm"
    chmod 755 "$INSTALL_NODE_DIR/bin/pnpm"
    printf '#!/bin/sh\nexec "%s/bin/node" "%s/bin/pnpx.mjs" "$@"\n' "$INSTALL_NODE_DIR" "$PNPM_DEST" > "$INSTALL_NODE_DIR/bin/pnpx"
    chmod 755 "$INSTALL_NODE_DIR/bin/pnpx"
    echo "      pnpm 已内置: $("$INSTALL_NODE_DIR/bin/pnpm" --version 2>/dev/null || echo '安装失败')"
  else
    echo "      [警告] pnpm 解包失败，plugin-manager 的 pnpm 操作不可用"
  fi
fi

# 项目级兼容运行时（新 glibc，供 univer 等插件子进程）。
NODE_GLIBC="$INSTALL_NODE_DIR/bin/node-glibc"
GLIBC_TARBALL=""
for candidate in "$PAYLOAD"/tools/glibc*.tar.gz; do [ -f "$candidate" ] && { GLIBC_TARBALL="$candidate"; break; }; done
if [ -n "$GLIBC_TARBALL" ]; then
  GLIBC_STAGE="$(mktemp -d "$STAGE/glibc.XXXXXX")"
  tar xzf "$GLIBC_TARBALL" -C "$GLIBC_STAGE"
  GLIBC_SRC="$(find "$GLIBC_STAGE" -maxdepth 1 -mindepth 1 -type d | head -1)"
  if [ -n "$GLIBC_SRC" ]; then
    rm -rf "$GLIBC_DIR"
    mkdir -p "$(dirname "$GLIBC_DIR")"
    mv "$GLIBC_SRC" "$GLIBC_DIR"
  fi
  rm -rf "$GLIBC_STAGE"
  chmod 755 "$GLIBC_DIR/ld-linux-x86-64.so.2" 2>/dev/null || true
  cat > "$NODE_GLIBC" <<GLIBC_WRAPPER
#!/bin/sh
# 用随包的新 glibc 运行 node。宿主 DSH 不使用本脚本；需要新 glibc 的插件子进程
# 通过 UNIVER_NODE_BINARY（univer）或 DSH_NODE_GLIBC（通用）引用它。
exec "$GLIBC_DIR/ld-linux-x86-64.so.2" --library-path "$GLIBC_DIR:$INSTALL_NODE_DIR/lib" "$INSTALL_NODE_DIR/bin/node" "\$@"
GLIBC_WRAPPER
  chmod 755 "$NODE_GLIBC"
  echo "      兼容运行时: $("$NODE_GLIBC" --version 2>/dev/null || echo '不可用')  [$("$GLIBC_DIR/ld-linux-x86-64.so.2" --version 2>/dev/null | head -1)]"
else
  echo "      [提示] 组件包内没有 tools/glibc*.tar.gz，跳过兼容运行时"
fi

# ---------- 3. 随装脚本 ----------
echo "[3/6] 安装脚本 ..."
if [ -d "$PAYLOAD/scripts" ]; then
  for script in "$PAYLOAD"/scripts/*; do
    [ -f "$script" ] || continue
    base="$(basename "$script")"
    cp "$script" "$DEST/$base"
    case "$base" in
      *.sh) chmod 755 "$DEST/$base" ;;
      *) chmod 644 "$DEST/$base" ;;
    esac
  done
fi
[ -f "$DEST/seed-profile.sh" ] || { echo "[错误] 组件包缺 seed-profile.sh" >&2; exit 1; }

# ---------- 4. 系统浏览器 ----------
# 界面是 Electron 壳；MCP / 需要浏览器的插件仍用系统浏览器。这里只探测，不携带
# 也不升级浏览器 deb（离线分发不再包含浏览器载荷）。
echo "[4/6] 浏览器检测 ..."

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

# ---------- 5. 桌面壳（可选） ----------
echo "[5/6] 桌面壳 ..."
DESKTOP_OK=0
TARGET_USER="${DSH_USER:-${SUDO_USER:-}}"
TARGET_HOME=""
[ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ] && TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
if [ "${DSH_DESKTOP:-1}" != "0" ] && [ -d "$PAYLOAD/desktop/app" ]; then
  ELECTRON_ZIP="$(ls "$PAYLOAD"/desktop/electron-v*-linux-x64.zip 2>/dev/null | head -1)"
  if [ -n "$ELECTRON_ZIP" ]; then
    rm -rf "$ELECTRON_DIR"; mkdir -p "$ELECTRON_DIR"
    unzip -q -o "$ELECTRON_ZIP" -d "$ELECTRON_DIR"
    [ -f "$ELECTRON_DIR/electron" ] && chmod 755 "$ELECTRON_DIR/electron"
    cp -r "$PAYLOAD/desktop/app" "$ELECTRON_DIR/app"
    chown -R "${TARGET_USER:-root}":"$(id -gn "${TARGET_USER:-root}" 2>/dev/null || echo root)" "$ELECTRON_DIR" 2>/dev/null || true
    chmod -R a+rX "$ELECTRON_DIR" 2>/dev/null || true
    chmod 755 "$ELECTRON_DIR/electron" 2>/dev/null || true
    cat > "$DEST/desktop.sh" <<DESKTOP_LAUNCH
#!/bin/bash
# DeepSeek Harness 桌面壳启动器：主窗口 + 托盘常驻；Web 服务由壳接管（退出即结束）。
export DISPLAY="\${DISPLAY:-:0}"
export DSH_DEST="$DEST"
export DSH_HOME="\${DSH_HOME:-\$HOME/.dsh}"
exec "$ELECTRON_DIR/electron" --no-sandbox "$ELECTRON_DIR/app" "\$@"
DESKTOP_LAUNCH
    chmod 755 "$DEST/desktop.sh"
    if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ] && [ -n "$TARGET_HOME" ]; then
      APPS_DIR="$TARGET_HOME/.local/share/applications"
      TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")"
      install -d -m 755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$APPS_DIR" 2>/dev/null || true
      cat > "$APPS_DIR/dsh-desktop.desktop" <<DESKTOP_ENTRY
[Desktop Entry]
Type=Application
Name=DeepSeek Harness
Comment=DeepSeek Harness 桌面客户端（托盘常驻，退出即停止服务）
Exec=$DEST/desktop.sh
Icon=$ELECTRON_DIR/app/icon.png
Terminal=false
Categories=Development;
StartupNotify=true
DESKTOP_ENTRY
      chown "$TARGET_USER":"$TARGET_GROUP" "$APPS_DIR/dsh-desktop.desktop" 2>/dev/null || true
      chmod 644 "$APPS_DIR/dsh-desktop.desktop"
      DESKTOP_PATH=""
      if command -v xdg-user-dir >/dev/null 2>&1; then
        DESKTOP_PATH="$(sudo -u "$TARGET_USER" -H xdg-user-dir DESKTOP 2>/dev/null || true)"
      fi
      [ -n "$DESKTOP_PATH" ] || DESKTOP_PATH="$TARGET_HOME/Desktop"
      if [ -d "$DESKTOP_PATH" ]; then
        cp "$APPS_DIR/dsh-desktop.desktop" "$DESKTOP_PATH/dsh-desktop.desktop"
        chown "$TARGET_USER":"$TARGET_GROUP" "$DESKTOP_PATH/dsh-desktop.desktop" 2>/dev/null || true
        chmod 755 "$DESKTOP_PATH/dsh-desktop.desktop"
        command -v gio >/dev/null 2>&1 && sudo -u "$TARGET_USER" -H gio set "$DESKTOP_PATH/dsh-desktop.desktop" metadata::trusted true 2>/dev/null || true
      fi
      command -v update-desktop-database >/dev/null 2>&1 && sudo -u "$TARGET_USER" -H update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
      echo "      应用入口: $APPS_DIR/dsh-desktop.desktop"
    fi
    DESKTOP_OK=1
    echo "      桌面壳: $DEST/desktop.sh"
  fi
elif [ "${DSH_DESKTOP:-1}" = "0" ]; then
  echo "      已跳过（DSH_DESKTOP=0）"
else
  echo "      [提示] 组件包内没有 desktop 载荷，跳过桌面壳"
fi

# ---------- 6. 启动脚本 / 卸载 / 版本 ----------
echo "[6/6] 生成启动脚本与版本标记 ..."
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
export UNIVER_NODE_BINARY="\${UNIVER_NODE_BINARY:-$NODE_GLIBC}"
export DSH_NODE_GLIBC="\${DSH_NODE_GLIBC:-$NODE_GLIBC}"
if [ -n "\${DSH_CHROME_PATH:-}" ]; then echo "  拉起用浏览器: \$DSH_CHROME_PATH"; fi
if [ -x "$NODE_GLIBC" ]; then
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

VERSION="$(cat "$PAYLOAD/VERSION" 2>/dev/null || echo unknown)"
[ "$VERSION" = "unknown" ] && VERSION="$("$NODE_BIN" -p "require('$META').version" 2>/dev/null || echo unknown)"
DSH_VER="$("$INSTALL_NODE_DIR/bin/node" -p "require('$DEST/app/node_modules/@deepseek-ai/dsh/package.json').version" 2>/dev/null || echo unknown)"
cat > "$DEST/.installed-version" <<VERSIONFILE
{
  "version": "$VERSION",
  "dshVersion": "$DSH_VER",
  "installedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "mode": "$([ "$UPGRADE" = "1" ] && echo upgrade || echo fresh)"
}
VERSIONFILE

UPDATE_URL_EFFECTIVE="${DSH_UPDATE_URL:-$DEFAULT_UPDATE_URL}"
if [ -n "${DSH_UPDATE_URL:-}" ]; then
  printf '{\n  "manifestUrl": "%s"\n}\n' "$DSH_UPDATE_URL" > "$DEST/update.json"
elif [ ! -f "$DEST/update.json" ] || ! grep -q '"manifestUrl"[[:space:]]*:[[:space:]]*"[^"]' "$DEST/update.json" 2>/dev/null; then
  printf '{\n  "manifestUrl": "%s"\n}\n' "$DEFAULT_UPDATE_URL" > "$DEST/update.json"
fi

# 单独安装本体（不经 installer）时也要把 profile 播种好；installer 会设
# DSH_SKIP_SEED=1，在全部组件装完后统一播种一次。
if [ "${DSH_SKIP_SEED:-0}" != "1" ] && [ -f "$DEST/seed-profile.sh" ]; then
  if [ "$(id -u)" = "0" ] && [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ] && [ -n "$TARGET_HOME" ] && [ -d "$TARGET_HOME" ]; then
    install -d -m 700 -o "$TARGET_USER" "$TARGET_HOME/.dsh" 2>/dev/null || true
    sudo -u "$TARGET_USER" -H env DSH_HOME="$TARGET_HOME/.dsh" SEED_NODE="$INSTALL_NODE_DIR/bin/node" \
      bash "$DEST/seed-profile.sh" "$DEST" || echo "      [警告] profile 播种失败"
  else
    SEED_NODE="$INSTALL_NODE_DIR/bin/node" bash "$DEST/seed-profile.sh" "$DEST" \
      || echo "      [警告] profile 播种失败（请以桌面用户身份手动重跑 seed-profile.sh）"
  fi
fi

echo
echo "============================================"
echo "  本体安装完成"
echo "  版本:      $VERSION（dsh $DSH_VER）"
echo "  启动 Web:  $DEST/start-web.sh"
echo "  组件管理:  sudo $DEST/installer.sh status"
if [ "${DESKTOP_OK:-0}" = "1" ]; then echo "  桌面客户端: $DEST/desktop.sh"; fi
echo "  更新源:    $UPDATE_URL_EFFECTIVE"
echo "============================================"
