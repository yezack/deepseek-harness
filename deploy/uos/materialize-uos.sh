#!/bin/bash
# UOS 侧：物化组件依赖树。
#
#   $BUILD/app                      dsh 本体（tarball-index.json 的全量官方包 + 传递依赖）
#   $BUILD/plugins-build/<包名>/    每个插件一棵**自包含**依赖树（nested 布局）
#
# 每个插件独立成包、独立安装，因此插件树必须自带全部第三方依赖：用
# `--install-strategy=nested` 让 npm 把依赖都放到插件包自己的 node_modules 里，
# 不从树根共享。宿主包（@deepseek-ai/*）例外——它们由本体的 profile 解析提供，
# 安装时在插件目录里软链回本体那一份（见 component/plugin/install.sh）。
#
# 用法: ./materialize-uos.sh [build-dir]
set -e
BUILD="${1:-$(cd "$(dirname "$0")" && pwd)}"
APP="$BUILD/app"
PLUGINS_BUILD="$BUILD/plugins-build"
TARBALLS="$BUILD/tarballs"
INDEX="$BUILD/tarball-index.json"
EXTRAS="${EXTRAS:-$BUILD/extras.json}"

NODE_DIR=/var/tmp/node22
export PATH="$NODE_DIR/bin:$PATH"
NODE="$NODE_DIR/bin/node"
NPM="$NODE_DIR/lib/node_modules/npm/bin/npm-cli.js"
export NARB_NATIVE_CACHE_DIR=/var/tmp/dsh-native-cache
mkdir -p "$NARB_NATIVE_CACHE_DIR"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"

echo "=== 0. 环境 ==="
"$NODE" -v
"$NODE" "$NPM" --version
ls -l "$INDEX" >/dev/null || { echo "[错误] 缺少索引 $INDEX"; exit 1; }
[ -f "$EXTRAS" ] || { echo "[错误] 缺少插件清单 $EXTRAS"; exit 1; }

echo "=== 1. 本体树 package.json ==="
rm -rf "$APP"; mkdir -p "$APP"
"$NODE" - "$TARBALLS" "$INDEX" "$APP" "$EXTRAS" "$BUILD" <<'JSEOF'
const fs = require('fs'), path = require('path');
const [tarballs, indexFile, app, extrasFile, bundleDir] = process.argv.slice(2);
const idx = JSON.parse(fs.readFileSync(indexFile, 'utf8'));
const extras = JSON.parse(fs.readFileSync(extrasFile, 'utf8'));
// 带 override 的条目不是普通依赖：把 tarball 装到另一个包名下。
// 消费方（browser-use）在本体树里按包名解析，所以 override 只进本体树。
const overridden = new Set(), overrides = {};
for (const e of extras) {
  if (!e.override) continue;
  overridden.add(e.override);
  overrides[e.override] = 'file:' + path.resolve(bundleDir, e.spec.replace(/^file:/, ''));
}
const deps = {}, miss = [];
for (const e of idx) {
  if (overridden.has(e.name)) continue;
  const f = path.join(tarballs, e.file);
  if (!fs.existsSync(f)) { miss.push(e.file); continue; }
  deps[e.name] = 'file:' + f;
}
const pkg = { name: 'dsh-uos-offline-body', version: '0.0.0', private: true, dependencies: deps };
if (Object.keys(overrides).length > 0) pkg.overrides = overrides;
fs.writeFileSync(path.join(app, 'package.json'), JSON.stringify(pkg, null, 2));
console.log('  本体: 索引条目', idx.length, '生成依赖', Object.keys(deps).length, 'override', Object.keys(overrides).length, '缺失', miss.length);
JSEOF

echo "=== 2. 安装本体树 ==="
echo "  registry: $NPM_REGISTRY"
cd "$APP"
"$NODE" "$NPM" install --no-audit --no-fund --legacy-peer-deps --ignore-scripts \
  --registry "$NPM_REGISTRY" --loglevel=warn 2>&1 | tail -8
echo "  本体 npm 退出码=${PIPESTATUS[0]}"

