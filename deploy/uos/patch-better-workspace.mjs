// 把 dsh-better-workspace 的默认工作区分组从 'disk'（仅磁盘目录）改为 'slash'
//（仅名称，只按标题里的 / 分组）。
//
// 为什么只能改代码：该设置不在插件的 cordis Config 里（Row Config 只有
// compactChains / statusPulse / styling / appearance 四项），workspaceGroupMode
// 保存在浏览器端持久 store（dsh.betterWorkspace.view.v1），且"持久化的值优先"
// —— 初始默认值只在水合不到任何持久值时生效。因此改 init 默认值就是
// "默认安装即仅名称"，而已经选过分组模式的浏览器不受影响（persisted wins）。
//
// 锚点：init 对象里唯一一处 workspaceGroupMode: 'disk'。找不到或位置不对就
// 直接失败，不静默跳过（与 patch-remote-mobile.mjs 同一约定）。
import fs from 'node:fs'
import path from 'node:path'

const appDir = process.argv[2]
if (appDir === undefined) {
  console.error('用法: patch-better-workspace.mjs <app 目录>')
  process.exit(1)
}

const file = path.join(appDir, 'node_modules', 'dsh-better-workspace', 'src', 'client.js')
if (!fs.existsSync(file)) {
  console.error(`[patch-better-workspace] 未找到 ${file}`)
  process.exit(1)
}

const source = fs.readFileSync(file, 'utf8')
if (source.includes('__DSH_BW_DEFAULT_SLASH__')) {
  console.log('[patch-better-workspace] 已打过补丁，跳过')
  process.exit(0)
}

const anchor = "workspaceGroupMode: 'disk'"
const at = source.indexOf(anchor)
if (at === -1 || source.indexOf(anchor, at + 1) !== -1) {
  console.error("[patch-better-workspace] 锚点 workspaceGroupMode: 'disk' 缺失或不唯一，拒绝猜测")
  process.exit(1)
}

// 必须是 init 默认值那一行（同statement还有 archivedFilter / sessionTitleSlash），
// 避免锚点漂移后改到迁移逻辑里的赋值。
const lineStart = source.lastIndexOf('\n', at) + 1
const lineEnd = source.indexOf('\n', at)
const line = source.slice(lineStart, lineEnd === -1 ? source.length : lineEnd)
if (!line.includes("archivedFilter: 'default'") || !line.includes('sessionTitleSlash')) {
  console.error('[patch-better-workspace] 锚点所在行不是 init 默认值行，拒绝改写')
  process.exit(1)
}

const patched = source.slice(0, at) + "workspaceGroupMode: 'slash' /* __DSH_BW_DEFAULT_SLASH__ */" + source.slice(at + anchor.length)
fs.writeFileSync(file, patched)
console.log(`[patch-better-workspace] 默认工作区分组: disk -> slash（仅名称）
  ${path.relative(appDir, file)}`)
