// 对 @yezack/dsh-remote-mobile 这个预装插件做三处构建期修正。
//
// 【1】修正 bundle patch 里的 row name
//
// 包名是 @yezack/dsh-remote-mobile，但发布出来的 cordis.patch.yml 里 row 的
// name 仍是上游的 'dsh-remote-mobile'。两者必须一致：client-modules 会用 row 的
// name 做 `require.resolve('<name>/package.json')`（packages/client/modules/src/
// index.ts:886），profile 的 node_modules 里只有 @yezack/dsh-remote-mobile，
// 旧名字解析不到，插件就 failed to import 并静默停用。这里按 package.json 的
// 实际包名纠正，避免依赖上游发布修复。
//
// 【2】修正客户端 bundle 的模块注册 id
//
// lib/client.js 开头是 `window.__ModuleLoader__.load({ id: "<打包时的包名>" })`。
// 模块表的键是包名（client-modules/src/client/manifest.ts:101 要求 entry name
// 等于 package name），所以改名后两边失配：模块表要 @yezack/dsh-remote-mobile，
// bundle 注册的却是 dsh-remote-mobile，那个 id 永远拿不到 factory，浏览器里
// import 失败，WebUI 启动页就把 @yezack/dsh-remote-mobile 列进 "Failed to load
// plugins"。只改 id 字段，不动同一文件里作为界面文案出现的同名文本。
//
// 【3】隐藏客户端里的 "Tailscale 虚拟私网接入 (推荐)" 块
//
// 目标环境是隔离局域网，没有 Tailscale；留着这个入口会让操作员以为它可用。
// 插件没有提供隐藏开关（Config 只有 SessionStoreOptions），所以只能改它打包好的
// 客户端代码。做法是把那一个子块整体替换成 null —— 它在 JSX children 数组里，
// null 不渲染，且不影响相邻的局域网与扫码配对块。
//
// bundle 保留换行缩进，因此按正则定位而不是精确子串。锚点找不到就直接失败：
// 插件升级后布局可能变，那时宁可让构建停下，也不要让这个入口悄悄回来。
import fs from 'node:fs'
import path from 'node:path'

const appDir = process.argv[2]
if (appDir === undefined) {
  console.error('用法: patch-remote-mobile.mjs <app 目录>')
  process.exit(1)
}

const packageDir = path.join(appDir, 'node_modules', '@yezack', 'dsh-remote-mobile')
const manifestPath = path.join(packageDir, 'package.json')
if (!fs.existsSync(manifestPath)) {
  console.error(`[patch-remote-mobile] 未找到 ${manifestPath}`)
  process.exit(1)
}
const packageName = JSON.parse(fs.readFileSync(manifestPath, 'utf8')).name

// 【1】row name 必须等于包名。
const patchPath = path.join(packageDir, 'cordis.patch.yml')
if (!fs.existsSync(patchPath)) {
  console.error(`[patch-remote-mobile] 未找到 ${patchPath}`)
  process.exit(1)
}
const patchSource = fs.readFileSync(patchPath, 'utf8')
const nameMatch = /^(\s*name:\s*)'([^']+)'\s*$/mu.exec(patchSource)
if (nameMatch === null) {
  console.error('[patch-remote-mobile] cordis.patch.yml 里找不到 name 行，拒绝猜测')
  process.exit(1)
}
if (nameMatch[2] !== packageName) {
  fs.writeFileSync(patchPath, patchSource.replace(nameMatch[0], `${nameMatch[1]}'${packageName}'`))
  console.log(`[patch-remote-mobile] row name: '${nameMatch[2]}' -> '${packageName}'`)
} else {
  console.log(`[patch-remote-mobile] row name 已与包名一致（${packageName}）`)
}

const file = path.join(packageDir, 'lib', 'client.js')
if (!fs.existsSync(file)) {
  console.error(`[patch-remote-mobile] 未找到 ${file}`)
  process.exit(1)
}

const source = fs.readFileSync(file, 'utf8')

