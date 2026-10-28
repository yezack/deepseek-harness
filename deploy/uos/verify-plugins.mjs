// 出包前的组件闸门：本体树 + 每个插件自包含树。
//
// 检查项：
//   1. 版本闸门：每个插件都被当前 dsh 版本接受（engines.dsh 优先，否则校验
//      @deepseek-ai/dsh* 的 peer 范围）。判定与 dsh-app-boot 一致。
//   2. 自包含：插件自己的依赖必须嵌套在插件包的 node_modules 里（nested 布局），
//      否则装到目标机后依赖会去插件目录之外找，独立安装就不成立。
//   3. 不复制宿主包：插件树里不能出现 @deepseek-ai/* 的实体副本（安装时只放软链）。
//   4. 服务端导入的每个 @deepseek-ai/* 都必须能在本体树里找到。
//   5. 客户端入口：声明 dsh.client.platform=web 时 exports["./client"] 必须存在
//      （客户端 bundle 里的 @deepseek-ai/* 由浏览器 platform 模块提供，不按 node 判定）。
//
// 用法: node verify-plugins.mjs <build-dir> [extras.json] [components.json]
import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'

const buildDir = path.resolve(process.argv[2] ?? '.')
const appDir = path.join(buildDir, 'app')
const appModules = path.join(appDir, 'node_modules')
const pluginsBuild = path.join(buildDir, 'plugins-build')
const extrasFile = path.resolve(process.argv[3] ?? path.join(buildDir, 'extras.json'))
const require = createRequire(import.meta.url)

if (!fs.existsSync(path.join(appModules, '@deepseek-ai', 'dsh', 'package.json'))) {
  console.error(`[verify-plugins] 找不到本体 ${appDir}`)
  process.exit(1)
}
const dshVersion = JSON.parse(fs.readFileSync(path.join(appModules, '@deepseek-ai', 'dsh', 'package.json'), 'utf8')).version
let semver
try { semver = require(path.join(appModules, 'semver')) } catch (error) {
  console.error(`[verify-plugins] 无法加载本体树里的 semver: ${error.message}`)
  process.exit(1)
}

const extras = JSON.parse(fs.readFileSync(extrasFile, 'utf8')).filter((entry) => !entry.override)
const DSH_PEER = /^@deepseek-ai\/dsh($|[-/])/u

function judge(manifest) {
  const enginesDsh = manifest.engines?.dsh
  if (typeof enginesDsh === 'string' && enginesDsh.trim() !== '') {
    return { ok: semver.satisfies(dshVersion, enginesDsh, { includePrerelease: true }), basis: `engines.dsh ${enginesDsh}` }
  }
  const peers = manifest.peerDependencies ?? {}
  const entries = Object.entries(peers).filter(([name]) => DSH_PEER.test(name))
  if (entries.length === 0) return { ok: true, basis: '无 dsh 版本声明（按 DSH 规则放行）' }
  const failures = entries.filter(([name, range]) => !semver.satisfies(dshVersion, range, { includePrerelease: true }))
  return {
    ok: failures.length === 0,
    basis: entries.map(([name, range]) => `${name} ${range}`).join(' / '),
  }
}

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

function isClientBundle(file, packageRoot) {
  const rel = path.relative(packageRoot, file).split(path.sep)
  return rel.some((segment) => /^client(?:[.-]|$)/iu.test(segment))
}

