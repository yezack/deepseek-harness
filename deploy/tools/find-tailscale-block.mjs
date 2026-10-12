// 定位 dsh-remote-mobile 客户端 bundle 里 Tailscale 那个子块的精确边界。
// 目的是把它整块替换成 null，从而在 UI 上隐藏 —— 目标环境是隔离局域网，
// 没有 Tailscale，留着这个入口只会误导操作员。
import fs from 'node:fs'

const file = process.argv[2]
const source = fs.readFileSync(file, 'utf8')

// 该块的外层 style 是它唯一可辨认的特征：底部分隔线 + 列布局。
// bundle 保留换行缩进，所以按正则匹配而不是精确子串。
const ANCHOR = /paddingBottom:\s*"16px",\s*borderBottom:\s*"1px solid var\(--dsw-alias-border-l2/
const match = ANCHOR.exec(source)
if (match === null) {
  console.error('未找到锚点，客户端 bundle 结构已变化')
  process.exit(1)
}
const anchorAt = match.index

// 向前找这次 jsxs 调用的起点。
const CALL = '/* @__PURE__ */ (0, import_jsx_runtime.jsxs)('
const callAt = source.lastIndexOf(CALL, anchorAt)
if (callAt === -1) {
  console.error('未找到调用起点')
  process.exit(1)
}

// 从调用参数表的左括号开始做括号配对，跳过字符串/模板/注释。
const open = callAt + CALL.length - 1
let depth = 0
let index = open
let end = -1
let quote = ''
let escaped = false
while (index < source.length) {
  const ch = source[index]
  if (quote !== '') {
    if (escaped) escaped = false
    else if (ch === '\\') escaped = true
    else if (ch === quote) quote = ''
    index += 1
    continue
  }
  if (ch === '"' || ch === "'" || ch === '`') {
    quote = ch
    index += 1
    continue
  }
  if (ch === '/' && source[index + 1] === '*') {
    const close = source.indexOf('*/', index + 2)
    index = close === -1 ? source.length : close + 2
    continue
  }
  if (ch === '/' && source[index + 1] === '/') {
    const close = source.indexOf('\n', index + 2)
    index = close === -1 ? source.length : close + 1
    continue
  }
  if (ch === '(') depth += 1
  else if (ch === ')') {
    depth -= 1
    if (depth === 0) {
      end = index
      break
    }
  }
  index += 1
}

const block = source.slice(callAt, end + 1)
console.log('锚点偏移      :', anchorAt)
console.log('调用起点      :', callAt)
console.log('调用结束      :', end, `(跨度 ${end - callAt + 1} 字符)`)
console.log('含 tailscaleSectionTitle :', block.includes('tailscaleSectionTitle'))
console.log('含 tailscaleIp          :', block.includes('tailscaleIp'))
console.log('含 lanIp                :', block.includes('lanIp'))
console.log('含 generate-code        :', block.includes('generate-code'))
console.log('含 netCardTitle         :', block.includes('netCardTitle'))
console.log('以 ) 结束            :', source[end] === ')')
console.log('结束后的 90 字符      :', JSON.stringify(source.slice(end + 1, end + 91)))
console.log('起点前 90 字符        :', JSON.stringify(source.slice(callAt - 90, callAt)))
