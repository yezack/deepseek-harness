// 审计预装第三方插件：逐包下载 tarball，检查两类改名失配。
//
// 背景（@yezack/dsh-remote-mobile 上踩过两次）：
//   1. cordis.patch.yml 里 row 的 name 必须等于包名 —— client-modules 用
//      require.resolve('<row-name>/package.json') 解析（packages/client/modules/
//      src/index.ts:886）。
//   2. lib/client.js 里 __ModuleLoader__.load({ id }) 的 id 必须等于包名 ——
//      模块表的键就是包名（client-modules/src/client/manifest.ts:101）。
// 改名重新发布的 fork 两处都容易漏，浏览器里表现为启动页 "Failed to load plugins"。
import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'

const outDir = process.argv[2]
const specs = process.argv.slice(3)
if (!outDir || specs.length === 0) {
  console.error('用法: audit-plugins.mjs <下载目录> <name@version>...')
  process.exit(1)
}
fs.mkdirSync(outDir, { recursive: true })

/** tarball 文件名：scoped 包去掉 @scope/ 前缀。 */
function tarballName(name, version) {
  return `${name.replace(/^@[^/]+\//, '')}-${version}.tgz`
}

function fetchTarball(name, version) {
  const file = path.join(outDir, tarballName(name, version))
  if (fs.existsSync(file)) return file
  const url = `https://registry.npmjs.org/${name}/-/${tarballName(name, version)}`
  execFileSync('curl.exe', ['-sL', '-m', '180', '-o', file, url], { stdio: 'pipe' })
  return file
}

function sha1(file) {
  return execFileSync(process.execPath, ['-e', `
    const c=require('node:crypto'),f=require('node:fs');
    console.log(c.createHash('sha1').update(f.readFileSync(process.argv[1])).digest('hex'))
  `, file], { encoding: 'utf8' }).trim()
}

const rows = []
for (const spec of specs) {
  const at = spec.lastIndexOf('@')
  const name = spec.slice(0, at)
  const version = spec.slice(at + 1)
  const row = { name, version, ok: true, notes: [] }
  try {
    const file = fetchTarball(name, version)
    row.bytes = fs.statSync(file).size
    row.sha1 = sha1(file)
    const dir = path.join(outDir, `x-${name.replace(/[@/]/g, '_')}-${version}`)
    fs.rmSync(dir, { recursive: true, force: true })
    fs.mkdirSync(dir, { recursive: true })
    execFileSync('tar', ['xzf', file, '-C', dir], { stdio: 'pipe' })
    const pkgDir = path.join(dir, 'package')
    const manifest = JSON.parse(fs.readFileSync(path.join(pkgDir, 'package.json'), 'utf8'))
    row.declared = manifest.name
    row.bundle = manifest.dsh?.bundle?.patch ?? null
    row.client = Boolean(manifest.dsh?.client)

    if (manifest.name !== name) {
      row.notes.push(`package.json name 是 ${manifest.name}，不是请求的 ${name}`)
    }

    // 1. row name
    const patchPath = manifest.dsh?.bundle?.patch
      ? path.join(pkgDir, manifest.dsh.bundle.patch.replace(/^\.\//, ''))
      : null
    if (patchPath && fs.existsSync(patchPath)) {
      const patch = fs.readFileSync(patchPath, 'utf8')
      const names = [...patch.matchAll(/^\s*name:\s*'([^']+)'/gmu)].map((m) => m[1])
      row.rowNames = [...new Set(names)]
      const bad = row.rowNames.filter((n) => n !== name)
      if (bad.length > 0) {
        row.ok = false
        row.notes.push(`row name 失配: ${bad.join(', ')}（应为 ${name}）`)
      }
    } else if (patchPath) {
      row.ok = false
      row.notes.push(`dsh.bundle.patch 指向的 ${manifest.dsh.bundle.patch} 不存在`)
    }

    // 2. client bundle 的模块注册 id
    const clientPath = path.join(pkgDir, 'lib', 'client.js')
    if (fs.existsSync(clientPath)) {
      const src = fs.readFileSync(clientPath, 'utf8')
      const m = /__ModuleLoader__\.load\(\{\s*\n\s*id:\s*"([^"]+)"/.exec(src)
      row.moduleId = m?.[1] ?? null
      if (m && m[1] !== name) {
        row.ok = false
        row.notes.push(`client bundle id 失配: ${m[1]}（应为 ${name}）`)
      }
      if (src.includes('__DSH_TAILSCALE_HIDDEN__')) row.notes.push('已打过 Tailscale 隐藏补丁')
    } else if (row.client) {
      row.notes.push('声明了 dsh.client 但没有 lib/client.js')
    }
  } catch (error) {
    row.ok = false
    row.notes.push(`失败: ${String(error.message).split('\n')[0]}`)
  }
  rows.push(row)
}

const pad = (s, n) => String(s).padEnd(n)
console.log(`${pad('包', 42)}${pad('版本', 10)}${pad('字节', 10)}${'结论'}`)
for (const r of rows) {
  console.log(`${pad(r.name, 42)}${pad(r.version, 10)}${pad(r.bytes ?? '-', 10)}${r.ok ? 'OK' : '需修正'}`)
  for (const n of r.notes) console.log(`  - ${n}`)
}
fs.writeFileSync(path.join(outDir, 'audit.json'), JSON.stringify(rows, null, 2))
console.log(`\n明细: ${path.join(outDir, 'audit.json')}`)
