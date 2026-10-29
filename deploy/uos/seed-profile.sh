#!/bin/bash
# 预置 web profile：**状态驱动**。
#
# 插件是独立组件，每个装在自己的目录：
#   $DEST/plugins/<包名>/             package.json + node_modules + component.json
#
# 本脚本扫描这些目录里的 component.json（installer/插件安装脚本写下的组件元数据），
# 据此推导 profile 需要的东西，不再维护任何硬编码插件清单：
#   - profile/node_modules/<包名> 的逐包软链（指向插件目录）
#   - profile/package.json 的 dependencies 与 dsh.profile.bundles（按 order 排序）
#   - cordis.patch.yml 里「默认禁用」标记块
#
# 幂等：只改自己负责的字段与标记块，用户手写的其他内容原样保留。
#
# 用法: DSH_HOME=<home> ./seed-profile.sh <安装目录>
set -e

DEST="${1:-${DEST:-}}"
HOME_DIR="${DSH_HOME:-}"
if [ -z "$DEST" ]; then echo "seed-profile: 需要安装目录" >&2; exit 1; fi
if [ -z "$HOME_DIR" ]; then echo "seed-profile: 需要 DSH_HOME" >&2; exit 1; fi

NODE_BIN="${SEED_NODE:-node}"
PROFILE="$HOME_DIR/profiles/web"
MODULES="$PROFILE/node_modules"
PLUGINS_ROOT="$DEST/plugins"
if [ ! -x "$NODE_BIN" ]; then echo "seed-profile: node 不可用（$NODE_BIN）" >&2; exit 1; fi

# 已安装插件清单：一行一个 "name<TAB>version<TAB>entryId<TAB>order<TAB>disabled"
# 由 component.json 推导；order 小的先应用，alwaysLast 的组件排到最后。
COMPONENTS="$("$NODE_BIN" - "$PLUGINS_ROOT" <<'JSEOF'
const fs = require('node:fs')
const path = require('node:path')
const root = process.argv[2]
const rows = []
function walk(dir) {
  let entries
  try { entries = fs.readdirSync(dir, { withFileTypes: true }) } catch { return }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue
    const full = path.join(dir, entry.name)
    if (entry.name === 'node_modules' || entry.name.startsWith('.')) continue
    // 作用域目录（@scope）往下再走一层；插件目录里有 component.json。
    if (entry.name.startsWith('@')) { walk(full); continue }
    const metaFile = path.join(full, 'component.json')
    if (!fs.existsSync(metaFile)) continue
    let meta
    try { meta = JSON.parse(fs.readFileSync(metaFile, 'utf8')) } catch (error) {
      console.error(`[seed-profile] component.json 解析失败: ${metaFile} (${error.message})`)
      continue
    }
    if (typeof meta.name !== 'string' || typeof meta.version !== 'string') {
      console.error(`[seed-profile] component.json 缺 name/version: ${metaFile}`)
      continue
    }
    rows.push({
      name: meta.name,
      version: meta.version,
      entryId: typeof meta.entryId === 'string' && meta.entryId !== '' ? meta.entryId : meta.name,
      order: Number.isFinite(meta.order) ? meta.order : 100,
      alwaysLast: meta.alwaysLast === true || meta.policy?.enforced === true,
      disabled: meta.disabled === true || meta.policy?.defaultEnabled === false,
      dir: full,
    })
  }
}
walk(root)
rows.sort((left, right) => left.order - right.order || left.name.localeCompare(right.name))
for (const row of rows) {
  console.log([row.name, row.version, row.entryId, row.order, row.disabled ? '1' : '0', row.alwaysLast ? '1' : '0', row.dir].join('\t'))
}
JSEOF
)"

echo "[seed-profile] 已安装插件: $(printf '%s' "$COMPONENTS" | grep -c . || true) 个"

# 写 profile 前留一份带时间戳的备份（保留最近 3 份）。
mkdir -p "$PROFILE"
if [ -f "$PROFILE/cordis.patch.yml" ]; then
  cp -p "$PROFILE/cordis.patch.yml" "$PROFILE/cordis.patch.yml.$(date +%Y%m%d-%H%M%S).bak"
  ls -1t "$PROFILE"/cordis.patch.yml.*.bak 2>/dev/null | tail -n +4 | xargs -r rm -f
