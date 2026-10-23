#!/bin/bash
# UOS 侧：把已物化的 app 与 node 打成离线安装包
# 用法: ./make-package.sh <build-dir>
#   build-dir 需含: app/  node/  install.sh  README.txt
set -e
BUILD="${1:-/home/uos/uosbuild}"
PKG="$BUILD/package"
VER_FILE="$BUILD/app/node_modules/@deepseek-ai/dsh/package.json"

[ -d "$BUILD/app/node_modules" ] || { echo "[错误] $BUILD/app/node_modules 不存在"; exit 1; }
[ -x "$BUILD/node/bin/node" ] || { echo "[错误] $BUILD/node/bin/node 不存在"; exit 1; }

DSH_VER=$(python3 -c "import json;print(json.load(open('$VER_FILE'))['version'])" 2>/dev/null || echo "?")
NODE_VER=$("$BUILD/node/bin/node" -v 2>/dev/null || echo "?")
echo "=== 打包 dsh $DSH_VER / node $NODE_VER ==="

echo "=== 1. 准备 package 目录 ==="
rm -rf "$PKG"; mkdir -p "$PKG"
cp "$BUILD/install.sh" "$PKG/install.sh"
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

echo "=== 2. 压缩 node ==="
cd "$BUILD"
zip -qr "$PKG/node.zip" node

# 版本号：默认用 UTC 构建时刻（单调、可读）。需要固定值时用 DSH_BUILD_VERSION 覆盖。
PKG_VERSION="${DSH_BUILD_VERSION:-$(date -u +%Y%m%d.%H%M)}"
printf '%s\n' "$PKG_VERSION" > "$PKG/VERSION"
echo "  版本: $PKG_VERSION"

echo "=== 3. 压缩 app（约 1.4GB，稍慢）==="
zip -qr "$PKG/app.zip" app

echo "=== 4. 打成单一分发包 ==="
cd "$BUILD"
rm -f dsh-uos-offline.tar.gz
tar czf dsh-uos-offline.tar.gz -C "$BUILD" package

# 升级清单：内网静态服务器上放 latest.json + 包本体。url 用相对名，
# 客户端按 manifest 的 URL 解析（换服务器不用改包）。
DSH_VER="$("$BUILD/node/bin/node" -p "require('$BUILD/app/node_modules/@deepseek-ai/dsh/package.json').version" 2>/dev/null || echo unknown)"
PKG_SHA="$(sha256sum "$BUILD/dsh-uos-offline.tar.gz" | cut -d' ' -f1)"
PKG_SIZE="$(stat -c%s "$BUILD/dsh-uos-offline.tar.gz")"
# minVersion：低于它的客户端会被判定为"强制更新"（不启动 DSH，只显示强制更新窗口）。
# 留空 = 本包不强制任何版本；发布时可用 DSH_MIN_VERSION 指定（通常写"上一个版本"）。
PKG_MIN_VERSION="${DSH_MIN_VERSION:-}"
cat > "$BUILD/latest.json" <<JSON
{
  "version": "$PKG_VERSION",
  "dshVersion": "$DSH_VER",
  "sha256": "$PKG_SHA",
  "size": $PKG_SIZE,
  "url": "dsh-uos-offline.tar.gz",
  "publishedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "minVersion": "$PKG_MIN_VERSION",
  "notes": ""
}
JSON

echo "=== 5. 结果 ==="
ls -lh "$PKG"
ls -lh "$BUILD/dsh-uos-offline.tar.gz"
sha256sum "$BUILD/dsh-uos-offline.tar.gz"
cat "$BUILD/latest.json"
tar tzf "$BUILD/dsh-uos-offline.tar.gz" | head -8
echo "=== 完成 $(date) ==="
