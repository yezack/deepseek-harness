#!/bin/bash
# UOS 侧：把已物化的两棵依赖树打成离线安装包
#
#   本体树 $BUILD/app          -> package/body.zip   -> dsh-uos-body-<ver>.tar.gz
#   插件树 $BUILD/plugins-app  -> package/plugins.zip -> dsh-uos-plugins-<ver>.tar.gz
#   整包 dsh-uos-offline.tar.gz = 两者内容（新机器一次装完）
#
# 三个 tar.gz 都解出 package/ 前缀，桌面壳按清单里的 units 分别下载安装：
#   body    单元：install.sh --upgrade        （不碰 $DEST/plugins）
#   plugins 单元：install-plugins.sh --upgrade（不碰本体）
# latest.json 同时保留旧字段（version/url/sha256/size），老客户端仍按整包升级。
#
# 用法: ./make-package.sh [build-dir]
#   build-dir 需含: app/  plugins-app/  node/  install.sh  install-plugins.sh
#                   seed-profile.sh  README.txt
set -e
BUILD="${1:-$(cd "$(dirname "$0")" && pwd)}"
PKG="$BUILD/package"
APP="$BUILD/app"
PLUGINS_APP="$BUILD/plugins-app"
VER_FILE="$APP/node_modules/@deepseek-ai/dsh/package.json"

[ -d "$APP/node_modules" ] || { echo "[错误] $APP/node_modules 不存在"; exit 1; }
[ -d "$PLUGINS_APP/node_modules" ] || { echo "[错误] $PLUGINS_APP/node_modules 不存在"; exit 1; }
[ -x "$BUILD/node/bin/node" ] || { echo "[错误] $BUILD/node/bin/node 不存在"; exit 1; }

DSH_VER=$(python3 -c "import json;print(json.load(open('$VER_FILE'))['version'])" 2>/dev/null || echo "?")
NODE_VER=$("$BUILD/node/bin/node" -v 2>/dev/null || echo "?")
# 版本号：默认用 UTC 构建时刻（单调、可读）；需要固定值时用环境变量覆盖。
# 只改插件、不动本体时，用 DSH_PLUGINS_VERSION 指定新插件版本、DSH_BUILD_VERSION 保持旧值。
PKG_VERSION="${DSH_BUILD_VERSION:-$(date -u +%Y%m%d.%H%M)}"
PLUGINS_VERSION="${DSH_PLUGINS_VERSION:-$PKG_VERSION}"
echo "=== 打包 dsh $DSH_VER / node $NODE_VER ==="
echo "  本体版本: $PKG_VERSION"
echo "  插件版本: $PLUGINS_VERSION"

echo "=== 1. 准备 package 目录 ==="
# SKIP_ZIP=1 只改脚本、载荷未变时复用上一轮的 zip：先把它们挪出来，重建目录再放回。
KEEP_ZIPS=""
if [ "${SKIP_ZIP:-0}" = "1" ] && [ -f "$PKG/node.zip" ] && [ -f "$PKG/body.zip" ] && [ -f "$PKG/plugins.zip" ]; then
  KEEP_ZIPS="$(mktemp -d)"
  mv "$PKG/node.zip" "$PKG/body.zip" "$PKG/plugins.zip" "$KEEP_ZIPS/"
fi
rm -rf "$PKG"; mkdir -p "$PKG"
if [ -n "$KEEP_ZIPS" ]; then
  mv "$KEEP_ZIPS"/node.zip "$KEEP_ZIPS"/body.zip "$KEEP_ZIPS"/plugins.zip "$PKG/"
  rmdir "$KEEP_ZIPS"
fi
cp "$BUILD/install.sh" "$PKG/install.sh"
[ -f "$BUILD/install-plugins.sh" ] && cp "$BUILD/install-plugins.sh" "$PKG/install-plugins.sh"
cp "$BUILD/README.txt" "$PKG/README.txt"
[ -f "$BUILD/seed-profile.sh" ] || { echo "[错误] $BUILD/seed-profile.sh 不存在"; exit 1; }
cp "$BUILD/seed-profile.sh" "$PKG/seed-profile.sh"
[ -f "$BUILD/enable-lan.sh" ] && cp "$BUILD/enable-lan.sh" "$PKG/enable-lan.sh"
# 运维与自检脚本
for tool in doctor.sh collect-logs.sh maintain-profile.mjs preflight.sh; do
  [ -f "$BUILD/$tool" ] && cp "$BUILD/$tool" "$PKG/$tool"
