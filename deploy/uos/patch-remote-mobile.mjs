// 从 dsh-remote-mobile 的客户端 bundle 里隐藏 "Tailscale 虚拟私网接入 (推荐)" 这一块。
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

const file = path.join(appDir, 'node_modules', 'dsh-remote-mobile', 'lib', 'client.js')
if (!fs.existsSync(file)) {
  console.error(`[patch-remote-mobile] 未找到 ${file}`)
  process.exit(1)
}

const source = fs.readFileSync(file, 'utf8')

if (source.includes('__DSH_TAILSCALE_HIDDEN__')) {
  console.log('[patch-remote-mobile] 已打过补丁，跳过')
  process.exit(0)
}

// 该块外层 style 的唯一特征：底部分隔线 + 列布局。
const anchor = /paddingBottom:\s*"16px",\s*borderBottom:\s*"1px solid var\(--dsw-alias-border-l2/
const found = anchor.exec(source)
if (found === null) {
  console.error('[patch-remote-mobile] 未找到 Tailscale 块的锚点；客户端 bundle 结构已变化，拒绝静默跳过')
  process.exit(1)
}

// 向前找这次 jsxs 调用的起点。
const call = '/* @__PURE__ */ (0, import_jsx_runtime.jsxs)('
const callAt = source.lastIndexOf(call, found.index)
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
while (index < source.length) {
  const char = source[index]
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
  if (char === '/' && source[index + 1] === '*') {
    const close = source.indexOf('*/', index + 2)
    index = close === -1 ? source.length : close + 2
    continue
  }
  if (char === '/' && source[index + 1] === '/') {
    const close = source.indexOf('\n', index + 2)
    index = close === -1 ? source.length : close + 1
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

if (end === -1 || source[end] !== ')') {
  console.error('[patch-remote-mobile] Tailscale 块的括号未配平，拒绝改写')
  process.exit(1)
}

const block = source.slice(callAt, end + 1)
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
const patched = source.slice(0, callAt) + 'null /* __DSH_TAILSCALE_HIDDEN__ */' + source.slice(end + 1)
fs.writeFileSync(file, patched)
console.log(`[patch-remote-mobile] 已隐藏 Tailscale 块（${end - callAt + 1} 字符）
  ${path.relative(appDir, file)}`)
