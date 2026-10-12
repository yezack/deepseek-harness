/**
 * Verify the JavaScript half of the compat script without a browser.
 *
 * Node already provides every API the script polyfills, so the test deletes
 * them first, evaluates the script, and asserts each shim behaves. The CSS half
 * returns early without a `CSS` object, which is exactly the Node environment.
 *
 * Run: node deploy/tools/test-compat.mjs   (from the repository root)
 */
import { compatScript } from '../../packages/host/web-compat/src/compat-script.ts'

const failures = []
let checks = 0

function check(label, condition, detail) {
  checks += 1
  if (condition) {
    console.log('  PASS  ' + label)
  } else {
    failures.push(label + (detail === undefined ? '' : ' -> ' + detail))
    console.log('  FAIL  ' + label + (detail === undefined ? '' : ' -> ' + detail))
  }
}

function remove(target, name) {
  const saved = Object.getOwnPropertyDescriptor(target, name)
  try { delete target[name] } catch (error) { void error }
  return saved
}

const restores = []
function strip(target, name) {
  const saved = remove(target, name)
  if (saved !== undefined) restores.push(() => Object.defineProperty(target, name, saved))
}

function restoreAll() {
  for (const restore of restores.reverse()) restore()
}

/* ---- remove every API the script installs ---- */
strip(Promise, 'withResolvers')
strip(AbortSignal, 'any')
strip(AbortSignal, 'timeout')
strip(globalThis, 'structuredClone')
strip(Object, 'hasOwn')
strip(Object, 'groupBy')
strip(Map, 'groupBy')
for (const name of ['at', 'toSorted', 'toReversed', 'toSpliced', 'with']) strip(Array.prototype, name)
strip(Array, 'fromAsync')
strip(String.prototype, 'replaceAll')
strip(String.prototype, 'isWellFormed')
strip(Set.prototype, 'union')
strip(Set.prototype, 'intersection')
strip(Set.prototype, 'difference')
strip(Set.prototype, 'symmetricDifference')
strip(Set.prototype, 'isSubsetOf')
strip(Set.prototype, 'isSupersetOf')
strip(Set.prototype, 'isDisjointFrom')
strip(globalThis, 'Iterator')

console.log('=== 环境确认：这些 API 已被删除 ===')
check('Promise.withResolvers 缺失', typeof Promise.withResolvers !== 'function')
check('AbortSignal.any 缺失', typeof AbortSignal.any !== 'function')
check('structuredClone 缺失', typeof globalThis.structuredClone !== 'function')
check('Iterator 缺失', typeof globalThis.Iterator === 'undefined')

/* ---- evaluate the shipped script ---- */
const source = compatScript()
check('脚本是非空字符串', typeof source === 'string' && source.length > 1000, '长度 ' + String(source.length))
console.log('=== 注入并执行脚本（' + source.length + ' 字节）===')
try {
  new Function(source)()
} catch (error) {
  console.log('  FAIL  脚本抛异常: ' + String(error))
  restoreAll()
  process.exit(1)
}
check('脚本无异常执行完毕', true)
check('写入幂等标记', globalThis.__DSH_WEB_COMPAT__ === true)

/* ---- assert each shim ---- */
console.log('=== 逐项断言 ===')

const deferred = Promise.withResolvers()
check('Promise.withResolvers 返回三元组', typeof deferred.resolve === 'function' && typeof deferred.reject === 'function' && deferred.promise instanceof Promise)
deferred.resolve(42)
check('Promise.withResolvers 可 resolve', (await deferred.promise) === 42)

const controllerA = new AbortController()
const controllerB = new AbortController()
const combined = AbortSignal.any([controllerA.signal, controllerB.signal])
check('AbortSignal.any 返回信号', combined instanceof AbortSignal)
check('AbortSignal.any 初始未中止', combined.aborted === false)
controllerA.abort()
check('AbortSignal.any 随源中止', combined.aborted === true)

const timeoutSignal = AbortSignal.timeout(10)
check('AbortSignal.timeout 返回信号', timeoutSignal instanceof AbortSignal)

const cyclic = { name: 'root', map: new Map([['k', new Date(0)]]), set: new Set([1, 2]) }
cyclic.self = cyclic
const cloned = globalThis.structuredClone(cyclic)
check('structuredClone 保留 Map', cloned.map instanceof Map && cloned.map.get('k') instanceof Date)
check('structuredClone 保留 Set', cloned.set instanceof Set && cloned.set.size === 2)
check('structuredClone 处理循环引用', cloned.self === cloned)
check('structuredClone 不共享引用', cloned !== cyclic)
const buffer = new Uint8Array([1, 2, 3])
const clonedBuffer = globalThis.structuredClone(buffer)
check('structuredClone 复制 TypedArray', clonedBuffer instanceof Uint8Array && clonedBuffer[0] === 1 && clonedBuffer.buffer !== buffer.buffer)

check('Object.hasOwn 真值', Object.hasOwn({ a: 1 }, 'a') === true)
check('Object.hasOwn 继承为假', Object.hasOwn({}, 'toString') === false)

