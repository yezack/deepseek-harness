#!/bin/bash
# UOS 侧：从本地 tarball + 索引物化 DSH 应用依赖树
# 用法: ./materialize-uos.sh <build-dir> <app-dir>
#   build-dir 需含: tarballs/npm/  tarballs/npm-vendor/  tarball-index.json
set -e
BUILD="${1:-/home/uos/uosbuild}"
APP="${2:-$BUILD/app}"
TARBALLS="$BUILD/tarballs"
INDEX="$BUILD/tarball-index.json"
# Third-party bundles and the MCP server the offline image preinstalls. Their
# versions resolve from the registry here, at build time, and the installed tree
# is frozen into app.zip, so the installed host needs no registry.
EXTRAS="${EXTRAS:-$BUILD/extras.json}"

NODE_DIR=/var/tmp/node22          # UOS 白名单路径，node 必须在此执行
export PATH="$NODE_DIR/bin:$PATH"
NODE="$NODE_DIR/bin/node"
# npm 的 shim 是 `#!/usr/bin/env node`，在 PATH 不完整时会报 env: node not found；
# 直接用 node 调 npm 的 CLI 入口，避免依赖 shebang 解析。
NPM="$NODE_DIR/lib/node_modules/npm/bin/npm-cli.js"
export NARB_NATIVE_CACHE_DIR=/var/tmp/dsh-native-cache
mkdir -p "$NARB_NATIVE_CACHE_DIR"

echo "=== 0. 环境 ==="
"$NODE" -v
ls -l "$INDEX" >/dev/null || { echo "[错误] 缺少索引 $INDEX"; exit 1; }

echo "=== 1. 按索引生成 consumer package.json ==="
rm -rf "$APP"; mkdir -p "$APP"
"$NODE" - "$TARBALLS" "$INDEX" "$APP" "$EXTRAS" "$BUILD" <<'JSEOF'
const fs = require('fs'), path = require('path');
const [tarballs, indexFile, app, extrasFile, bundleDir] = process.argv.slice(2);
const idx = JSON.parse(fs.readFileSync(indexFile, 'utf8'));
const deps = {};
let miss = [];
for (const e of idx) {
  const f = path.join(tarballs, e.file);
  if (!fs.existsSync(f)) { miss.push(e.file); continue; }
  deps[e.name] = 'file:' + f;
}
let extras = [];
if (extrasFile && fs.existsSync(extrasFile)) extras = JSON.parse(fs.readFileSync(extrasFile, 'utf8'));
for (const e of extras) {
  // 带 spec 的条目从构建目录里的 tarball 安装。@yezack/chrome-devtools-mcp-108 是
  // 本地 fork，公共 registry 上没有，所以必须走这条路径 —— 对离线包来说也更稳，
  // 装进去的就是验证过的那一份字节。相对路径按构建目录解析，npm 只认绝对路径。
  if (e.spec) {
    const rel = e.spec.replace(/^file:/, '');
    deps[e.name] = 'file:' + path.resolve(bundleDir, rel);
    continue;
  }
  // 索引里已有同名依赖时保留索引里的版本：node_modules 只能有一份，而后者的
  // 消费者（例如 dsh 自带的 browser-use 包）对版本有要求。
  if (!deps[e.name]) deps[e.name] = e.version;
}
fs.writeFileSync(path.join(app, 'package.json'), JSON.stringify({
  name: 'dsh-uos-offline-app', version: '0.0.0', private: true, dependencies: deps
}, null, 2));
console.log('  索引条目:', idx.length, ' 第三方:', extras.length,
  ' 生成依赖:', Object.keys(deps).length, ' 缺失:', miss.length);
if (miss.length) console.log('  缺失样例:', miss.slice(0, 5));
JSEOF

echo "=== 2. npm install ==="
echo "  --legacy-peer-deps  : 绕过 npm/arborist 的 edgesOut 崩溃"
echo "  --ignore-scripts    : 跳过 koffi 源码编译（改用预编译包）"
# 走镜像：直连 registry.npmjs.org 在这台构建机上会读超时/ECONNRESET（dshmarket
# 就是这么失败的），镜像覆盖全部传递依赖。可用 NPM_REGISTRY 覆盖。
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"
echo "  registry            : $NPM_REGISTRY"
cd "$APP"
"$NODE" "$NPM" install --no-audit --no-fund --legacy-peer-deps --ignore-scripts \
  --registry "$NPM_REGISTRY" --loglevel=warn 2>&1 | tail -15
echo "  npm 退出码=${PIPESTATUS[0]}"

echo "=== 3. koffi 官方预编译包 ==="
KOFFI_VER=$("$NODE" -e "try{console.log(require('$APP/node_modules/koffi/package.json').version)}catch(e){console.log('')}" 2>/dev/null)
echo "  koffi 版本: ${KOFFI_VER:-未安装}"
if [ -n "$KOFFI_VER" ]; then
  ( cd "$APP" && "$NODE" "$NPM" install --no-audit --no-fund --no-save --force --ignore-scripts \
      --registry "$NPM_REGISTRY" \
      "@koromix/koffi-linux-x64@$KOFFI_VER" 2>&1 | tail -4 ) || true
fi
ls -la "$APP/node_modules/@koromix/koffi-linux-x64/linux_x64/" 2>/dev/null || echo "  ⚠️ @koromix 未安装"

echo "=== 4. 隐藏 dsh-remote-mobile 的 Tailscale 入口 ==="
# 目标环境是隔离局域网，没有 Tailscale，留着那个入口会误导操作员。插件没有隐藏
# 开关，所以改它打包好的客户端代码；脚本在锚点漂移时直接失败，不会静默跳过。
"$NODE" "$BUILD/patch-remote-mobile.mjs" "$APP"

echo "=== 5. 验证 ==="
"$NODE" "$APP/node_modules/@deepseek-ai/dsh/lib/bin.js" --version 2>&1 | head -3
"$NODE" -e "const k=require('$APP/node_modules/koffi'); console.log('KOFFI_OK', typeof k.load)" 2>&1 | head -2
du -sh "$APP/node_modules" 2>/dev/null
echo "=== 完成 $(date) ==="
