// 出包前的版本闸门回归：按 DSH 真实的兼容判定，检查 12 个预装插件是否都能被
// 当前 dsh 版本接受。判定逻辑与 dsh-app-boot 一致：
//   - 有 engines.dsh → 只按它判（includePrerelease 开启）
//   - 否则只校验 @deepseek-ai/dsh* 的 peer 声明
// npm 的 strict peer 检查会把 rc 版本报成假阳性，不能用它代替。
//
// 用法: node verify-plugins.mjs <app 目录> [seed-profile.sh]
import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'

const appDir = path.resolve(process.argv[2] ?? 'app')
const seedFile = path.resolve(process.argv[3] ?? path.join(path.dirname(appDir), 'seed-profile.sh'))
const require = createRequire(import.meta.url)

const dshPkgPath = path.join(appDir, 'node_modules', '@deepseek-ai', 'dsh', 'package.json')
if (!fs.existsSync(dshPkgPath)) {
  console.error(`[verify-plugins] 找不到 ${dshPkgPath}`)
  process.exit(1)
}
const dshVersion = JSON.parse(fs.readFileSync(dshPkgPath, 'utf8')).version

let semver
try {
  semver = require(path.join(appDir, 'node_modules', 'semver'))
} catch (error) {
  console.error(`[verify-plugins] 无法加载 app 内的 semver: ${error.message}`)
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

let failed = 0
const rows = []
for (const item of plugins) {
  const name = item.includes('@', 1) ? item.slice(0, item.lastIndexOf('@')) : item
  const want = item.slice(item.lastIndexOf('@') + 1)
  const manifestPath = path.join(appDir, 'node_modules', name, 'package.json')
  if (!fs.existsSync(manifestPath)) {
    rows.push(`  MISS ${name}（期望 ${want}，未安装）`)
    failed += 1
    continue
  }
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'))
  const result = judge(manifest)
  const versionNote = manifest.version === want ? '版本一致' : `版本 ${manifest.version} ≠ 清单 ${want}`
  if (manifest.version !== want) failed += 1
  if (!result.ok) {
    failed += 1
    rows.push(`  FAIL ${name}@${manifest.version}（${versionNote}）判定: ${result.basis}`)
  } else {
    rows.push(`  PASS ${name}@${manifest.version}（${versionNote}）判定: ${result.basis}`)
  }
}

console.log(`[verify-plugins] dsh ${dshVersion}，检查 ${plugins.length} 个预装插件`)
for (const row of rows) console.log(row)
if (failed > 0) {
  console.error(`[verify-plugins] ${failed} 项不通过，拒绝出包`)
  process.exit(1)
}
console.log('[verify-plugins] 全部通过')
