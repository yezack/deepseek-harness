#!/bin/bash
# DeepSeek Harness - UOS 插件单元安装/升级
#
# 插件与本体是两个独立的发布单元、两个目录：
#
#   $DSH_DEST/app/                本体（dsh 全部官方包 + Node 运行时）
#   $DSH_DEST/plugins/app/        插件（第三方插件 + 它们自己的第三方依赖）
#   $DSH_DEST/plugins/.installed-version
#
# 升级插件不重装本体（省掉 ~600MB 下载与解压），升级本体也不动插件。
# profile（~/.dsh/profiles/web）里只放指向 $DSH_DEST/plugins/app/node_modules 的
# 逐包软链，由 seed-profile.sh 维护；插件对宿主包的依赖走 dsh 的 profile 解析：
# 声明的 peer 由运行时解析表提供，未声明但物理存在的由插件树里 @deepseek-ai
# 软链兜底，两者都指回本体那一份，因此始终是单实例。
#
# 用法: sudo ./install-plugins.sh [--upgrade]
#   --upgrade  原地替换插件树（保留 profile 里的用户配置，只同步版本）
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${DSH_DEST:-/deepseek-harness}"
PLUGINS_DIR="$DEST/plugins"
STAGING="$DEST/.plugins-new"
BACKUP="$DEST/plugins.bak"
INSTALL_NODE_DIR="${DSH_NODE_DIR:-/var/tmp/dsh-node}"

UPGRADE=0
for arg in "$@"; do
  case "$arg" in
    --upgrade) UPGRADE=1 ;;
    --help|-h)
      echo "用法: sudo ./install-plugins.sh [--upgrade]"
      exit 0 ;;
  esac
done

echo "============================================"
echo "  DeepSeek Harness - 插件安装"
echo "  插件目录: $PLUGINS_DIR"
echo "============================================"

if [ "$(id -u)" != "0" ]; then
  echo "  提示: 当前非 root。$DEST 需要写权限，请用 root 运行： sudo ./install-plugins.sh"
  echo
fi

# 本体必须在：插件的宿主包全部链接到本体那一份。
if [ ! -f "$DEST/app/node_modules/@deepseek-ai/dsh/package.json" ]; then
  echo "[错误] 本体未安装或不是新布局（缺 $DEST/app/node_modules/@deepseek-ai/dsh）"
  echo "       请先安装本体（install.sh），或确认 DSH_DEST=$DEST 指向正确位置"
  exit 1
fi

NODE_BIN="$INSTALL_NODE_DIR/bin/node"
[ -x "$NODE_BIN" ] || NODE_BIN="$DEST/node/bin/node"
if [ ! -x "$NODE_BIN" ]; then
  echo "[错误] 找不到 node（$INSTALL_NODE_DIR/bin/node 或 $DEST/node/bin/node）"
  exit 1
fi

# 载荷：包根目录的 plugins.zip（make-package.sh 的产物），兼容 plugins/ 子目录，
# 以及构建机上已解开的 plugins-app 目录。
ZIP="$HERE/plugins.zip"
[ -f "$ZIP" ] || ZIP="$HERE/plugins/plugins.zip"
if [ ! -f "$ZIP" ] && [ ! -d "$HERE/plugins-app" ]; then
  echo "[错误] 找不到插件载荷（$HERE/plugins.zip 或 $HERE/plugins-app）"
  exit 1
fi

echo "[1/4] 解压插件载荷（约 650MB，请稍候）..."
rm -rf "$STAGING"
mkdir -p "$STAGING"
if [ -f "$ZIP" ]; then
  unzip -q -o "$ZIP" -d "$STAGING"
else
  cp -r "$HERE/plugins-app" "$STAGING/plugins-app"
fi
SRC="$STAGING/plugins-app"
if [ ! -d "$SRC/node_modules" ]; then
  rm -rf "$STAGING"
  echo "[错误] 插件载荷结构异常：$SRC/node_modules 不存在"
  exit 1
fi

echo "[2/4] 挂接宿主包：@deepseek-ai -> $DEST/app/node_modules/@deepseek-ai"
# 插件 import '@deepseek-ai/*' 时先在插件树里物理查找；这个软链指回本体那一份，
# 保证模块缓存里是同一个实例（两份 dsh-tools 会让 unique symbol 对不上）。
rm -rf "$SRC/node_modules/@deepseek-ai"
ln -sfn "$DEST/app/node_modules/@deepseek-ai" "$SRC/node_modules/@deepseek-ai"