const grouped = Object.groupBy([1, 2, 3, 4], value => (value % 2 === 0 ? 'even' : 'odd'))
check('Object.groupBy 分组', grouped.odd.length === 2 && grouped.even.length === 2)
const mapGrouped = Map.groupBy([1, 2, 3], value => (value === 2 ? 'two' : 'other'))
check('Map.groupBy 分组', mapGrouped.get('two').length === 1 && mapGrouped.get('other').length === 2)

check('Array.prototype.at 负数', [1, 2, 3].at(-1) === 3)
const unsorted = [3, 1, 2]
check('toSorted 不改原数组', unsorted.toSorted((a, b) => a - b).join(',') === '1,2,3' && unsorted.join(',') === '3,1,2')
check('toReversed', [1, 2, 3].toReversed().join(',') === '3,2,1')
check('toSpliced 删除', [1, 2, 3].toSpliced(1, 1).join(',') === '1,3')
check('toSpliced 插入', [1, 2, 3].toSpliced(1, 0, 9).join(',') === '1,9,2,3')
check('toSpliced 单参数截断', [1, 2, 3].toSpliced(1).join(',') === '1')
check('with 替换', [1, 2, 3].with(-1, 9).join(',') === '1,2,9')
let withThrew = false
try { [1, 2, 3].with(9, 0) } catch (error) { withThrew = error instanceof RangeError }
check('with 越界抛 RangeError', withThrew)

const fromAsync = await Array.fromAsync([1, 2, 3], async value => value * 2)
check('Array.fromAsync 映射', fromAsync.join(',') === '2,4,6')

check('replaceAll 字符串', 'a-b-c'.replaceAll('-', '+') === 'a+b+c')
check('replaceAll 正则', 'a1b2'.replaceAll(/\d/g, '#') === 'a#b#')

const setA = new Set([1, 2, 3])
const setB = new Set([3, 4])
check('Set.union', [...setA.union(setB)].sort().join(',') === '1,2,3,4')
check('Set.intersection', [...setA.intersection(setB)].join(',') === '3')
check('Set.difference', [...setA.difference(setB)].sort().join(',') === '1,2')
check('Set.symmetricDifference', [...setA.symmetricDifference(setB)].sort().join(',') === '1,2,4')
check('Set.isSubsetOf', new Set([1]).isSubsetOf(setA) === true && setA.isSubsetOf(new Set([1])) === false)
check('Set.isSupersetOf', setA.isSupersetOf(new Set([1])) === true)
check('Set.isDisjointFrom', setA.isDisjointFrom(new Set([9])) === true && setA.isDisjointFrom(setB) === false)

/* ---- Iterator: the structure matters, not just the name ---- */
const iteratorPrototype = Object.getPrototypeOf(Object.getPrototypeOf([][Symbol.iterator]()))
check('Iterator 是构造函数', typeof globalThis.Iterator === 'function')
check('Iterator.prototype IS %IteratorPrototype%', globalThis.Iterator.prototype === iteratorPrototype)
check('Iterator.from 可用', typeof globalThis.Iterator.from === 'function')
const collected = globalThis.Iterator.from([1, 2, 3, 4]).filter(value => value % 2 === 0).map(value => value * 10).toArray()
check('Iterator 链式 filter+map+toArray', collected.join(',') === '20,40')
check('Iterator.take', globalThis.Iterator.from([1, 2, 3, 4]).take(2).toArray().join(',') === '1,2')
check('Iterator.drop', globalThis.Iterator.from([1, 2, 3, 4]).drop(2).toArray().join(',') === '3,4')
check('Iterator.flatMap', globalThis.Iterator.from([1, 2]).flatMap(value => [value, value]).toArray().join(',') === '1,1,2,2')
check('Iterator.reduce', globalThis.Iterator.from([1, 2, 3]).reduce((sum, value) => sum + value, 0) === 6)
check('Iterator.some', globalThis.Iterator.from([1, 2]).some(value => value === 2) === true)
check('Iterator.every', globalThis.Iterator.from([1, 2]).every(value => value > 0) === true)
check('Iterator.find', globalThis.Iterator.from([1, 2, 3]).find(value => value > 1) === 2)
check('Iterator 结果继承 %IteratorPrototype%', iteratorPrototype.isPrototypeOf(globalThis.Iterator.from([1]).map(value => value)))
const patched = iteratorPrototype
patched.__probe__ = 1
check('可直接 patch Iterator.prototype', globalThis.Iterator.from([1]).__probe__ === 1)
delete patched.__probe__

/* ---- idempotence ---- */
console.log('=== 幂等性 ===')
const twice = new Function(source)()
void twice
check('二次执行不抛异常', true)
check('二次执行后用原生优先（标记仍在）', globalThis.__DSH_WEB_COMPAT__ === true)

restoreAll()

console.log('')
console.log('=== 结果: ' + (checks - failures.length) + '/' + checks + ' 通过 ===')
if (failures.length > 0) {
  console.log('失败项:')
  for (const failure of failures) console.log('  - ' + failure)
  process.exit(1)
}
