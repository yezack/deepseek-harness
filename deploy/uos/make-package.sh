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
# 绝对模式：来源文件可能是 711（SFTP 上传的产物），chmod +x 不会补读位。
chmod 755 "$PKG/install.sh" "$PKG/seed-profile.sh"

echo "=== 2. 压缩 node ==="
cd "$BUILD"
zip -qr "$PKG/node.zip" node

echo "=== 3. 压缩 app（约 1.4GB，稍慢）==="
zip -qr "$PKG/app.zip" app

echo "=== 4. 打成单一分发包 ==="
cd "$BUILD"
rm -f dsh-uos-offline.tar.gz
tar czf dsh-uos-offline.tar.gz -C "$BUILD" package

echo "=== 5. 结果 ==="
ls -lh "$PKG"
ls -lh "$BUILD/dsh-uos-offline.tar.gz"
sha256sum "$BUILD/dsh-uos-offline.tar.gz"
tar tzf "$BUILD/dsh-uos-offline.tar.gz" | head -6
echo "=== 完成 $(date) ==="