fi

# ============ 1. profile/node_modules 软链 ============
while IFS=$'\t' read -r name _version _entryId _order _disabled _alwaysLast source_dir; do
  [ -n "$name" ] || continue
  [ -d "$source_dir" ] || continue
  link="$MODULES/$name"
  mkdir -p "$(dirname "$link")"
  if [ -L "$link" ]; then
    current="$(readlink "$link" 2>/dev/null || true)"
    if [ "$current" != "$source_dir" ]; then rm -f "$link"; ln -s "$source_dir" "$link"; fi
    continue
  fi
  # 实目录：用户自己 pnpm 装的包，保留原样，不接管。
  if [ -e "$link" ]; then continue; fi
  ln -s "$source_dir" "$link"
done <<< "$COMPONENTS"

# 摘掉「曾经装过、现在已移除」的软链：目标不存在且名字不在当前清单里。
if [ -d "$MODULES" ]; then
  for link in "$MODULES"/* "$MODULES"/@*/*; do
    [ -L "$link" ] || continue
    [ -e "$link" ] && continue
    rm -f "$link"
  done
fi

# ============ 2. profile/package.json：dependencies + bundles ============
COMPONENTS="$COMPONENTS" "$NODE_BIN" - "$PROFILE/package.json" <<'JSEOF'
const fs = require('node:fs')
const manifestFile = process.argv[2]
const rows = (process.env.COMPONENTS ?? '').split('\n').filter((line) => line !== '').map((line) => {
  const [name, version, entryId, order, disabled, alwaysLast] = line.split('\t')
  return { name, version, entryId, order: Number(order), disabled: disabled === '1', alwaysLast: alwaysLast === '1' }
})
const base = ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app']
let manifest
try {
  manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'))
} catch (error) {
  if (error.code !== 'ENOENT') throw error
  manifest = { name: 'dsh-profile-web' }
}
manifest.private = true
manifest.dependencies = { ...manifest.dependencies }
// dependencies 只保留「当前装着的插件 + 官方基座」：已移除的组件不能留残条目，
// 否则每次启动都会报 skipping profile bundle。
const managed = new Set(rows.map((row) => row.name))
for (const name of Object.keys(manifest.dependencies)) {
  if (name.startsWith('@deepseek-ai/')) continue
  if (!managed.has(name)) delete manifest.dependencies[name]
}
for (const row of rows) manifest.dependencies[row.name] = row.version

manifest.dsh = { ...manifest.dsh }
manifest.dsh.profile = { ...manifest.dsh.profile }
const previous = Array.isArray(manifest.dsh.profile.bundles) ? manifest.dsh.profile.bundles : []
// 官方基座固定在最前；插件按 order；alwaysLast 的挪到末端（例如 ga-controller）。
const core = [...new Set([...base, ...previous.filter((name) => name.startsWith('@deepseek-ai/'))])]
const ordered = rows.filter((row) => !row.alwaysLast)
const tail = rows.filter((row) => row.alwaysLast)
// 操作员自己加的非官方 bundle 保留在末尾（在 alwaysLast 之前）。
const extra = previous.filter((name) => !core.includes(name) && !managed.has(name))
const bundles = [...core, ...ordered.map((row) => row.name), ...extra, ...tail.map((row) => row.name)]
manifest.dsh.profile.bundles = [...new Set(bundles)]
fs.writeFileSync(manifestFile, JSON.stringify(manifest, null, 2) + '\n')
console.log(`[seed-profile] bundles: ${manifest.dsh.profile.bundles.length} 项（插件 ${rows.length} 个）`)
JSEOF

# ============ 3. cordis.patch.yml：两个 managed 块 ============
# 文件顺序即优先级：DEFAULT-OFF 块放最前（操作员可在用户区覆盖），ENFORCED 块放最后
# （操作员关不掉）。工具只改这两个块内的字节，用户区原样保留、不删不挪。
PATCH="$PROFILE/cordis.patch.yml"
OFF_BEGIN="# >>> dsh-offline: default-disabled plugins"
OFF_END="# <<< dsh-offline: default-disabled plugins"
ENF_BEGIN="# >>> dsh-offline: enforced plugins"
ENF_END="# <<< dsh-offline: enforced plugins"
COMPONENTS="$COMPONENTS" OFF_BEGIN="$OFF_BEGIN" OFF_END="$OFF_END" ENF_BEGIN="$ENF_BEGIN" ENF_END="$ENF_END" \
  "$NODE_BIN" - "$PATCH" <<'JSEOF'
