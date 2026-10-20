/**
 * Verify the host half: the plugin claims one index tap and the tap places the
 * compat script ahead of every already-rendered injection row.
 *
 * The ordering is the whole point — the boot tail and the parser-blocking
 * bootstrap bundles must find the polyfills already installed — so this test
 * renders a document shaped like the real one and asserts position, not merely
 * presence.
 *
 * Run: node deploy/tools/test-injection.mjs   (from the repository root, after a build)
 */
import { apply, name, inject } from '../../packages/host/web-compat/lib/index.js'

let checks = 0
const failures = []
function check(label, condition, detail) {
  checks += 1
  if (condition) console.log('  PASS  ' + label)
  else { failures.push(label); console.log('  FAIL  ' + label + (detail === undefined ? '' : ' -> ' + detail)) }
}

console.log('=== 插件接口 ===')
check('name 为 web-compat', name === 'web-compat', String(name))
check('inject 声明 webServer', Array.isArray(inject) && inject.includes('webServer'), JSON.stringify(inject))

const taps = []
let effectUsed = 0
const ctx = {
  webServer: {
    tapIndex(transform) {
      taps.push(transform)
      return () => { taps.length = 0 }
    },
  },
  effect(factory) { effectUsed += 1; return factory() },
}

apply(ctx)
check('通过 ctx.effect 注册（注册即 effect）', effectUsed === 1, '调用 ' + effectUsed + ' 次')
check('恰好声明一个 index tap', taps.length === 1, '数量 ' + taps.length)

/* A document shaped like the served one: structured head rows already spliced
after <head>, the boot tail at the end of body. */
const rendered = '<!doctype html><html lang="en"><head><script>HEAD_ROW_BOOTSTRAP</script>'
  + '<link rel="stylesheet" href="./assets/index.css"></head><body>'
  + '<div id="root"></div>'
  + '<script>(globalThis.__DSH_BOOT_READY__ ??= Promise.withResolvers()).resolve()</script>'
  + '</body></html>'

const out = taps[0](rendered)
const compatAt = out.indexOf('data-dsh-web-compat')
const headRowAt = out.indexOf('HEAD_ROW_BOOTSTRAP')
const bootTailAt = out.indexOf('__DSH_BOOT_READY__')
const headCloseAt = out.indexOf('</head>')

console.log('=== 注入位置 ===')
check('兼容脚本已注入', compatAt !== -1)
check('位于 <head> 之内', compatAt !== -1 && compatAt < headCloseAt)
check('早于其他 head 注入行', compatAt !== -1 && headRowAt !== -1 && compatAt < headRowAt,
  'compat@' + compatAt + ' row@' + headRowAt)
check('早于 boot 尾脚本', compatAt !== -1 && bootTailAt !== -1 && compatAt < bootTailAt)
check('早于样式表', compatAt !== -1 && compatAt < out.indexOf('index.css'))

console.log('=== 注入内容 ===')
const script = out.slice(compatAt, out.indexOf('</script>', compatAt))
check('带标记属性', out.includes('<script data-dsh-web-compat>'))
check('含 Promise.withResolvers 兜底', script.includes("define(Promise, 'withResolvers'"))
check('含 Iterator 兜底', script.includes('installIterator'))
check('含 color-mix 兜底', script.includes('installColorMixFallback'))
check('含 CSS 支持探测', script.includes("CSS.supports('color', 'color-mix(in srgb, red, blue)')"))
check('含变异观察器（捕捉运行时注入的 <style>）', script.includes('MutationObserver'))

/* The element must not close itself early: a single stray </script inside the
   text would end the element and silently drop every polyfill that follows. */
const body = script.slice(script.indexOf('>') + 1)
check('不含 </script（不会提前闭合元素）', !body.toLowerCase().includes('</script'))
let parses = true
try { new Function(body) } catch (error) { parses = false }
check('脚本可独立解析为完整程序', parses)

console.log('=== 无 <head> 的退化路径 ===')
const fragment = taps[0]('<main>x</main>')
check('文档片段前置注入', fragment.startsWith('<script data-dsh-web-compat>'))

console.log('')
console.log('=== 结果: ' + (checks - failures.length) + '/' + checks + ' 通过 ===')
if (failures.length > 0) {
  for (const failure of failures) console.log('  - ' + failure)
  process.exit(1)
}
