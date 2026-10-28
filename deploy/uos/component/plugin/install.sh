#!/bin/bash
# 单个插件的独立安装脚本（每个插件包各带一份，内容相同）。
#
# 组件包结构（tar.gz）：
#   package/component.json    组件元数据（name/version/entryId/order/disabled/alwaysLast）
#   package/install.sh        本脚本
#   package/payload/plugin/   插件包目录：package.json + node_modules + 构建产物
#
# 安装位置：$DSH_DEST/plugins/<包名>/（自包含 node_modules）
# 宿主包（@deepseek-ai/*）不复制：在插件树里软链回本体那一份，保证单实例。
#
# 用法（installer 会以同样的方式调用，可单独运行）：
#   ./install.sh --component <组件包.tar.gz> [--upgrade] [--no-seed]
#   ./install.sh --component <组件包.tar.gz> --uninstall
# 环境：
#   DSH_DEST        安装根目录（默认 /deepseek-harness）
#   DSH_NODE_DIR    白名单 node 目录（默认 /var/tmp/dsh-node）
#   DSH_SKIP_SEED=1 安装后不重播 profile（由 installer 统一播种时用）
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${DSH_DEST:-/deepseek-harness}"
PLUGINS_DIR="$DEST/plugins"
INSTALL_NODE_DIR="${DSH_NODE_DIR:-/var/tmp/dsh-node}"

COMPONENT=""
UPGRADE=0
UNINSTALL=0
SEED=1
while [ $# -gt 0 ]; do
  case "$1" in
    --component) COMPONENT="${2:-}"; shift 2 ;;
    --upgrade) UPGRADE=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --no-seed) SEED=0; shift ;;
    --help|-h)
      echo "用法: ./install.sh --component <组件包.tar.gz> [--upgrade] [--no-seed|--uninstall]"
      exit 0 ;;
    *) shift ;;
  esac
done
[ -n "$COMPONENT" ] || COMPONENT="${DSH_COMPONENT_FILE:-}"
if [ -z "$COMPONENT" ] || [ ! -f "$COMPONENT" ]; then
  echo "[错误] 需要组件包： --component <tar.gz>（或环境变量 DSH_COMPONENT_FILE）" >&2
  exit 1
fi
COMPONENT="$(cd "$(dirname "$COMPONENT")" && pwd)/$(basename "$COMPONENT")"

NODE_BIN="$INSTALL_NODE_DIR/bin/node"
[ -x "$NODE_BIN" ] || NODE_BIN="$DEST/node/bin/node"
if [ ! -x "$NODE_BIN" ]; then echo "[错误] 找不到 node（$INSTALL_NODE_DIR 或 $DEST/node）" >&2; exit 1; fi
if [ ! -f "$DEST/app/node_modules/@deepseek-ai/dsh/package.json" ]; then
  echo "[错误] 本体未安装（缺 $DEST/app/node_modules/@deepseek-ai/dsh）" >&2
  echo "       先安装 dsh 本体组件，再装插件" >&2
  exit 1
fi

# 暂存放在插件根目录里：与最终位置同一文件系统，收尾用 mv 重命名，不复制几百 MB。
mkdir -p "$PLUGINS_DIR"
STAGE="$(mktemp -d "$PLUGINS_DIR/.stage-XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# 只取元数据与本脚本需要的部分，payload 由下方按需解出。
tar xzf "$COMPONENT" -C "$STAGE" package/component.json 2>/dev/null || {
  echo "[错误] 组件包结构异常：缺 package/component.json" >&2
  exit 1
}
META="$STAGE/package/component.json"
NAME="$("$NODE_BIN" -p "require('$META').name")"
VERSION="$("$NODE_BIN" -p "require('$META').version")"
DSH_WANT="$("$NODE_BIN" -p "require('$META').dshVersion || ''")"
if [ -z "$NAME" ] || [ "$NAME" = "undefined" ]; then echo "[错误] component.json 缺 name" >&2; exit 1; fi

TARGET="$PLUGINS_DIR/$NAME"

