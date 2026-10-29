#!/bin/bash
# UOS 侧：把物化好的树打成**按组件分发**的目录（不再有整包）。
#
# 产物（$BUILD/dist/）：
#   installer.sh                          统一管理入口（安装/升级/卸载/状态）
#   manifest.json                         组件清单（版本、sha256、顺序、entryId…）
#   VERSION                               本次分发的版本号
#   components/dsh-body-<ver>.tar.gz      本体组件
#   components/<slug>-<ver>.tar.gz        每个插件一个组件包
#
# 每个组件包内部结构一致，可单独安装：
#   package/component.json
#   package/install.sh
#   package/payload/...
#
# 用法: ./make-dist.sh [build-dir]
# 环境: DSH_BUILD_VERSION 固定本次分发版本；SKIP_SHA=1 跳过已有组件的重新打包
set -e
BUILD="${1:-$(cd "$(dirname "$0")" && pwd)}"
APP="$BUILD/app"
PLUGINS_BUILD="$BUILD/plugins-build"
EXTRAS="${EXTRAS:-$BUILD/extras.json}"
COMPONENTS_META="${COMPONENTS_META:-$BUILD/components.json}"
DIST="$BUILD/dist"
STAGE="$BUILD/.dist-stage"
VER_FILE="$APP/node_modules/@deepseek-ai/dsh/package.json"

[ -d "$APP/node_modules" ] || { echo "[错误] $APP/node_modules 不存在（先跑 materialize-uos.sh）"; exit 1; }
[ -d "$PLUGINS_BUILD" ] || { echo "[错误] $PLUGINS_BUILD 不存在（先跑 materialize-uos.sh）"; exit 1; }
[ -x "$BUILD/node/bin/node" ] || { echo "[错误] $BUILD/node/bin/node 不存在"; exit 1; }
[ -f "$COMPONENTS_META" ] || { echo "[错误] 缺少组件元数据 $COMPONENTS_META"; exit 1; }

DSH_VER=$(python3 -c "import json;print(json.load(open('$VER_FILE'))['version'])" 2>/dev/null || echo "?")
PKG_VERSION="${DSH_BUILD_VERSION:-$(date -u +%Y%m%d.%H%M)}"
echo "=== 打包组件分发 dsh $DSH_VER / 分发版本 $PKG_VERSION ==="

rm -rf "$DIST" "$STAGE"
mkdir -p "$DIST/components" "$STAGE"

# tar 需要"同一个 package/ 前缀 + payload 里的目录是多 GB 的树"，直接复制代价太大：
# 用软链搭出 package/ 的形状，tar -h 按真实内容归档。
mkdir -p "$STAGE/body/package/payload"
mkdir -p "$STAGE/plugins"

slugOf() { printf '%s' "$1" | sed 's/^@//; s#/#-#g'; }

# ---------- 本体组件 ----------
echo "=== 1. 本体组件 ==="
BODY_VERSION="$PKG_VERSION"
cp "$BUILD/component/body/install.sh" "$STAGE/body/package/install.sh"
chmod 755 "$STAGE/body/package/install.sh"
printf '%s\n' "$BODY_VERSION" > "$STAGE/body/package/payload/VERSION"
mkdir -p "$STAGE/body/package/payload/scripts"
for script in seed-profile.sh doctor.sh collect-logs.sh maintain-profile.mjs enable-lan.sh installer.sh README.txt; do
  [ -f "$BUILD/$script" ] && cp "$BUILD/$script" "$STAGE/body/package/payload/scripts/"
done
[ -f "$STAGE/body/package/payload/scripts/seed-profile.sh" ] || { echo "[错误] 缺 seed-profile.sh"; exit 1; }
[ -f "$STAGE/body/package/payload/scripts/installer.sh" ] || { echo "[错误] 缺 installer.sh"; exit 1; }
ln -s "$APP" "$STAGE/body/package/payload/app"
ln -s "$BUILD/node" "$STAGE/body/package/payload/node"
[ -d "$BUILD/desktop" ] && ln -s "$BUILD/desktop" "$STAGE/body/package/payload/desktop"
[ -d "$BUILD/tools" ] && ln -s "$BUILD/tools" "$STAGE/body/package/payload/tools"
[ -d "$BUILD/browser" ] && ln -s "$BUILD/browser" "$STAGE/body/package/payload/browser"
"$BUILD/node/bin/node" - "$STAGE/body/package/component.json" "$BODY_VERSION" "$DSH_VER" <<'JSEOF'
const fs = require('fs')
const [file, version, dshVersion] = process.argv.slice(2)
fs.writeFileSync(file, JSON.stringify({
  name: '@deepseek-ai/dsh',
  kind: 'body',
  version,
  dshVersion,
  order: 0,
  installedBy: 'installer',
}, null, 2) + '\n')
JSEOF
tar czhf "$DIST/components/dsh-body-$BODY_VERSION.tar.gz" -C "$STAGE/body" package/component.json package/install.sh package/payload
echo "  组件: dsh-body-$BODY_VERSION.tar.gz ($(du -h "$DIST/components/dsh-body-$BODY_VERSION.tar.gz" | cut -f1))"