done
# 内置工具：pnpm 的 npm 包 + 新 glibc 兼容运行时（B2 / 项目级 glibc）
if [ -d "$BUILD/tools" ] && ls "$BUILD"/tools/*.tgz "$BUILD"/tools/*.tar.gz >/dev/null 2>&1; then
  mkdir -p "$PKG/tools"
  cp "$BUILD"/tools/*.tgz "$BUILD"/tools/*.tar.gz "$PKG/tools/" 2>/dev/null || true
  echo "  携带工具: $(ls "$BUILD"/tools/*.tgz "$BUILD"/tools/*.tar.gz 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
fi
# 绝对模式：来源文件可能是 711 / 600（SFTP 上传的产物），chmod +x 不会补读位。
chmod 755 "$PKG/install.sh" "$PKG/seed-profile.sh"
[ -f "$PKG/install-plugins.sh" ] && chmod 755 "$PKG/install-plugins.sh"
[ -f "$PKG/enable-lan.sh" ] && chmod 755 "$PKG/enable-lan.sh"
for tool in doctor.sh collect-logs.sh preflight.sh; do
  [ -f "$PKG/$tool" ] && chmod 755 "$PKG/$tool"
done
[ -f "$PKG/maintain-profile.mjs" ] && chmod 644 "$PKG/maintain-profile.mjs"
chmod 644 "$PKG/README.txt"

# 可选：桌面壳载荷（Electron 运行时 + 壳应用）。窗口/托盘接管服务进程，不碰 Web 侧。
if [ -d "$BUILD/desktop" ]; then
  mkdir -p "$PKG/desktop"
  [ -d "$BUILD/desktop/app" ] && cp -r "$BUILD/desktop/app" "$PKG/desktop/"
  ELECTRON_ZIP="$(ls "$BUILD"/desktop/electron-v*-linux-x64.zip 2>/dev/null | head -1)"
  if [ -n "$ELECTRON_ZIP" ]; then
    cp "$ELECTRON_ZIP" "$PKG/desktop/"
    echo "  携带桌面壳: $(basename "$ELECTRON_ZIP") ($(du -h "$ELECTRON_ZIP" | cut -f1))"
  fi
fi

# 可选：随包携带系统浏览器升级包。把 deb 放在 build-dir/browser/ 下即会被打包；
# install.sh 只在目标机已装同一浏览器且版本更低时询问是否升级。
# deb 来源： apt-get download org.deepin.browser   （UOS 官方仓库）
if [ -d "$BUILD/browser" ] && ls "$BUILD/browser"/*.deb >/dev/null 2>&1; then
  mkdir -p "$PKG/browser"
  cp "$BUILD/browser"/*.deb "$PKG/browser/"
  echo "  携带浏览器升级包: $(ls "$BUILD/browser"/*.deb | xargs -n1 basename | tr '\n' ' ')"
fi

printf '%s\n' "$PKG_VERSION" > "$PKG/VERSION"
printf '%s\n' "$PKG_VERSION" > "$PKG/VERSION-BODY"
printf '%s\n' "$PLUGINS_VERSION" > "$PKG/VERSION-PLUGINS"

echo "=== 2. 压缩 node ==="
cd "$BUILD"
# SKIP_ZIP=1 时复用 package/ 里已有的 zip（只改了脚本、载荷未变时用，省一次全量压缩）。
if [ "${SKIP_ZIP:-0}" = "1" ] && [ -f "$PKG/node.zip" ] && [ -f "$PKG/body.zip" ] && [ -f "$PKG/plugins.zip" ]; then
  echo "  SKIP_ZIP=1：复用已有 node.zip / body.zip / plugins.zip"
else
  zip -qr "$PKG/node.zip" node
  echo "=== 3. 压缩本体树 ==="
  zip -qr "$PKG/body.zip" app
  echo "=== 4. 压缩插件树 ==="
  zip -qr "$PKG/plugins.zip" plugins-app
fi

echo "=== 5. 打成三个分发包 ==="
cd "$BUILD"
rm -f dsh-uos-offline.tar.gz dsh-uos-body-*.tar.gz dsh-uos-plugins-*.tar.gz

# 整包：新机器一次装完（本体 + 插件 + 全部脚本与工具）
tar czf dsh-uos-offline.tar.gz -C "$BUILD" package

# 本体升级包：只含本体载荷；install.sh --upgrade 不碰 $DEST/plugins
BODY_FILES=(install.sh install-plugins.sh seed-profile.sh maintain-profile.mjs README.txt
            VERSION VERSION-BODY node.zip body.zip)
[ -f "$PKG/enable-lan.sh" ] && BODY_FILES+=(enable-lan.sh)
[ -f "$PKG/doctor.sh" ] && BODY_FILES+=(doctor.sh)
[ -f "$PKG/collect-logs.sh" ] && BODY_FILES+=(collect-logs.sh)
for optional in tools desktop browser; do
  [ -d "$PKG/$optional" ] && BODY_FILES+=("$optional")
done
# 单元包和整包一样必须解出 package/ 前缀（桌面壳按 package/install.sh 找入口），
# 用 tar 的 --transform 加前缀，避免额外复制一份几百 MB 的载荷。
tar czf "dsh-uos-body-$PKG_VERSION.tar.gz" -C "$PKG" --transform 's,^,package/,' "${BODY_FILES[@]}"

# 插件升级包：只含插件载荷 + 播种所需脚本（install-plugins.sh 会调用 install.sh --seed-only）
PLUGIN_FILES=(install.sh install-plugins.sh seed-profile.sh maintain-profile.mjs README.txt
              VERSION VERSION-PLUGINS plugins.zip)
tar czf "dsh-uos-plugins-$PLUGINS_VERSION.tar.gz" -C "$PKG" --transform 's,^,package/,' "${PLUGIN_FILES[@]}"

# 升级清单：内网静态服务器上放 latest.json + 三个包。url 用相对名，
# 客户端按 manifest 的 URL 解析（换服务器不用改包）。
sha_of() { sha256sum "$1" | cut -d' ' -f1; }
size_of() { stat -c%s "$1"; }
FULL_SHA="$(sha_of "$BUILD/dsh-uos-offline.tar.gz")"
FULL_SIZE="$(size_of "$BUILD/dsh-uos-offline.tar.gz")"
BODY_SHA="$(sha_of "$BUILD/dsh-uos-body-$PKG_VERSION.tar.gz")"
BODY_SIZE="$(size_of "$BUILD/dsh-uos-body-$PKG_VERSION.tar.gz")"
PLUG_SHA="$(sha_of "$BUILD/dsh-uos-plugins-$PLUGINS_VERSION.tar.gz")"
PLUG_SIZE="$(size_of "$BUILD/dsh-uos-plugins-$PLUGINS_VERSION.tar.gz")"
# minVersion：低于它的客户端会被判定为"强制更新"（不启动 DSH，只显示强制更新窗口）。
# 留空 = 该单元不强制任何版本；发布时可用 DSH_MIN_VERSION / DSH_PLUGINS_MIN_VERSION 指定。
PKG_MIN_VERSION="${DSH_MIN_VERSION:-}"
PLUG_MIN_VERSION="${DSH_PLUGINS_MIN_VERSION:-}"
cat > "$BUILD/latest.json" <<JSON
{
  "version": "$PKG_VERSION",
  "dshVersion": "$DSH_VER",
  "sha256": "$FULL_SHA",
  "size": $FULL_SIZE,
  "url": "dsh-uos-offline.tar.gz",
  "publishedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "minVersion": "$PKG_MIN_VERSION",
  "notes": "",
  "units": {
    "body": {
      "version": "$PKG_VERSION",
      "sha256": "$BODY_SHA",
      "size": $BODY_SIZE,
      "url": "dsh-uos-body-$PKG_VERSION.tar.gz",
      "minVersion": "$PKG_MIN_VERSION"
    },
    "plugins": {
      "version": "$PLUGINS_VERSION",
      "sha256": "$PLUG_SHA",
      "size": $PLUG_SIZE,
      "url": "dsh-uos-plugins-$PLUGINS_VERSION.tar.gz",
      "minVersion": "$PLUG_MIN_VERSION"
    }
  }
}
JSON

echo "=== 6. 结果 ==="
ls -lh "$PKG" | head -20
echo "--- 分发件 ---"
ls -lh "$BUILD"/dsh-uos-*.tar.gz
cat "$BUILD/latest.json"
echo "--- 整包结构 ---"
tar tzf "$BUILD/dsh-uos-offline.tar.gz" | head -8
echo "=== 完成 $(date) ==="