echo "=== 3. 逐插件安装（自包含树）==="
rm -rf "$PLUGINS_BUILD"; mkdir -p "$PLUGINS_BUILD"
"$NODE" - "$EXTRAS" "$BUILD" "$PLUGINS_BUILD" <<'JSEOF' > "$PLUGINS_BUILD/.list"
const fs = require('fs'), path = require('path');
const [extrasFile, bundleDir, outRoot] = process.argv.slice(2);
const extras = JSON.parse(fs.readFileSync(extrasFile, 'utf8'));
for (const e of extras) {
  if (e.override) continue;              // chrome-devtools-mcp fork 属于本体树
  const spec = e.spec
    ? 'file:' + path.resolve(bundleDir, e.spec.replace(/^file:/, ''))
    : e.version;
  console.log(`${e.name}\t${spec}`);
}
JSEOF
PLUGIN_COUNT=0
while IFS=$'\t' read -r name spec; do
  [ -n "$name" ] || continue
  dir="$PLUGINS_BUILD/$(echo "$name" | tr '/@' '__')"
  echo "  --- $name"
  mkdir -p "$dir"
  printf '%s\n' "$name" > "$dir/.component-name"
  cat > "$dir/package.json" <<PLUGINPKG
{
  "name": "dsh-plugin-component-$(echo "$name" | tr '/@' '__')",
  "version": "0.0.0",
  "private": true,
  "dependencies": { "$name": "$spec" }
}
PLUGINPKG
  ( cd "$dir" && "$NODE" "$NPM" install --no-audit --no-fund --legacy-peer-deps --ignore-scripts \
      --install-strategy=nested --registry "$NPM_REGISTRY" --loglevel=silent 2>&1 | tail -3 )
  # 自包含化：npm 即便给了 --install-strategy=nested 也可能把依赖提升到树根。
  # 把树根 node_modules 里除插件本身之外的条目全部搬进插件包的 node_modules，
  # 这样插件包就是自包含的（独立安装/卸载时不需要任何共享目录）。
  "$NODE" - "$dir" "$name" <<'JSEOF'
const fs = require('fs'), path = require('path')
const [treeRoot, name] = process.argv.slice(2)
const rootModules = path.join(treeRoot, 'node_modules')
const pluginDir = path.join(rootModules, name)
const pluginModules = path.join(pluginDir, 'node_modules')
const scope = name.startsWith('@') ? name.split('/')[0] : undefined
fs.mkdirSync(pluginModules, { recursive: true })
let moved = 0
function moveEntry(from, to) {
  if (fs.existsSync(to)) fs.rmSync(to, { recursive: true, force: true })
  fs.renameSync(from, to)
  moved += 1
}
for (const entry of fs.readdirSync(rootModules)) {
  if (entry === '.bin' || entry === '.package-lock.json') continue
  if (entry === name) continue
  const from = path.join(rootModules, entry)
  if (entry === scope) {
    // 作用域目录：搬走除插件自己以外的兄弟包，搬空后删掉目录。
    for (const sibling of fs.readdirSync(from)) {
      if (`${scope}/${sibling}` === name) continue
      moveEntry(path.join(from, sibling), path.join(pluginModules, scope, sibling))
    }
    const rest = fs.readdirSync(from)
    if (rest.length === 0) fs.rmdirSync(from)
    continue
  }
  moveEntry(from, path.join(pluginModules, entry))
}
console.log(`      ${name}: 归档 ${moved} 个依赖到插件包内`)
JSEOF
  # 自包含检查：依赖必须在插件包自己的 node_modules 里（nested 布局）。
  if [ ! -d "$dir/node_modules/$(echo "$name")/node_modules" ] && [ "$(ls "$dir/node_modules" | wc -l)" -gt 1 ]; then
    echo "      [警告] $name 的依赖没有完全嵌套（nested 可能未生效）"
  fi
  PLUGIN_COUNT=$((PLUGIN_COUNT + 1))
done < "$PLUGINS_BUILD/.list"
rm -f "$PLUGINS_BUILD/.list"
echo "  已物化插件: $PLUGIN_COUNT 个"

