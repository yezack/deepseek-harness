/**
 * Guard the compat template before anything imports it.
 *
 * The browser source lives in a String.raw template, so three characters are
 * structural rather than cosmetic: a backtick terminates the template, an
 * interpolated placeholder is evaluated at build time, and a script end tag
 * closes the injected element early and silently drops every polyfill after it.
 * Each has broken this file at least once, and each is invisible to a type
 * check, so it is checked here instead.
 *
 * Run: node _stage/check-template.mjs
 */
import { readFileSync } from 'node:fs'

const path = process.argv[2]
if (path === undefined) {
  console.error('usage: node check-template.mjs <compat-script.ts>')
  process.exit(2)
}

const text = readFileSync(path, 'utf8')
const opener = 'String.raw`'
const start = text.indexOf(opener)
const end = text.lastIndexOf('`')
if (start === -1 || end <= start) {
  console.error('FAIL  未找到 String.raw 模板')
  process.exit(1)
}

const inner = text.slice(start + opener.length, end)
const problems = []
if (inner.includes('`')) problems.push('模板内含反引号 —— 会提前终止模板字符串')
if (inner.includes('${')) problems.push('模板内含 ${ —— 会被当作插值在构建期求值')
if (/<\/script/i.test(inner)) problems.push('模板内含 </script —— 会提前闭合注入的 script 元素')

console.log('=== 模板静态检查 ===')
console.log('  模板长度: ' + inner.length + ' 字节')
console.log('  反引号: ' + (inner.match(/`/g) || []).length)
console.log('  ${ 出现: ' + (inner.match(/\$\{/g) || []).length)
console.log('  </script: ' + (inner.match(/<\/script/gi) || []).length)
console.log('  IIFE 开头: ' + (inner.startsWith('(function () {') ? '正常' : '异常'))

if (problems.length > 0) {
  console.log('=== 结果: FAIL ===')
  for (const problem of problems) console.log('  - ' + problem)
  process.exit(1)
}
console.log('=== 结果: PASS ===')