const fs = require('node:fs')
const path = require('node:path')
const file = process.argv[2]
const beginOff = process.env.OFF_BEGIN
const endOff = process.env.OFF_END
const beginEnf = process.env.ENF_BEGIN
const endEnf = process.env.ENF_END
const rows = (process.env.COMPONENTS ?? '').split('\n').filter((line) => line !== '').map((line) => {
  const [name, version, entryId, order, disabled, alwaysLast] = line.split('\t')
  return { name, entryId, disabled: disabled === '1', enforced: alwaysLast === '1' }
})
// 块内写的是 bundle entry 的 id，不是包名，两者不一定相同。
const offIds = rows.filter((row) => row.disabled && !row.enforced).map((row) => row.entryId)
const enfIds = rows.filter((row) => row.enforced).map((row) => row.entryId)
const offBlock = [
  beginOff,
  '# 由 seed-profile.sh 维护：默认安装后不启用（操作员可在用户区覆盖）',
  ...offIds.flatMap((id) => [`- id: ${id}`, '  disabled: true']),
  endOff,
].join('\n')
const enfBlock = [
  beginEnf,
  '# 由 seed-profile.sh 维护：强制启用，操作员无法通过 profile 关闭',
  ...enfIds.flatMap((id) => [`- id: ${id}`, '  disabled: false']),
  endEnf,
].join('\n')
function stripBlock(text, begin, end) {
  const start = text.indexOf(begin)
  if (start === -1) return text
  const stop = text.indexOf(end, start)
  if (stop === -1) return text
  return text.slice(0, start) + text.slice(stop + end.length)
}
let current = ''
try { current = fs.readFileSync(file, 'utf8') } catch (error) { if (error.code !== 'ENOENT') throw error }
const user = stripBlock(stripBlock(current, beginOff, endOff), beginEnf, endEnf).trim()
const parts = []
if (offIds.length > 0) parts.push(offBlock)
if (user !== '') parts.push(user)
if (enfIds.length > 0) parts.push(enfBlock)
const next = parts.join('\n\n') + '\n'
fs.mkdirSync(path.dirname(file), { recursive: true })
fs.writeFileSync(file, next)
console.log(`[seed-profile] 默认禁用: ${offIds.length === 0 ? '（无）' : offIds.join(', ')}`)
console.log(`[seed-profile] 强制启用: ${enfIds.length === 0 ? '（无）' : enfIds.join(', ')}`)
JSEOF