echo "=== 4. koffi 预编译包（本体树 + 各插件树按需）==="
install_koffi() {
  local tree="$1" label="$2"
  local ver
  ver=$("$NODE" -e "try{console.log(require('$tree/node_modules/koffi/package.json').version)}catch(e){console.log('')}" 2>/dev/null)
  [ -n "$ver" ] || return 0
  echo "  $label koffi $ver"
  ( cd "$tree" && "$NODE" "$NPM" install --no-audit --no-fund --no-save --force --ignore-scripts \
      --registry "$NPM_REGISTRY" "@koromix/koffi-linux-x64@$ver" >/dev/null 2>&1 ) || true
}
install_koffi "$APP" 本体
for dir in "$PLUGINS_BUILD"/*; do
  [ -d "$dir" ] || continue
  # 插件树里的 koffi 可能嵌在插件包自己的 node_modules 下。
  candidate="$(find "$dir" -maxdepth 5 -type d -path '*/node_modules/koffi' | head -1)"
  [ -n "$candidate" ] || continue
  tree_root="$(cd "$candidate/../.." && pwd)"
  install_koffi "$tree_root" "$(cat "$dir/.component-name" 2>/dev/null || basename "$dir")"
done

echo "=== 5. 构建期补丁（打在各插件树里）==="
PLUGIN_PATCH_ROOT="$BUILD/.patch-root"
rm -rf "$PLUGIN_PATCH_ROOT"; mkdir -p "$PLUGIN_PATCH_ROOT/node_modules"
# 补丁脚本按 <app>/node_modules/<包名> 定位，这里给它们一个同一形状的根。
# 插件目录名 = 包名的 '@' 与 '/' 都换成 '_'（与上面的 tr 一致）。
plugin_tree_dir() { printf '%s/%s' "$PLUGINS_BUILD" "$(printf '%s' "$1" | tr '/@' '__')"; }
link_plugin_for_patch() {
  local name="$1" dir
  dir="$(plugin_tree_dir "$name")/node_modules/$1"
  if [ ! -d "$dir" ]; then echo "      [跳过] $name 未物化"; return 0; fi
  rm -rf "$PLUGIN_PATCH_ROOT/node_modules/$name"
  mkdir -p "$(dirname "$PLUGIN_PATCH_ROOT/node_modules/$name")"
  ln -sfn "$dir" "$PLUGIN_PATCH_ROOT/node_modules/$name"
}
link_plugin_for_patch "@yezack/dsh-remote-mobile"
link_plugin_for_patch "dsh-better-workspace"
"$NODE" "$BUILD/patch-remote-mobile.mjs" "$PLUGIN_PATCH_ROOT"
"$NODE" "$BUILD/patch-better-workspace.mjs" "$PLUGIN_PATCH_ROOT"
rm -rf "$PLUGIN_PATCH_ROOT"

echo "=== 6. 验证 ==="
"$NODE" "$APP/node_modules/@deepseek-ai/dsh/lib/bin.js" --version 2>&1 | head -2
"$NODE" -e "const k=require('$APP/node_modules/koffi'); console.log('KOFFI_OK', typeof k.load)" 2>&1 | head -2
"$NODE" - "$PLUGINS_BUILD" <<'JSEOF'
const fs = require('fs'), path = require('path')
const root = process.argv[2]
const dirs = fs.readdirSync(root, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name)
let ok = 0
const bad = []
for (const dir of dirs) {
  const treeRoot = path.join(root, dir)
  const nameFile = path.join(treeRoot, '.component-name')
  if (!fs.existsSync(nameFile)) { bad.push(`${dir}(缺 .component-name)`); continue }
  const name = fs.readFileSync(nameFile, 'utf8').trim()
  const pkgDir = path.join(treeRoot, 'node_modules', name)
  if (!fs.existsSync(path.join(pkgDir, 'package.json'))) { bad.push(`${name}(未安装)`); continue }
  // 自包含：插件包自己的 node_modules 必须存在（nested 布局），否则装到目标机后
  // 依赖会去插件目录之外找，独立安装就不成立了。
  if (!fs.existsSync(path.join(pkgDir, 'node_modules'))) { bad.push(`${name}(依赖未嵌套)`); continue }
  ok += 1
}
console.log('PLUGIN_TREES_OK', ok, '/', dirs.length, bad.length ? '异常: ' + bad.join(',') : '')
JSEOF
du -sh "$APP" "$PLUGINS_BUILD" 2>/dev/null
echo "=== 完成 $(date) ==="