# koffi 的原生 .node 必须从白名单路径加载。插件树里有 koffi 时同样处理：
# 预编译包搬到 /var/tmp，再从插件树软链过去（与 install.sh 对本体的做法一致）。
KOROMIX_SRC="$SRC/node_modules/@koromix/koffi-linux-x64"
if [ -d "$KOROMIX_SRC" ]; then
  KOROMIX_WH="/var/tmp/dsh-native-cache/koromix/koffi-linux-x64-plugins"
  mkdir -p /var/tmp/dsh-native-cache/koromix
  rm -rf "$KOROMIX_WH"
  cp -r "$KOROMIX_SRC" "$KOROMIX_WH"
  mkdir -p "$SRC/node_modules/koffi/build/koffi"
  ln -sfn "$KOROMIX_WH/linux_x64" "$SRC/node_modules/koffi/build/koffi/linux_x64"
  echo "      koffi 原生模块已链接到白名单路径"
fi

echo "[3/4] 原子替换 $PLUGINS_DIR ..."
rm -rf "$BACKUP"
if [ -d "$PLUGINS_DIR" ]; then
  mv "$PLUGINS_DIR" "$BACKUP"
fi
if ! mkdir -p "$PLUGINS_DIR" || ! mv "$SRC" "$PLUGINS_DIR/app"; then
  # 回滚：旧的插件树放回去，不留半成品。
  rm -rf "$PLUGINS_DIR"
  if [ -d "$BACKUP" ]; then mv "$BACKUP" "$PLUGINS_DIR"; fi
  rm -rf "$STAGING"
  echo "[错误] 替换插件目录失败，已回滚到升级前"
  exit 1
fi

# 版本标记：供桌面壳「检查更新」比较，也供 preflight 判断 profile 是否同步。
PKG_VER="$(cat "$HERE/VERSION-PLUGINS" 2>/dev/null || cat "$HERE/VERSION" 2>/dev/null || echo unknown)"
DSH_VER="$("$NODE_BIN" -p "require('$DEST/app/node_modules/@deepseek-ai/dsh/package.json').version" 2>/dev/null || echo unknown)"
cat > "$PLUGINS_DIR/.installed-version" <<VERSIONFILE
{
  "version": "$PKG_VER",
  "dshVersion": "$DSH_VER",
  "installedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "mode": "$([ "$UPGRADE" = "1" ] && echo upgrade || echo fresh)"
}
VERSIONFILE

# 清单自检：seed-profile.sh 的 BUNDLES 里每个插件都必须在插件树里落地，
# 少一个就说明载荷不完整——继续装下去只会让插件在启动时被静默跳过。
BUNDLES=""
if [ -f "$HERE/seed-profile.sh" ]; then
  BUNDLES="$(grep -m1 '^BUNDLES=' "$HERE/seed-profile.sh" | sed -E 's/^BUNDLES="//; s/"$//')"
fi
if [ -n "$BUNDLES" ]; then
  MISSING=""
  for item in $BUNDLES; do
    name="${item%@*}"
    if [ ! -d "$PLUGINS_DIR/app/node_modules/$name" ]; then MISSING="$MISSING $name"; fi
  done
  if [ -n "$MISSING" ]; then
    rm -rf "$PLUGINS_DIR"
    if [ -d "$BACKUP" ]; then mv "$BACKUP" "$PLUGINS_DIR"; fi
    rm -rf "$STAGING"
    echo "[错误] 插件载荷缺少：$MISSING（已回滚到升级前）"
    exit 1
  fi
fi

rm -rf "$BACKUP" "$STAGING"

echo "[4/4] 同步 profile 软链与版本 ..."
if [ "${DSH_PLUGINS_SKIP_SEED:-0}" = "1" ]; then
  # 由 install.sh 调用时统一在安装末尾播种一次，避免重复写 profile。
  echo "      跳过（由 install.sh 统一播种）"
elif [ -f "$HERE/install.sh" ] && [ -f "$HERE/seed-profile.sh" ]; then
  bash "$HERE/install.sh" --seed-only
else
  echo "      [警告] 包里没有 install.sh/seed-profile.sh，跳过 profile 播种"
  echo "             稍后请手动执行： sudo -u <桌面用户> DSH_HOME=\$HOME/.dsh $DEST/seed-profile.sh $DEST"
fi

echo
echo "============================================"
echo "  插件安装完成"
echo "  版本:     $PKG_VER"
echo "  插件数:   $(echo "$BUNDLES" | wc -w)"
echo "  目录:     $PLUGINS_DIR"
echo "  磁盘占用: $(du -sh "$PLUGINS_DIR" 2>/dev/null | cut -f1)"
echo "============================================"