if [ "$UNINSTALL" = "1" ]; then
  echo "== 卸载插件 $NAME =="
  rm -rf "$TARGET"
  rm -f "$PLUGINS_DIR/.new-$NAME" 2>/dev/null || true
  if [ "$SEED" = "1" ] && [ -f "$DEST/seed-profile.sh" ]; then
    bash "$DEST/seed-profile.sh" "$DEST" || true
  fi
  echo "已卸载 $NAME"
  exit 0
fi

DSH_VER="$("$NODE_BIN" -p "require('$DEST/app/node_modules/@deepseek-ai/dsh/package.json').version" 2>/dev/null || echo unknown)"
echo "== 安装插件 $NAME@$VERSION（dsh $DSH_VER）=="

# 1. 解 payload 到临时目录
PAYLOAD="$STAGE/payload"
mkdir -p "$PAYLOAD"
tar xzf "$COMPONENT" -C "$PAYLOAD" --strip-components=3 package/payload/plugin 2>/dev/null || {
  echo "[错误] 组件包结构异常：缺 package/payload/plugin" >&2
  exit 1
}
if [ ! -f "$PAYLOAD/package.json" ]; then echo "[错误] payload 里没有插件包（package.json 缺失）" >&2; exit 1; fi

# 2. 组件元数据随包安装：seed-profile.sh 靠它推导 profile，不维护硬编码清单。
cp "$META" "$PAYLOAD/component.json"

# 3. 宿主包软链：插件 import '@deepseek-ai/*' 时物理命中的是本体那一份。
rm -rf "$PAYLOAD/node_modules/@deepseek-ai"
mkdir -p "$PAYLOAD/node_modules"
ln -sfn "$DEST/app/node_modules/@deepseek-ai" "$PAYLOAD/node_modules/@deepseek-ai"

# 4. koffi 的原生 .node 必须从白名单路径加载（与本体安装脚本同一处理）。
if [ -d "$PAYLOAD/node_modules/@koromix/koffi-linux-x64" ]; then
  KOROMIX_WH="/var/tmp/dsh-native-cache/koromix/koffi-linux-x64-$(echo "$NAME" | tr '/@' '__')"
  mkdir -p /var/tmp/dsh-native-cache/koromix
  rm -rf "$KOROMIX_WH"
  cp -r "$PAYLOAD/node_modules/@koromix/koffi-linux-x64" "$KOROMIX_WH"
  mkdir -p "$PAYLOAD/node_modules/koffi/build/koffi"
  ln -sfn "$KOROMIX_WH/linux_x64" "$PAYLOAD/node_modules/koffi/build/koffi/linux_x64"
  echo "   koffi 原生模块已链接到白名单路径"
fi

# 5. 原子替换插件目录
BACKUP="$PLUGINS_DIR/.bak-$(echo "$NAME" | tr '/@' '__')"
rm -rf "$BACKUP"
mkdir -p "$(dirname "$TARGET")"
if [ -d "$TARGET" ]; then mv "$TARGET" "$BACKUP"; fi
if ! mv "$PAYLOAD" "$TARGET"; then
  rm -rf "$TARGET"
  [ -d "$BACKUP" ] && mv "$BACKUP" "$TARGET"
  echo "[错误] 替换插件目录失败，已回滚" >&2
  exit 1
fi
rm -rf "$BACKUP"
rm -f "$PLUGINS_DIR/.new-$NAME" 2>/dev/null || true

cat > "$TARGET/.installed-version" <<VERSIONFILE
{
  "name": "$NAME",
  "version": "$VERSION",
  "dshVersion": "$DSH_VER",
  "installedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "mode": "$([ "$UPGRADE" = "1" ] && echo upgrade || echo fresh)"
}
VERSIONFILE

echo "   已安装到 $TARGET（$(du -sh "$TARGET" 2>/dev/null | cut -f1)）"

# 6. 重播 profile（安装/升级插件后必须让 profile 看见新组件）
if [ "$SEED" = "1" ] && [ "${DSH_SKIP_SEED:-0}" != "1" ] && [ -f "$DEST/seed-profile.sh" ]; then
  SEED_NODE="$NODE_BIN" bash "$DEST/seed-profile.sh" "$DEST"
fi
echo "== 完成 $NAME@$VERSION =="