# ---------- 插件组件 ----------
echo "=== 2. 插件组件 ==="
# 用 node 生成每个插件的元数据行：name<TAB>version<TAB>entryId<TAB>order<TAB>disabled<TAB>alwaysLast
"$BUILD/node/bin/node" - "$EXTRAS" "$COMPONENTS_META" "$PLUGINS_BUILD" <<'JSEOF' > "$STAGE/plugins.list"
const fs = require('fs'), path = require('path')
const [extrasFile, metaFile, buildRoot] = process.argv.slice(2)
const extras = JSON.parse(fs.readFileSync(extrasFile, 'utf8'))
const meta = JSON.parse(fs.readFileSync(metaFile, 'utf8')).components ?? {}
for (const entry of extras) {
  if (entry.override) continue
  // 构建树目录名：'@' 与 '/' 都换成 '_'（与 materialize-uos.sh 的 tr 一致）。
  const buildDir = entry.name.replaceAll('@', '_').replaceAll('/', '_')
  const dir = path.join(buildRoot, buildDir)
  const pkgFile = path.join(dir, 'node_modules', entry.name, 'package.json')
  if (!fs.existsSync(pkgFile)) { console.error(`  [跳过] ${entry.name} 未物化`); continue }
  const pkg = JSON.parse(fs.readFileSync(pkgFile, 'utf8'))
  const own = meta[entry.name] ?? {}
  const fields = [
    entry.name, pkg.version, own.entryId ?? entry.name, own.order ?? 100,
    own.disabled === true ? '1' : '0', own.alwaysLast === true ? '1' : '0',
  ]
  console.log(fields.join('\t'))
}
JSEOF
while IFS=$'\t' read -r name version entryId order disabled alwaysLast; do
  [ -n "$name" ] || continue
  slug="$(slugOf "$name")"
  build_dir="$(printf '%s' "$name" | tr '/@' '__')"
  work="$STAGE/plugins/$slug"
  mkdir -p "$work/package/payload"
  cp "$BUILD/component/plugin/install.sh" "$work/package/install.sh"
  chmod 755 "$work/package/install.sh"
  ln -s "$PLUGINS_BUILD/$build_dir/node_modules/$name" "$work/package/payload/plugin"
  "$BUILD/node/bin/node" - "$work/package/component.json" "$name" "$version" "$DSH_VER" "$entryId" "$order" "$disabled" "$alwaysLast" <<'JSEOF'
const fs = require('fs')
const [file, name, version, dshVersion, entryId, order, disabled, alwaysLast] = process.argv.slice(2)
const meta = { name, kind: 'plugin', version, dshVersion, entryId, order: Number(order) }
if (disabled === '1') meta.disabled = true
if (alwaysLast === '1') meta.alwaysLast = true
fs.writeFileSync(file, JSON.stringify(meta, null, 2) + '\n')
JSEOF
  out="$DIST/components/$slug-$version.tar.gz"
  tar czhf "$out" -C "$work" package/component.json package/install.sh package/payload
  echo "  $name@$version -> $slug-$version.tar.gz ($(du -h "$out" | cut -f1))"
done < "$STAGE/plugins.list"