const AI_IMPORT = /(?:\bfrom\s*|\brequire\s*\(\s*|\bimport\s*\(\s*)(['"])@deepseek-ai\/([A-Za-z0-9._-]+)/gu
// 构建树目录名 = 包名的 '@' 与 '/' 都换成 '_'（与 materialize-uos.sh 的 tr 一致）。
const slugOf = (name) => name.replaceAll('@', '_').replaceAll('/', '_')

let failed = 0
const rows = []
for (const entry of extras) {
  const name = entry.name
  const version = entry.version
  const treeRoot = path.join(pluginsBuild, slugOf(name))
  const packageRoot = path.join(treeRoot, 'node_modules', name)
  if (!fs.existsSync(path.join(packageRoot, 'package.json'))) {
    rows.push(`  MISS ${name}（期望 ${version}，未物化）`)
    failed += 1
    continue
  }
  const manifest = JSON.parse(fs.readFileSync(path.join(packageRoot, 'package.json'), 'utf8'))
  const result = judge(manifest)
  const problems = []
  if (!result.ok) problems.push(`兼容判定: ${result.basis}`)
  if (version !== undefined && manifest.version !== version) problems.push(`版本 ${manifest.version} ≠ 清单 ${version}`)

  // 2. 自包含：依赖必须嵌套在插件包里
  if (!fs.existsSync(path.join(packageRoot, 'node_modules'))) problems.push('依赖未嵌套（插件包内没有 node_modules）')

  // 3. 宿主包副本：插件包里（嵌套 node_modules）不能有宿主包实体。
  //    例外：@deepseek-ai/schemastery 是无状态校验库，多个插件自带一份是允许的。
  const HOST_SCOPE = '@deepseek-ai'
  const ALLOWED_HOST_DEP = '@deepseek-ai/schemastery'
  const duplicated = []
  const nestedModules = path.join(packageRoot, 'node_modules')
  const nestedScope = path.join(nestedModules, HOST_SCOPE)
  if (fs.existsSync(nestedScope)) {
    for (const sibling of fs.readdirSync(nestedScope)) {
      const dep = `${HOST_SCOPE}/${sibling}`
      if (dep !== ALLOWED_HOST_DEP) duplicated.push(dep)
    }
  }
  if (duplicated.length > 0) problems.push(`插件树里有宿主包副本: ${duplicated.join(', ')}`)

  // 4/5. 导入覆盖 + 客户端入口
  const serverImports = new Set()
  const clientImports = new Set()
  for (const file of jsFiles(packageRoot)) {
    const target = isClientBundle(file, packageRoot) ? clientImports : serverImports
    const text = fs.readFileSync(file, 'utf8')
    for (const match of text.matchAll(AI_IMPORT)) target.add(`@deepseek-ai/${match[2]}`)
  }
  const hasHost = (dep) => fs.existsSync(path.join(appModules, dep, 'package.json'))
  const unresolved = [...serverImports].filter((dep) => !hasHost(dep))
  if (unresolved.length > 0) problems.push(`服务端导入的宿主包不在本体树: ${unresolved.join(', ')}`)
  const clientOnly = [...clientImports].filter((dep) => !hasHost(dep) && !serverImports.has(dep))

  const clientEntry = manifest.exports?.['./client']
  if (manifest.dsh?.client?.platform === 'web') {
    if (clientEntry === undefined) problems.push('声明了 web 客户端但缺 exports["./client"]')
    else if (typeof clientEntry === 'string' && !fs.existsSync(path.join(packageRoot, clientEntry))) {
      problems.push(`客户端入口不存在: ${clientEntry}`)
    }
  }

  if (problems.length > 0) failed += 1
  rows.push(`  ${problems.length === 0 ? 'PASS' : 'FAIL'} ${name}@${manifest.version}（依赖 ${countDeps(packageRoot)} 个）判定: ${result.basis}`)
  for (const problem of problems) rows.push(`       - ${problem}`)
  if (clientOnly.length > 0) rows.push(`       · 客户端 bundle 依赖浏览器 platform 模块: ${clientOnly.join(', ')}`)
}

function countDeps(packageRoot) {
  try { return fs.readdirSync(path.join(packageRoot, 'node_modules')).filter((name) => !name.startsWith('.')).length } catch { return 0 }
}

console.log(`[verify-plugins] dsh ${dshVersion}，检查 ${extras.length} 个插件组件树`)
for (const row of rows) console.log(row)
if (failed > 0) {
  console.error(`[verify-plugins] ${failed} 项不通过，拒绝出包`)
  process.exit(1)
}
console.log('[verify-plugins] 全部通过')
