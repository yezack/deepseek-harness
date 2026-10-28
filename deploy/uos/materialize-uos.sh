#!/bin/bash
# UOS 侧：从本地 tarball + 索引物化两棵依赖树
#
#   $BUILD/app          本体树：dsh 全部官方包 + 其传递依赖（tarball-index.json）
#   $BUILD/plugins-app  插件树：第三方插件 + 其传递依赖（extras.json）
#
# 拆两棵树是为了让本体与插件成为**两个独立的发布单元**（目标机上分别装到
# /deepseek-harness/app 与 /deepseek-harness/plugins/app）。插件对宿主包的依赖
# 一律声明为 peerDependencies，由 dsh 的 profile 解析钩子提供正在运行的那一份
# 实例（见 .agents/notes/implemented/architecture/2026-09-19-profile-resolution-lookup-order.zh.md），
# 因此插件树里不含 @deepseek-ai/* 的副本，也不会出现两份 cordis。
#
# 例外：extras 里带 override 的条目（chrome-devtools-mcp 的 108 fork）属于本体树——
# 消费它的是 dsh 自带的 browser-use 包，按包名从本体树解析。
#
# 用法: ./materialize-uos.sh [build-dir]
#   build-dir 需含: tarballs/npm/  tarballs/npm-vendor/  tarball-index.json  extras.json
set -e
BUILD="${1:-$(cd "$(dirname "$0")" && pwd)}"
APP="$BUILD/app"
PLUGINS="$BUILD/plugins-app"
TARBALLS="$BUILD/tarballs"
INDEX="$BUILD/tarball-index.json"
# 第三方插件清单。版本在构建机上从 registry 解析，装好的树冻结进 plugins.zip，
# 目标机不需要 registry。
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
[ -f "$EXTRAS" ] || { echo "[错误] 缺少插件清单 $EXTRAS"; exit 1; }

echo "=== 1. 生成两棵树的 consumer package.json ==="
rm -rf "$APP" "$PLUGINS"; mkdir -p "$APP" "$PLUGINS"
"$NODE" - "$TARBALLS" "$INDEX" "$APP" "$PLUGINS" "$EXTRAS" "$BUILD" <<'JSEOF'
const fs = require('fs'), path = require('path');
const [tarballs, indexFile, app, pluginsDir, extrasFile, bundleDir] = process.argv.slice(2);
const idx = JSON.parse(fs.readFileSync(indexFile, 'utf8'));
const extras = JSON.parse(fs.readFileSync(extrasFile, 'utf8'));

// 带 override 的条目不是普通依赖：它把 tarball 装到**另一个包名**下，让所有按包名
// 解析的消费者都拿到它。dsh 自带的 browser-use 包用
// import.meta.resolve('chrome-devtools-mcp/...') 定位服务端，所以只有让
// node_modules/chrome-devtools-mcp 本身就变成 108 fork，那条路径才用得上修复。
// 消费方在本体树，所以 override 只进本体树。
const overridden = new Set();
const overrides = {};
for (const e of extras) {
  if (!e.override) continue;
  overridden.add(e.override);
  overrides[e.override] = 'file:' + path.resolve(bundleDir, e.spec.replace(/^file:/, ''));
}

// 本体树：索引条目。被 override 的包不能同时出现在 dependencies 里，npm 会报
// EOVERRIDE（override 与直接依赖冲突），它由 overrides 提供。
const bodyDeps = {};
const miss = [];
for (const e of idx) {
  if (overridden.has(e.name)) continue;
  const f = path.join(tarballs, e.file);
  if (!fs.existsSync(f)) { miss.push(e.file); continue; }
  bodyDeps[e.name] = 'file:' + f;
}
const bodyPkg = { name: 'dsh-uos-offline-body', version: '0.0.0', private: true, dependencies: bodyDeps };
if (Object.keys(overrides).length > 0) bodyPkg.overrides = overrides;
fs.writeFileSync(path.join(app, 'package.json'), JSON.stringify(bodyPkg, null, 2));

// 插件树：extras 里除 override 条目以外的全部插件。
const pluginDeps = {};
for (const e of extras) {
  if (e.override) continue;
  // 带 spec 的条目从构建目录里的 tarball 安装。@yezack 的本地 fork 公共 registry 上
  // 没有，必须走这条路径 —— 对离线包来说也更稳，装进去的就是验证过的那一份字节。
  // 相对路径按构建目录解析，npm 只认绝对路径。
  if (e.spec) {
    pluginDeps[e.name] = 'file:' + path.resolve(bundleDir, e.spec.replace(/^file:/, ''));
    continue;
  }
  pluginDeps[e.name] = e.version;
}
const pluginsPkg = { name: 'dsh-uos-offline-plugins', version: '0.0.0', private: true, dependencies: pluginDeps };
fs.writeFileSync(path.join(pluginsDir, 'package.json'), JSON.stringify(pluginsPkg, null, 2));