# ---------- installer + manifest ----------
echo "=== 3. installer 与清单 ==="
cp "$BUILD/installer.sh" "$DIST/installer.sh"
chmod 755 "$DIST/installer.sh"
printf '%s\n' "$PKG_VERSION" > "$DIST/VERSION"
"$BUILD/node/bin/node" - "$DIST" "$BUILD" "$PKG_VERSION" "$DSH_VER" <<'JSEOF'
const fs = require('fs'), path = require('path'), crypto = require('node:crypto')
const [dist, buildRoot, version, dshVersion] = process.argv.slice(2)
function sha256(file) {
  const hash = crypto.createHash('sha256')
  const fd = fs.openSync(file, 'r')
  const buffer = Buffer.alloc(1 << 20)
  let read
  while ((read = fs.readSync(fd, buffer, 0, buffer.length, null)) > 0) hash.update(buffer.subarray(0, read))
  fs.closeSync(fd)
  return hash.digest('hex')
}
const componentsDir = path.join(dist, 'components')
const files = fs.readdirSync(componentsDir).filter((file) => file.endsWith('.tar.gz')).sort()
const body = files.find((file) => file.startsWith('dsh-body-'))
const plugins = files.filter((file) => !file.startsWith('dsh-body-'))
const components = []
const bodyVersion = version
components.push({
  name: '@deepseek-ai/dsh', kind: 'body', version: bodyVersion, order: 0,
  file: `components/${body}`,
  sha256: sha256(path.join(componentsDir, body)),
  size: fs.statSync(path.join(componentsDir, body)).size,
})
// 插件元数据从组件包里的 component.json 读一遍（tar 太贵，改用打包时写下的清单文件）。
const listFile = path.join(buildRoot, '.dist-stage', 'plugins.list')
const rows = fs.readFileSync(listFile, 'utf8').split('\n').filter(Boolean).map((line) => line.split('\t'))
let index = 0
for (const [name, pluginVersion, entryId, order, disabled, alwaysLast] of rows) {
  const slug = name.replace(/^@/u, '').replaceAll('/', '-')
  const file = plugins.find((candidate) => candidate === `${slug}-${pluginVersion}.tar.gz`)
  if (file === undefined) { console.error(`[错误] 清单缺组件包: ${slug}-${pluginVersion}.tar.gz`); process.exit(1) }
  const entry = {
    name, kind: 'plugin', version: pluginVersion, entryId, order: Number(order),
    file: `components/${file}`,
    sha256: sha256(path.join(componentsDir, file)),
    size: fs.statSync(path.join(componentsDir, file)).size,
  }
  if (disabled === '1') entry.disabled = true
  if (alwaysLast === '1') entry.alwaysLast = true
  components.push(entry)
  index += 1
}
components.sort((left, right) => left.order - right.order || left.name.localeCompare(right.name))
const manifest = {
  format: 2,
  generatedAt: new Date().toISOString(),
  version,
  dshVersion,
  installer: { version, file: 'installer.sh' },
  components,
}
fs.writeFileSync(path.join(dist, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n')
console.log(`  清单: ${components.length} 个组件（本体 1 + 插件 ${index}）`)
JSEOF
rm -rf "$STAGE"

# ---------- 介质自检清单 + 离线安装入口 ----------
# 离线交付是"整目录拷介质"：先校验完整性再安装，防止 U 盘/共享目录拷贝损坏。
echo "=== 3b. 介质清单与安装入口 ==="
"$BUILD/node/bin/node" - "$DIST" <<'JSEOF'
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto')
const dist = process.argv[2]
const sha = (file) => {
  const hash = crypto.createHash('sha256')
  const fd = fs.openSync(file, 'r')
  const buffer = Buffer.alloc(1 << 20)
  let read
  while ((read = fs.readSync(fd, buffer, 0, buffer.length, null)) > 0) hash.update(buffer.subarray(0, read))
  fs.closeSync(fd)
  return hash.digest('hex')
}
const files = fs.readdirSync(path.join(dist, 'components'))
  .filter((file) => file.endsWith('.tar.gz'))
  .sort()
  .map((file) => `components/${file}`)
files.push('manifest.json', 'VERSION')
fs.writeFileSync(path.join(dist, 'SHA256SUMS'), files.map((rel) => `${sha(path.join(dist, rel))}  ${rel}`).join('\n') + '\n')
console.log(`  SHA256SUMS: ${files.length} 项`)
JSEOF
cat > "$DIST/install.sh" <<'WRAPPER'
#!/bin/bash
# 离线介质安装入口：先校验介质完整性（SHA256SUMS），再交给 installer 执行。
#
# 用法（在介质目录里）：
#   sudo ./install.sh              全新安装或升级（由 installer apply 自动判定）
#   sudo ./install.sh --dry-run    只打印计划
#   sudo ./install.sh --yes        非交互
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE" || { echo "ERROR 无法进入介质目录 $HERE" >&2; exit 1; }
[ -f SHA256SUMS ] || { echo "ERROR 缺少 SHA256SUMS（介质不完整）" >&2; exit 1; }
[ -f installer.sh ] || { echo "ERROR 缺少 installer.sh（介质不完整）" >&2; exit 1; }
echo "PHASE 介质自检"
# 用 --quiet：只输出失败项（中文 locale 下 "成功" 不是 "OK"，不能用 grep 过滤）。
if ! CHECK_OUT="$(sha256sum --quiet -c SHA256SUMS 2>&1)"; then
  echo "ERROR 介质校验失败：拷贝可能损坏，请重新复制介质" >&2
  printf '%s\n' "$CHECK_OUT" | head -5 >&2
  exit 1
fi
echo "RESULT ok medium-verified"
exec bash "$HERE/installer.sh" apply --dist "$HERE" "$@"
WRAPPER
chmod 755 "$DIST/install.sh"

echo "=== 4. 结果 ==="
ls -lh "$DIST" | head -10
ls -lh "$DIST/components" | head -20
echo "--- 清单摘要 ---"
"$BUILD/node/bin/node" -e '
const m = require("'"$DIST"'/manifest.json")
console.log("format", m.format, "version", m.version, "dsh", m.dshVersion)
for (const c of m.components) console.log(`  ${c.kind.padEnd(6)} ${c.name}@${c.version}  order=${c.order}${c.disabled ? " disabled" : ""}${c.alwaysLast ? " alwaysLast" : ""}  ${(c.size / 1048576).toFixed(1)}MB`)
'
echo "=== 完成 $(date) ==="