// 【2】客户端模块注册 id 必须等于包名。
const idPattern = /(__ModuleLoader__\.load\(\{\s*\n\s*id:\s*)"([^"]+)"/
const idMatch = idPattern.exec(source)
if (idMatch === null) {
  console.error('[patch-remote-mobile] client.js 里找不到 __ModuleLoader__.load 的 id，拒绝猜测')
  process.exit(1)
}
if (idMatch[2] !== packageName) {
  fs.writeFileSync(file, source.replace(idPattern, `$1"${packageName}"`))
  console.log(`[patch-remote-mobile] client bundle id: "${idMatch[2]}" -> "${packageName}"`)
} else {
  console.log(`[patch-remote-mobile] client bundle id 已与包名一致（${packageName}）`)
}

const patched = fs.readFileSync(file, 'utf8')

if (patched.includes('__DSH_TAILSCALE_HIDDEN__')) {
  console.log('[patch-remote-mobile] 已打过 Tailscale 补丁，跳过')
  process.exit(0)
}

// 该块外层 style 的唯一特征：底部分隔线 + 列布局。
const anchor = /paddingBottom:\s*"16px",\s*borderBottom:\s*"1px solid var\(--dsw-alias-border-l2/
const found = anchor.exec(patched)
if (found === null) {
  console.error('[patch-remote-mobile] 未找到 Tailscale 块的锚点；客户端 bundle 结构已变化，拒绝静默跳过')
  process.exit(1)
}

// 向前找这次 jsxs 调用的起点。
const call = '/* @__PURE__ */ (0, import_jsx_runtime.jsxs)('
const callAt = patched.lastIndexOf(call, found.index)
if (callAt === -1) {
  console.error('[patch-remote-mobile] 未找到 Tailscale 块所在调用的起点')
  process.exit(1)
}

// 从参数表左括号开始配对，跳过字符串、模板与注释。
const open = callAt + call.length - 1
let depth = 0
let index = open
let end = -1
let quote = ''
let escaped = false
while (index < patched.length) {
  const char = patched[index]
  if (quote !== '') {
    if (escaped) escaped = false
    else if (char === '\\') escaped = true
    else if (char === quote) quote = ''
    index += 1
    continue
  }
  if (char === '"' || char === "'" || char === '`') {
    quote = char
    index += 1
    continue
  }
  if (char === '/' && patched[index + 1] === '*') {
    const close = patched.indexOf('*/', index + 2)
    index = close === -1 ? patched.length : close + 2
    continue
  }
  if (char === '/' && patched[index + 1] === '/') {
    const close = patched.indexOf('\n', index + 2)
    index = close === -1 ? patched.length : close + 1
    continue
  }
  if (char === '(') depth += 1
  else if (char === ')') {
    depth -= 1
    if (depth === 0) {
      end = index
      break
    }
  }
  index += 1
}

if (end === -1 || patched[end] !== ')') {
  console.error('[patch-remote-mobile] Tailscale 块的括号未配平，拒绝改写')
  process.exit(1)
}

const block = patched.slice(callAt, end + 1)
// 只替换确实是 Tailscale 那一块的位置，避免锚点漂移后改错东西。
for (const marker of ['tailscaleSectionTitle', 'tailscaleIp']) {
  if (!block.includes(marker)) {
    console.error(`[patch-remote-mobile] 目标块不含 ${marker}，拒绝改写`)
    process.exit(1)
  }
}
for (const marker of ['netCardTitle', 'lanIp', 'generate-code']) {
  if (block.includes(marker)) {
    console.error(`[patch-remote-mobile] 目标块含 ${marker}，范围过大，拒绝改写`)
    process.exit(1)
  }
}

// 标记留在文件里，供重复执行与事后核对。
const hidden = patched.slice(0, callAt) + 'null /* __DSH_TAILSCALE_HIDDEN__ */' + patched.slice(end + 1)
fs.writeFileSync(file, hidden)
console.log(`[patch-remote-mobile] 已隐藏 Tailscale 块（${end - callAt + 1} 字符）
  ${path.relative(appDir, file)}`)
