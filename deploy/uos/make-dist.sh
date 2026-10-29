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

# ---------- 主体组件：core / tools / scripts / shell ----------
# 拆分目的：改一行脚本只发 scripts（几十 KB），不必重下 1.7GB 本体。
# core/tools/shell 的版本跟随分发版本；scripts 的版本取脚本内容哈希，内容没变就不会重装。
echo "=== 1. 主体组件（core/tools/scripts/shell）==="
mkdir -p "$STAGE/components"
: > "$STAGE/components.list"

# scripts 版本 = 脚本内容哈希（前 12 位）：只有脚本真的变了，客户端才会重装这个组件。
SCRIPTS_DIR="$STAGE/scripts-payload/scripts"
mkdir -p "$SCRIPTS_DIR"
for script in seed-profile.sh doctor.sh collect-logs.sh maintain-profile.mjs enable-lan.sh installer.sh README.txt; do
  [ -f "$BUILD/$script" ] && cp "$BUILD/$script" "$SCRIPTS_DIR/"
done
[ -f "$SCRIPTS_DIR/seed-profile.sh" ] || { echo "[错误] 缺 seed-profile.sh"; exit 1; }
[ -f "$SCRIPTS_DIR/installer.sh" ] || { echo "[错误] 缺 installer.sh"; exit 1; }
SCRIPTS_VERSION="$(cd "$SCRIPTS_DIR" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-12)"

# makeComponent <name> <kind> <version> <order> <payload-root> <payload-subdir>
makeComponent() {
  local name="$1" kind="$2" version="$3" order="$4" payloadRoot="$5" subdir="$6" slug work tarfile
  slug="$(slugOf "$name")"
  work="$STAGE/comp-$slug"
  rm -rf "$work"
  mkdir -p "$work/package/payload/$(dirname "$subdir")"
  printf '%s\n' "$version" > "$work/package/payload/VERSION"
  cp "$BUILD/component/$kind/install.sh" "$work/package/install.sh"
  chmod 755 "$work/package/install.sh"
  ln -s "$payloadRoot" "$work/package/payload/$subdir"
  # core 组件同时携带 Node 运行时（脚本/壳/工具在各自组件里）。
  [ "$kind" = "core" ] && ln -s "$BUILD/node" "$work/package/payload/node"
  "$BUILD/node/bin/node" - "$work/package/component.json" "$name" "$kind" "$version" "$DSH_VER" "$order" <<'JSEOF'
const fs = require('fs')
const [file, name, kind, version, dshVersion, order] = process.argv.slice(2)
fs.writeFileSync(file, JSON.stringify({
  name, kind, version, dshVersion, order: Number(order),
  policy: { defaultEnabled: true, enforced: false },
  installedBy: 'installer',
}, null, 2) + '\n')
JSEOF
  tarfile="$DIST/components/$slug-$version.tar.gz"
  tar czhf "$tarfile" -C "$work" package/component.json package/install.sh package/payload
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$kind" "$version" "$order" "components/$(basename "$tarfile")" >> "$STAGE/components.list"
  echo "  组件: $(basename "$tarfile") ($(du -h "$tarfile" | cut -f1))"
}

makeComponent "@deepseek-ai/dsh-core"    core    "$PKG_VERSION"     0  "$APP"                    app
makeComponent "@deepseek-ai/dsh-scripts" scripts "$SCRIPTS_VERSION" 2 "$SCRIPTS_DIR" scripts
[ -d "$BUILD/desktop" ] && makeComponent "@deepseek-ai/dsh-shell" shell "$PKG_VERSION" 3 "$BUILD/desktop" desktop
[ -d "$BUILD/tools" ]   && makeComponent "@deepseek-ai/dsh-tools" tools "$PKG_VERSION" 1 "$BUILD/tools"   tools

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
  meta.policy = { defaultEnabled: disabled !== '1', enforced: alwaysLast === '1' }
if (disabled === '1') meta.disabled = true
if (alwaysLast === '1') meta.alwaysLast = true
fs.writeFileSync(file, JSON.stringify(meta, null, 2) + '\n')
JSEOF
  out="$DIST/components/$slug-$version.tar.gz"
  tar czhf "$out" -C "$work" package/component.json package/install.sh package/payload
  echo "  $name@$version -> $slug-$version.tar.gz ($(du -h "$out" | cut -f1))"
done < "$STAGE/plugins.list"

# ---------- installer + manifest ----------
printf '%s\n' "$PKG_VERSION" > "$DIST/VERSION"
echo "=== 3. installer 与清单 ==="
cp "$BUILD/installer.sh" "$DIST/installer.sh"
chmod 755 "$DIST/installer.sh"

"$BUILD/node/bin/node" - "$DIST" "$PKG_VERSION" "$DSH_VER" "$STAGE/components.list" "$STAGE/plugins.list" <<'JSEOF'
const fs = require('node:fs')
const path = require('node:path')
const crypto = require('node:crypto')
const dist = process.argv[2]
const version = process.argv[3]
const dshVersion = process.argv[4]
const componentsList = process.argv[5]
const pluginsList = process.argv[6]

const sha256 = (file) => {
  const hash = crypto.createHash('sha256')
  const fd = fs.openSync(file, 'r')
  const buffer = Buffer.alloc(1 << 20)
  let read
  while ((read = fs.readSync(fd, buffer, 0, buffer.length, null)) > 0) hash.update(buffer.subarray(0, read))
  fs.closeSync(fd)
  return hash.digest('hex')
}

const components = []

for (const line of fs.readFileSync(componentsList, 'utf8').split('\n')) {
  if (line === '') continue
  const [name, kind, entryVersion, order, file] = line.split('\t')
  const abs = path.join(dist, file)
  components.push({
    name, kind, version: entryVersion, order: Number(order),
    policy: { defaultEnabled: true, enforced: false },
    file, sha256: sha256(abs), size: fs.statSync(abs).size,
  })
}

if (fs.existsSync(pluginsList)) {
  for (const line of fs.readFileSync(pluginsList, 'utf8').split('\n')) {
    if (line === '') continue
    const [name, pluginVersion, entryId, order, disabled, alwaysLast] = line.split('\t')
    if (disabled === undefined) continue
    const slug = name.replace(/^@/u, '').replaceAll('/', '-')
    const file = `components/${slug}-${pluginVersion}.tar.gz`
    const abs = path.join(dist, file)
    components.push({
      name, kind: 'plugin', version: pluginVersion, entryId, order: Number(order),
      policy: { defaultEnabled: disabled !== '1', enforced: alwaysLast === '1' },
      file, sha256: sha256(abs), size: fs.statSync(abs).size,
    })
  }
}

components.sort((left, right) => left.order - right.order || left.name.localeCompare(right.name))

const manifest = {
  format: 3,
  version,
  dshVersion,
  generatedAt: new Date().toISOString(),
  installer: { version, file: 'installer.sh' },
  components,
}
fs.writeFileSync(path.join(dist, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n')
const body = components.filter((component) => component.kind !== 'plugin')
const plugins = components.filter((component) => component.kind === 'plugin')
console.log(`  清单: ${components.length} 个组件（主体 ${body.length} + 插件 ${plugins.length}）`)
JSEOF

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
