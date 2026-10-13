// 校验 web-app bundle patch 里的 chrome-devtools MCP 行。
// DSH 的 !!js 标签由 Loader 注册，这里按标量透传后解析。
//
// 行必须指向朴素包名 chrome-devtools-mcp：离线镜像用 npm overrides 把
// @yezack/chrome-devtools-mcp-108 装到了那个名字下，所以该目录就是 fork，
// 而 dsh 自带的 browser-use 包按同一名字 import.meta.resolve，也拿到 fork。
//
// 用法（仓库根目录）:
//   node deploy/tools/check-mcp-row.mjs <js-yaml 入口> <cordis.patch.yml>
import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
// 两个路径都按当前工作目录解析：require('相对路径') 是相对本文件找的。
const yaml = require(path.resolve(process.argv[2]))
const JsType = new yaml.Type('tag:yaml.org,2002:js', { kind: 'scalar', construct: (data) => data })
const schema = yaml.DEFAULT_SCHEMA.extend([JsType])

const doc = yaml.load(fs.readFileSync(path.resolve(process.argv[3]), 'utf8'), { schema })
const rows = doc.flatMap((entry) => entry.insert ?? [])
const row = rows.find((candidate) => candidate.id === 'mcp-chrome-devtools')

const expected = '/deepseek-harness/app/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js'
const actual = String(row?.config?.args?.[0] ?? '')

const checks = {
  'YAML 解析且 mcp 行存在': row !== undefined,
  '默认路径与安装布局一致': actual.includes(expected),
  '不指向 fork 的原始包名': !actual.includes('@yezack/'),
  '不带 headless': !row?.config?.args?.includes('--headless'),
  '浏览器路径可覆盖': String(row?.config?.args?.[2] ?? '').includes('DSH_CHROME_PATH'),
  // 浏览器子进程必须拿到可写的 $HOME：360 的 crashpad 没有它就拿不到 --database，
  // CDP 起不来，puppeteer 只报 Target closed。
  '注入可写 HOME': String(row?.config?.env?.HOME ?? '').includes('DSH_CHROME_HOME'),
}

console.log('  insert 行数           :', rows.length)
console.log('  serverName            :', row?.config?.serverName)
console.log('  args                  :', JSON.stringify(row?.config?.args))
console.log('  env.HOME              :', JSON.stringify(row?.config?.env?.HOME))
for (const [label, ok] of Object.entries(checks)) {
  console.log('  ' + (ok ? '✓' : '✗') + ' ' + label)
}

process.exit(Object.values(checks).every(Boolean) ? 0 : 1)