console.log('  本体: 索引条目', idx.length, ' 生成依赖', Object.keys(bodyDeps).length,
  ' override', Object.keys(overrides).length, ' 缺失', miss.length);
console.log('  插件: 清单条目', extras.length, ' 生成依赖', Object.keys(pluginDeps).length);
if (miss.length) console.log('  缺失样例:', miss.slice(0, 5));
JSEOF

echo "=== 2. npm install 本体树 ==="
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

echo "=== 3. npm install 插件树 ==="
# 插件声明的 @deepseek-ai/* 都是 peerDependencies，--legacy-peer-deps 让 npm 不装
# 它们（由宿主的 profile 解析钩子提供），插件树只带自己的第三方依赖。
cd "$PLUGINS"
"$NODE" "$NPM" install --no-audit --no-fund --legacy-peer-deps --ignore-scripts \
  --registry "$NPM_REGISTRY" --loglevel=warn 2>&1 | tail -15
echo "  npm 退出码=${PIPESTATUS[0]}"

echo "=== 4. koffi 官方预编译包（两棵树按需）==="
install_koffi() {
  local tree="$1" name="$2"
  local ver
  ver=$("$NODE" -e "try{console.log(require('$tree/node_modules/koffi/package.json').version)}catch(e){console.log('')}" 2>/dev/null)
  echo "  $name koffi 版本: ${ver:-未安装}"
  [ -n "$ver" ] || return 0
  # 它的 .node 必须从白名单路径加载：安装期再把它搬到 /var/tmp 并软链回去，
  # 这里只保证预编译包随树一起产出。
  ( cd "$tree" && "$NODE" "$NPM" install --no-audit --no-fund --no-save --force --ignore-scripts \
      --registry "$NPM_REGISTRY" \
      "@koromix/koffi-linux-x64@$ver" 2>&1 | tail -4 ) || true
  ls -la "$tree/node_modules/@koromix/koffi-linux-x64/linux_x64/" 2>/dev/null | head -3 \
    || echo "  ⚠️ $name @koromix 未安装"
}
install_koffi "$APP" 本体
install_koffi "$PLUGINS" 插件

echo "=== 5. 构建期补丁（只作用于插件树）==="
# 4a. 隐藏 dsh-remote-mobile 的 Tailscale 入口
# 目标环境是隔离局域网，没有 Tailscale，留着那个入口会误导操作员。插件没有隐藏
# 开关，所以改它打包好的客户端代码；脚本在锚点漂移时直接失败，不会静默跳过。
"$NODE" "$BUILD/patch-remote-mobile.mjs" "$PLUGINS"

# 4b. dsh-better-workspace 默认分组改为「仅名称」
# workspaceGroupMode 不在插件的 cordis Config 里（Row Config 只有 compactChains /
# statusPulse / styling / appearance），它存在浏览器端持久 store 且"持久值优先"，
# 所以只能改客户端代码里的初始默认值；已选过模式的浏览器不受影响。
"$NODE" "$BUILD/patch-better-workspace.mjs" "$PLUGINS"

echo "=== 6. 验证 ==="
"$NODE" "$APP/node_modules/@deepseek-ai/dsh/lib/bin.js" --version 2>&1 | head -3
"$NODE" -e "const k=require('$APP/node_modules/koffi'); console.log('KOFFI_OK', typeof k.load)" 2>&1 | head -2
"$NODE" -e '
const fs = require("fs"), path = require("path")
const [pluginsDir, extrasFile] = process.argv.slice(1)
const extras = JSON.parse(fs.readFileSync(extrasFile, "utf8"))
const missing = extras.filter((e) => !e.override)
  .filter((e) => !fs.existsSync(path.join(pluginsDir, "node_modules", e.name, "package.json")))
  .map((e) => e.name)
console.log("PLUGINS_OK", missing.length === 0 ? "全部就位" : "缺失 " + missing.join(","))
' "$PLUGINS" "$EXTRAS"
du -sh "$APP/node_modules" "$PLUGINS/node_modules" 2>/dev/null
echo "=== 完成 $(date) ==="
