#!/bin/bash
# dsh 本体核心组件（core）：app 依赖树 + Node 运行时 + 原生模块白名单。
#
# 组件包结构（tar.gz）：
#   package/component.json      组件元数据（name/version/dshVersion）
#   package/install.sh          本脚本
#   package/payload/app/        dsh 与全部官方依赖（node_modules）
#   package/payload/node/       Node 运行时
#
# 装到 $DSH_DEST/app、$DSH_DEST/node，并把 Node 复制到 DSH_NODE_DIR（白名单目录）。
# 脚本 / 桌面壳 / 兼容运行时分别在 scripts、shell、tools 组件里。
#
# 用法： ./install.sh --component <组件包.tar.gz> [--upgrade]
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${DSH_DEST:-/deepseek-harness}"
INSTALL_NODE_DIR="${DSH_NODE_DIR:-/var/tmp/dsh-node}"

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

STAGE="$DEST/.install-stage-core"
rm -rf "$STAGE"; mkdir -p "$STAGE"
trap 'rm -rf "$STAGE"' EXIT

echo "== 安装核心组件（app + node）=="
echo "   安装位置: $DEST"
echo "   组件包:   $COMPONENT"
echo "   解包（约 1.7GB，请稍候）..."
tar xzf "$COMPONENT" -C "$STAGE" --strip-components=1 package/payload 2>/dev/null || {
  echo "[错误] 组件包结构异常：缺 package/payload" >&2; exit 1; }
PAYLOAD="$STAGE/payload"
[ -d "$PAYLOAD/app/node_modules" ] || { echo "[错误] payload 里没有 app/node_modules" >&2; exit 1; }
[ -x "$PAYLOAD/node/bin/node" ] || { echo "[错误] payload 里没有 node/bin/node" >&2; exit 1; }

# ---------- 1. 本体依赖树 ----------
echo "[1/3] 安装 app/ ..."
rm -rf "$DEST/app"
mv "$PAYLOAD/app" "$DEST/app"

# ---------- 2. Node 运行时 ----------
echo "[2/3] 安装 Node 运行时 ..."
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

# ---------- 3. 版本标记 ----------
echo "[3/3] 写版本标记 ..."
VERSION="$(cat "$PAYLOAD/VERSION" 2>/dev/null || echo unknown)"
DSH_VER="$("$INSTALL_NODE_DIR/bin/node" -p "require('$DEST/app/node_modules/@deepseek-ai/dsh/package.json').version" 2>/dev/null || echo unknown)"
cat > "$DEST/.installed-version" <<VERSIONFILE
{
  "version": "$VERSION",
  "dshVersion": "$DSH_VER",
  "installedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "mode": "$([ "$UPGRADE" = "1" ] && echo upgrade || echo fresh)"
}
VERSIONFILE

echo
echo "============================================"
echo "  核心组件安装完成"
echo "  版本:      $VERSION（dsh $DSH_VER）"
echo "  启动 Web:  $DEST/start-web.sh（由 scripts 组件生成）"
echo "============================================"
