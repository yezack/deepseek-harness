// 在副本上验证 patch-remote-mobile.mjs：不碰真实安装。
//
// 用法（仓库根目录）:
//   node deploy/tools/test-hide-tailscale.mjs [源插件目录]
// 默认从 ~/.dsh 的 desktop profile 取已安装的包；要验 fork 就显式传它解开的目录。
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execFileSync } from 'node:child_process'

const PKG = '@yezack/dsh-remote-mobile'
const source = process.argv[2] ?? path.join(os.homedir(), '.dsh', 'profiles', 'desktop', 'node_modules', 'dsh-remote-mobile')
if (!fs.existsSync(source)) {
  console.error(`找不到源插件 ${source}；请作为第一个参数传入包目录`)
  process.exit(1)
}
const patcher = path.resolve('deploy/uos/patch-remote-mobile.mjs')
if (!fs.existsSync(patcher)) {
  console.error(`找不到 ${patcher}；请在仓库根目录运行`)
  process.exit(1)
}
const stage = path.join(os.tmpdir(), 'rmtest')
fs.rmSync(stage, { recursive: true, force: true })
fs.mkdirSync(path.join(stage, 'node_modules', '@yezack'), { recursive: true })
fs.cpSync(source, path.join(stage, 'node_modules', PKG), { recursive: true })

const client = path.join(stage, 'node_modules', PKG, 'lib', 'client.js')
const patchFile = path.join(stage, 'node_modules', PKG, 'cordis.patch.yml')
const count = (text, needle) => text.split(needle).length - 1
const before = fs.readFileSync(client, 'utf8')

console.log('=== 原始 ===')
console.log('  大小                    :', before.length)
console.log('  渲染调用 t("tailscaleSectionTitle") :', count(before, 't("tailscaleSectionTitle"'))
console.log('  lanIp / generate-code   :', before.includes('lanIp'), '/', before.includes('generate-code'))
const rowNameBefore = /^\s*name:\s*'([^']+)'/mu.exec(fs.readFileSync(patchFile, 'utf8'))?.[1]
const declaredName = JSON.parse(fs.readFileSync(path.join(stage, 'node_modules', PKG, 'package.json'), 'utf8')).name
console.log('  cordis.patch row name   :', rowNameBefore, ' 包名:', declaredName)

console.log('=== 执行补丁 ===')
const out = execFileSync(process.execPath, [patcher, stage], { encoding: 'utf8' })
process.stdout.write(out)

const rowNameAfter = /^\s*name:\s*'([^']+)'/mu.exec(fs.readFileSync(patchFile, 'utf8'))?.[1]
console.log('  row name 已等于包名     :', rowNameAfter === declaredName, `(${rowNameAfter})`)

const after = fs.readFileSync(client, 'utf8')
console.log('=== 补丁后 ===')
console.log('  大小                    :', after.length, `(减少 ${before.length - after.length})`)
console.log('  含隐藏标记              :', after.includes('__DSH_TAILSCALE_HIDDEN__'))
console.log('  渲染调用剩余            :', count(after, 't("tailscaleSectionTitle"'), '← 应为 0')
console.log('  文案字典项仍在          :', count(after, 'tailscaleSectionTitle:'), '← 应为 2（zh/en）')
console.log('  相邻块仍在 lanIp        :', after.includes('lanIp'))
console.log('  配对码生成仍在          :', after.includes('generate-code'))
console.log('  netCardTitle 仍在       :', after.includes('netCardTitle'))

console.log('=== 语法检查 ===')
try {
  execFileSync(process.execPath, ['--check', client], { stdio: 'pipe' })
  console.log('  node --check: 通过')
} catch (error) {
  console.log('  node --check: 失败')
  console.log(String(error.stderr).slice(0, 600))
  process.exit(1)
}

console.log('=== 幂等 ===')
const again = execFileSync(process.execPath, [patcher, stage], { encoding: 'utf8' })
process.stdout.write(again)
console.log('  大小未再变化            :', fs.readFileSync(client, 'utf8').length === after.length)

fs.rmSync(stage, { recursive: true, force: true })
