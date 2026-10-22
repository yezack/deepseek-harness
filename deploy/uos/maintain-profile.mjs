// 维护 web profile 的 cordis.patch.yml：擦除孤儿行、整理标记块、语法预检。
//
// 用法: maintain-profile.mjs <patch 文件> <cordis.yml> <安装目录> <禁用清单csv>
//
// 【A1 孤儿行】加载器对"指向不存在的 entry"的 patch 行只打一行 warn，该行的
// config 静默丢弃（生产环境出现过 orphan 行导致浏览器配置没生效却没人发现）。
// 这里按 cordis.yml 的文本里是否出现该 id 判断存活，删掉对不上的整行。
//
// 【A2 标记块卫生】`# >>> dsh-offline` 块由本包独占维护；有人在块内手写了别的
// 配置（生产环境出现过 better-workspace 的配色行被包进 render browser 块），
// 下次重写标记块会把它覆盖。这里把不属于该块的行移出到块外，不丢内容。
//
// 【A3 语法预检】用应用自带的 js-yaml 解析一遍（注册 !!js 自定义 tag 以匹配
// cordis 的写法）。失败就回滚到 .bak-seed 并退出：宁可启动前明确报错，也不要
// 等到 schemastery 深处才抛（0.0.0.0 那次报错离配置行很远，现场极难定位）。
import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)

const [fileArg, cordisArg, dest, disabledCsv] = process.argv.slice(2)
if (fileArg === undefined || cordisArg === undefined || dest === undefined) {
  console.error('用法: maintain-profile.mjs <patch 文件> <cordis.yml> <安装目录> [禁用清单csv]')
  process.exit(1)
}

const file = path.resolve(fileArg)
const backup = `${file}.bak-seed`

const BLOCKS = [
  {
    begin: '# >>> dsh-offline: default-disabled plugins',
    end: '# <<< dsh-offline: default-disabled plugins',
    owned: new Set((disabledCsv ?? '').split(',').filter((item) => item !== '')),
  },
  {
    begin: '# >>> dsh-offline: render browser',
    end: '# <<< dsh-offline: render browser',
    owned: new Set(['univer']),
  },
]

let text
try {
  text = fs.readFileSync(file, 'utf8')
} catch (error) {
  if (error.code === 'ENOENT') process.exit(0)
  throw error
}

// 首次维护前留一份基线，语法预检失败时回滚到它。
if (!fs.existsSync(backup)) {
  try {
    fs.copyFileSync(file, backup)
  } catch (error) {
    console.error(`[maintain-profile] 无法创建备份 ${backup}: ${error.message}`)
    process.exit(1)
  }
}

let lines = text.split('\n')
const rowIdOf = (line) => {
  const match = /^\s*-\s*id:\s*(\S+)/.exec(line)
  return match === null ? null : match[1]
}

/** 把 [start, end) 行按 `- id:` 切分成行组。 */
function partition(start, end) {
  const rows = []
  let current = null
  for (let index = start; index < end; index += 1) {
    if (rowIdOf(lines[index]) !== null) {
      if (current !== null) rows.push(current)
      current = { start: index, end: index + 1 }
    } else if (current !== null) {
      current.end = index + 1
    }
  }
  if (current !== null) rows.push(current)
  return rows
}

/** 找到标记块的行号范围；找不到返回 null。 */
function findBlock(block) {
  let beginAt = -1
  for (let index = 0; index < lines.length; index += 1) {
    if (beginAt === -1) {
      if (lines[index].includes(block.begin)) beginAt = index
      continue
    }
    if (lines[index].includes(block.end)) return { beginAt, endAt: index }
  }
  return null
}

let moved = 0
let removed = 0

// 【A2】块内只保留本块拥有的行，其余移出到块结束标记之后。
for (const block of BLOCKS) {
  const found = findBlock(block)
  if (found === null) continue
  const rows = partition(found.beginAt + 1, found.endAt)
  const foreign = rows.filter((row) => !block.owned.has(rowIdOf(lines[row.start])))
  if (foreign.length === 0) continue
  const payload = []
  for (const row of foreign) {
    payload.push(...lines.slice(row.start, row.end))
    if (rowIdOf(lines[row.start]) === null) continue
  }
  // 从后往前删，避免索引错位。
  for (const row of [...foreign].reverse()) lines.splice(row.start, row.end - row.start)
  const refound = findBlock(block)
  if (refound === null) continue
  const insert = [
    '# 以下配置原本被误放在上面这个包维护块内部，已自动移出（内容原样保留）。',
    ...payload,
    '',
  ]
  lines.splice(refound.endAt + 1, 0, ...insert)
  const names = foreign.map((row) => rowIdOf(lines[row.start] ?? '')).filter((name) => name !== null)
  console.log(`[maintain-profile] 标记块「${block.begin.replace('# >>> dsh-offline: ', '')}」移出 ${foreign.length} 行外来配置`)
  moved += foreign.length
}