# ============ 4. webserver 通配绑定迁移（0.2.1 拒绝 0.0.0.0） ============
"$NODE_BIN" - "$PATCH" "$DEST" <<'JSEOF'
const fs = require('node:fs')
const file = process.argv[2]
const dest = process.argv[3]
let current
try { current = fs.readFileSync(file, 'utf8') } catch (error) { if (error.code === 'ENOENT') process.exit(0); throw error }
const lines = current.split('\n')
let inWebserver = false
let changed = false
for (let index = 0; index < lines.length; index += 1) {
  const idMatch = /^\s*-\s*id:\s*(\S+)/u.exec(lines[index])
  if (idMatch) { inWebserver = idMatch[1] === 'webserver'; continue }
  if (!inWebserver) continue
  const hostMatch = /^(\s*host:\s*)["']?(0\.0\.0\.0|::)["']?\s*$/u.exec(lines[index])
  if (hostMatch) { lines[index] = hostMatch[1] + "'127.0.0.1'"; changed = true }
}
if (!changed) process.exit(0)
fs.writeFileSync(file, lines.join('\n'))
console.log('[seed-profile] webserver 通配绑定已改为 127.0.0.1（0.2.1 拒绝 0.0.0.0）')
console.log(`[seed-profile]   要同时对外服务：sudo ${dest}/enable-lan.sh`)
JSEOF

# ============ 5. 渲染浏览器 ============
RENDER_BEGIN="# >>> dsh-offline: render browser"
RENDER_END="# <<< dsh-offline: render browser"
# 没装 univer 插件时不写这一行（并清掉旧块）：patch 里出现找不到的 entry id
# 只会在每次启动时刷警告。
RENDER_ENABLED=1
if ! printf '%s' "$COMPONENTS" | grep -q 'dsh-univer-office'; then RENDER_ENABLED=0; fi
RENDER_ENABLED="$RENDER_ENABLED" "$NODE_BIN" - "$PATCH" "$RENDER_BEGIN" "$RENDER_END" <<'JSEOF'
const fs = require('node:fs')
const path = require('node:path')
const [file, beginMark, endMark] = process.argv.slice(2)
const block = [
  beginMark,
  '# 由 seed-profile.sh 维护：univer 的渲染浏览器，与 chrome-devtools MCP 行读同一个',
  '# 环境变量 DSH_CHROME_PATH（分别的配置行，不是同一行）。',
  '# 需要换浏览器时改 start-web.sh 里的 DSH_CHROME_PATH，这里会自动跟随。',
  '- id: univer',
  '  config:',
  "    browserExecutablePath: !!js process.env.DSH_CHROME_PATH ?? '/usr/bin/browser'",
  endMark,
].join('\n')
let current = ''
try { current = fs.readFileSync(file, 'utf8') } catch (error) { if (error.code !== 'ENOENT') throw error }
const beginAt = current.indexOf(beginMark)
const endAt = current.indexOf(endMark)
const enabled = process.env.RENDER_ENABLED === '1'
let next
if (!enabled) {
  // 卸载 univer 后清掉自己写过的那一段。
  if (beginAt !== -1 && endAt > beginAt) {
    next = current.slice(0, beginAt) + current.slice(endAt + endMark.length)
    fs.writeFileSync(file, next.replace(/\n{3,}/gu, '\n\n').trimStart() + '\n')
    console.log('[seed-profile] 渲染浏览器: univer 未安装，已移除该配置块')
  }
  process.exit(0)
}
next = beginAt !== -1 && endAt > beginAt
  ? current.slice(0, beginAt) + block + current.slice(endAt + endMark.length)
  : (current.trimEnd() === '' ? block : current.trimEnd() + '\n\n' + block)
fs.mkdirSync(path.dirname(file), { recursive: true })
fs.writeFileSync(file, next.trimEnd() + '\n')
console.log('[seed-profile] 渲染浏览器: DSH_CHROME_PATH')
JSEOF

# ============ 6. 配置卫生维护 ============
if [ -f "$DEST/maintain-profile.mjs" ]; then
  FORCED_IDS="$(printf '%s' "$COMPONENTS" | awk -F'\t' '$6=="1"{print $3}' | paste -sd, -)"
  DISABLED_IDS="$(printf '%s' "$COMPONENTS" | awk -F'\t' '$5=="1"{print $3}' | paste -sd, -)"
  "$NODE_BIN" "$DEST/maintain-profile.mjs" "$PATCH" "$PROFILE/cordis.yml" "$DEST" "$DISABLED_IDS" "$FORCED_IDS"
else
  echo "[seed-profile] 缺少 maintain-profile.mjs，跳过配置卫生维护"
fi

# ============ 7. 播种标记 ============
DSH_VER="$(LC_ALL=C "$NODE_BIN" -p "require('$DEST/app/node_modules/@deepseek-ai/dsh/package.json').version" 2>/dev/null || echo unknown)"
COMPONENTS="$COMPONENTS" "$NODE_BIN" - "$PROFILE" "$DSH_VER" <<'JSEOF'
const fs = require('node:fs')
const path = require('node:path')
const [profileDir, dshVersion] = process.argv.slice(2)
const rows = (process.env.COMPONENTS ?? '').split('\n').filter((line) => line !== '').map((line) => {
  const [name, version] = line.split('\t')
  return { name, version }
})
const file = path.join(profileDir, '.dsh-offline-state.json')
fs.writeFileSync(file, JSON.stringify({
  seedVersion: 3,
  layout: 'components',
  dshVersion,
  components: Object.fromEntries(rows.map((row) => [row.name, row.version])),
  seededAt: new Date().toISOString(),
  seededBy: process.env.USER || process.env.LOGNAME || 'unknown',
}, null, 2) + '\n')
console.log(`[seed-profile] 播种标记: dsh ${dshVersion} / 组件 ${rows.length} 个`)
JSEOF
