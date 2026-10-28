// 出包前的版本闸门回归 + 拆树后的依赖自检。
//
// 两棵树：
//   <build>/app          本体（dsh 官方包 + 依赖）
//   <build>/plugins-app  插件（第三方插件 + 它们自己的依赖）
//
// 检查项：
//   1. 版本闸门：按 dsh 真实的兼容判定，检查 seed-profile.sh 的 BUNDLES 清单里每个
//      插件都被当前 dsh 版本接受。判定逻辑与 dsh-app-boot 一致：
//        - 有 engines.dsh → 只按它判（includePrerelease 开启）
//        - 否则只校验 @deepseek-ai/dsh* 的 peer 声明
//      npm 的 strict peer 检查会把 rc 版本报成假阳性，不能用它代替。
//   2. 插件树里不得出现本体包副本：@deepseek-ai/* 必须由本体那一份提供（插件把它
//      们声明为 peer），否则 dsh-tools 这类带 unique symbol 的包会出现第二个实例。
//   3. 插件代码里 import 的每个 @deepseek-ai/* 都必须能在本体树里找到（安装期
//      会把 @deepseek-ai 软链进插件树），否则运行时会静默少插件。
//   4. 客户端插件声明 dsh.client.platform=web 时，exports["./client"] 必须指向存在的文件。
//
// 用法: node verify-plugins.mjs <build-dir> [seed-profile.sh]
import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'

const buildDir = path.resolve(process.argv[2] ?? '.')
const appDir = path.join(buildDir, 'app')
const pluginsDir = path.join(buildDir, 'plugins-app')
const seedFile = path.resolve(process.argv[3] ?? path.join(buildDir, 'seed-profile.sh'))
const require = createRequire(import.meta.url)

const appModules = path.join(appDir, 'node_modules')
const pluginModules = path.join(pluginsDir, 'node_modules')

const dshPkgPath = path.join(appModules, '@deepseek-ai', 'dsh', 'package.json')
if (!fs.existsSync(dshPkgPath)) {
  console.error(`[verify-plugins] 找不到本体 ${dshPkgPath}`)
  process.exit(1)
}
if (!fs.existsSync(pluginModules)) {
  console.error(`[verify-plugins] 找不到插件树 ${pluginModules}`)
  process.exit(1)
}
const dshVersion = JSON.parse(fs.readFileSync(dshPkgPath, 'utf8')).version

let semver
try {
  semver = require(path.join(appModules, 'semver'))
} catch (error) {
  console.error(`[verify-plugins] 无法加载本体树里的 semver: ${error.message}`)
  process.exit(1)
}

const seedText = fs.readFileSync(seedFile, 'utf8')
const bundlesLine = /^BUNDLES="([^"]*)"/mu.exec(seedText)
if (bundlesLine === null) {
  console.error(`[verify-plugins] ${seedFile} 里没有 BUNDLES= 清单`)
  process.exit(1)
}
const plugins = bundlesLine[1].split(/\s+/u).filter(Boolean)

const DSH_PEER = /^@deepseek-ai\/dsh($|[-/])/u

function judge(manifest) {
  const enginesDsh = manifest.engines?.dsh
  if (typeof enginesDsh === 'string' && enginesDsh.trim() !== '') {
    const ok = semver.satisfies(dshVersion, enginesDsh, { includePrerelease: true })
    return { ok, basis: `engines.dsh ${enginesDsh}` }
  }
  const peers = manifest.peerDependencies ?? {}
  const entries = Object.entries(peers).filter(([name]) => DSH_PEER.test(name))
  if (entries.length === 0) {
    return { ok: true, basis: '无 dsh 版本声明（按 DSH 规则放行）' }
  }
  const failures = entries.filter(([name, range]) => !semver.satisfies(dshVersion, range, { includePrerelease: true }))
  return {
    ok: failures.length === 0,
    basis: entries.map(([name, range]) => `${name} ${range}`).join(' / '),
  }
}

/** 递归收集包内 JS 文件（跳过依赖目录）。 */
function jsFiles(dir, out = []) {
  let entries
  try { entries = fs.readdirSync(dir, { withFileTypes: true }) } catch { return out }
  for (const entry of entries) {
    if (entry.name === 'node_modules' || entry.name.startsWith('.')) continue
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) jsFiles(full, out)
    else if (/\.(?:js|cjs|mjs)$/u.test(entry.name)) out.push(full)
  }
  return out
}

/**
 * 客户端 bundle 里的 @deepseek-ai/* 由浏览器侧的 platform 模块表提供
 * （packages/client/web/src/platform.ts 的 PLATFORM_MODULES），不走 Node 解析，
 * 所以不能用本体树里有没有物理包来判定。按路径判断：客户端入口本身，以及
 * `client.js` / `client/` 这类客户端产物。
 * @param {string} file 绝对路径
 * @param {string} packageRoot 插件包目录
 */