// 【A1】删除指向不存在 entry 的孤儿行（不动本包维护块内的行）。
//
// "存在"的判定不能只看 profile 的 cordis.yml：绝大多数 entry 是**各 bundle 的
// cordis.patch.yml 在加载时插入**的（webserver、univer、dream-skin 都不在
// cordis.yml 文本里）。只按 cordis.yml 判会把合法行当孤儿删掉 —— 实测踩过。
// 因此把 app/node_modules 下所有 bundle patch 的 `- id:` 一并算作已知 id。
function collectKnownIds(dest) {
  const known = new Set()
  const readPatch = (file) => {
    try {
      const text = fs.readFileSync(file, 'utf8')
      for (const match of text.matchAll(/^\s*-\s*id:\s*(\S+)/gmu)) known.add(match[1])
    } catch (error) {
      /* 读不了就跳过，宁可少判孤儿 */
    }
  }
  const visit = (dir, depth) => {
    if (depth < 0) return
    let entries
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true })
    } catch (error) {
      return
    }
    for (const entry of entries) {
      if (!entry.isDirectory()) {
        if (entry.name === 'cordis.patch.yml') readPatch(path.join(dir, entry.name))
        continue
      }
      visit(path.join(dir, entry.name), depth - 1)
    }
  }
  // 3 层足够覆盖 node_modules/<pkg>、node_modules/<@scope>/<pkg>、<pkg>/node_modules/<dep>
  visit(path.join(dest, 'app', 'node_modules'), 3)
  return known
}

let knownIds = null
try {
  knownIds = collectKnownIds(dest)
} catch (error) {
  knownIds = null
}
let cordisText = null
try {
  cordisText = fs.readFileSync(path.resolve(cordisArg), 'utf8')
} catch (error) {
  if (error.code !== 'ENOENT') throw error
}
if (knownIds !== null && knownIds.size > 0) {
  if (cordisText !== null) {
    for (const match of cordisText.matchAll(/^\s*-\s*id:\s*(\S+)/gmu)) knownIds.add(match[1])
  }
  const inManaged = new Set()
  for (const block of BLOCKS) {
    const found = findBlock(block)
    if (found === null) continue
    for (let index = found.beginAt; index <= found.endAt; index += 1) inManaged.add(index)
  }
  const orphans = []
  const rows = partition(0, lines.length)
  for (const row of rows) {
    const id = rowIdOf(lines[row.start])
    if (id === null) continue
    if (inManaged.has(row.start)) continue
    if (BLOCKS.some((block) => block.owned.has(id))) continue
    if (knownIds.has(id)) continue
    orphans.push({ id, start: row.start, end: row.end })
  }
  for (const row of orphans.reverse()) {
    lines.splice(row.start, row.end - row.start)
    console.log(`[maintain-profile] 删除孤儿 patch 行: ${row.id}（没有 bundle 或 cordis.yml 提供该 entry）`)
    removed += 1
  }
} else {
  console.log('[maintain-profile] 无法枚举已知 entry（bundle patch 扫描失败），跳过孤儿行检查')
}

const next = lines.join('\n').replace(/\n{3,}/gu, '\n\n').trimEnd() + '\n'
const changed = next !== text

// 【A3】语法预检：应用自带的 js-yaml + !!js 自定义 tag。
function parseStrict(source) {
  const yaml = require(path.join(dest, 'app', 'node_modules', 'js-yaml'))
  const jsTag = new yaml.Type('tag:yaml.org,2002:js', {
    kind: 'scalar',
    construct: (data) => data,
  })
  const schema = yaml.DEFAULT_SCHEMA.extend([jsTag])
  yaml.load(source, { schema })
}

function fail(message) {
  try {
    if (fs.existsSync(backup)) fs.copyFileSync(backup, file)
  } catch (error) {
    console.error(`[maintain-profile] 回滚失败: ${error.message}`)
  }
  console.error(`[maintain-profile] ${file} 语法错误，已回滚: ${message}`)
  process.exit(1)
}

try {
  parseStrict(changed ? next : text)
} catch (error) {
  fail(error.message.split('\n')[0])
}

if (changed) {
  const tmp = `${file}.tmp-maintain`
  fs.writeFileSync(tmp, next)
  fs.renameSync(tmp, file)
}
if (moved === 0 && removed === 0) {
  console.log('[maintain-profile] 配置卫生检查通过（无孤儿行、无块内外来行）')
}