function isClientBundle(file, packageRoot) {
  const rel = path.relative(packageRoot, file).split(path.sep)
  return rel.some((segment) => /^client(?:[.-]|$)/iu.test(segment))
}

// 插件代码里 import 的 @deepseek-ai/* 包名（含子路径）。
const AI_IMPORT = /(?:\bfrom\s*|\brequire\s*\(\s*|\bimport\s*\(\s*)(['"])@deepseek-ai\/([A-Za-z0-9._-]+)/gu

let failed = 0
const rows = []

for (const item of plugins) {
  const name = item.includes('@', 1) ? item.slice(0, item.lastIndexOf('@')) : item
  const want = item.slice(item.lastIndexOf('@') + 1)
  const manifestPath = path.join(pluginModules, name, 'package.json')
  if (!fs.existsSync(manifestPath)) {
    rows.push(`  MISS ${name}（期望 ${want}，未安装）`)
    failed += 1
    continue
  }
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'))
  const result = judge(manifest)
  const versionNote = manifest.version === want ? '版本一致' : `版本 ${manifest.version} ≠ 清单 ${want}`
  if (manifest.version !== want) failed += 1
  if (!result.ok) failed += 1

  // 2. 本体包副本
  const dup = Object.keys(manifest.dependencies ?? {}).filter((dep) => dep.startsWith('@deepseek-ai/') && dep !== '@deepseek-ai/schemastery')
  const duplicated = dup.filter((dep) => fs.existsSync(path.join(pluginModules, dep, 'package.json')))

  // 3. import 覆盖：服务端代码导入的 @deepseek-ai/* 必须在本体树里存在
  //    （安装期会在插件树里建 @deepseek-ai 软链；客户端 bundle 的导入由浏览器
  //    platform 模块表提供，单独统计，不作为出包失败条件）。
  const packageRoot = path.join(pluginModules, name)
  const serverImports = new Set()
  const clientImports = new Set()
  const peers = new Set(Object.keys(manifest.peerDependencies ?? {}))
  for (const file of jsFiles(packageRoot)) {
    const target = isClientBundle(file, packageRoot) ? clientImports : serverImports
    const text = fs.readFileSync(file, 'utf8')
    for (const match of text.matchAll(AI_IMPORT)) target.add(`@deepseek-ai/${match[2]}`)
  }
  const hasHostPackage = (dep) => fs.existsSync(path.join(appModules, dep, 'package.json'))
  const unresolved = [...serverImports].filter((dep) => !hasHostPackage(dep))
  const clientOnly = [...clientImports].filter((dep) => !hasHostPackage(dep) && !serverImports.has(dep))
  const missingPeer = [...serverImports].filter((dep) => !peers.has(dep) && hasHostPackage(dep))

  // 4. 客户端入口
  const clientPlatform = manifest.dsh?.client?.platform
  const clientEntry = manifest.exports?.['./client']
  const clientPath = typeof clientEntry === 'string'
    ? path.join(pluginModules, name, clientEntry)
    : undefined
  const clientProblems = []
  if (clientPlatform !== undefined && clientPlatform !== 'web') clientProblems.push(`dsh.client.platform=${clientPlatform}（应为 web）`)
  if (clientPlatform === 'web' && clientEntry === undefined) clientProblems.push('缺 exports["./client"]')
  if (clientPath !== undefined && !fs.existsSync(clientPath)) clientProblems.push(`客户端入口不存在: ${clientEntry}`)

  const problems = []
  if (!result.ok) problems.push(`兼容判定: ${result.basis}`)
  if (duplicated.length > 0) problems.push(`插件树里有本体包副本: ${duplicated.join(', ')}`)
  if (unresolved.length > 0) problems.push(`服务端导入的本体包不存在于本体树: ${unresolved.join(', ')}`)
  if (clientProblems.length > 0) problems.push(clientProblems.join('；'))
  if (problems.length > 0) failed += 1

  const tail = []
  if (missingPeer.length > 0) tail.push(`未声明 peer 但由本体提供 ${missingPeer.length} 个（靠 @deepseek-ai 软链兜底）`)
  if (clientOnly.length > 0) tail.push(`客户端 bundle 依赖浏览器 platform 模块 ${clientOnly.length} 个: ${clientOnly.join(', ')}`)
  rows.push(`  ${problems.length === 0 ? 'PASS' : 'FAIL'} ${name}@${manifest.version}（${versionNote}）判定: ${result.basis}`)
  if (problems.length > 0) for (const problem of problems) rows.push(`       - ${problem}`)
  if (tail.length > 0) rows.push(`       · ${tail.join('；')}`)
}

console.log(`[verify-plugins] dsh ${dshVersion}，检查 ${plugins.length} 个预装插件（本体树 + 插件树）`)
for (const row of rows) console.log(row)
if (failed > 0) {
  console.error(`[verify-plugins] ${failed} 项不通过，拒绝出包`)
  process.exit(1)
}
console.log('[verify-plugins] 全部通过')
