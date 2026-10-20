// Regenerate compat-standalone.js, the script the browser-side compat tests load.
//
// It is the exact IIFE the host injects, so the tests exercise shipped code
// rather than a copy. The file is generated output and stays out of the
// repository; regenerate it beside the test page before running it.
//
// Usage (from the repository root):
//   node --import tsx/esm deploy/tools/gen-compat-standalone.mjs _stage
//   node deploy/tools/gen-compat-standalone.mjs _stage          # Node 24, strip-types
//
// Then open _stage/css-test.html or _stage/mutation-test.html in a browser.
import fs from 'node:fs'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const outDir = process.argv[2] ?? '_stage'
const source = path.resolve('packages/host/web-compat/src/compat-script.ts')

if (!fs.existsSync(source)) {
  console.error(`找不到 ${source}；请在仓库根目录运行`)
  process.exit(1)
}

const module = await import(pathToFileURL(source).href)
const script = module.compatScript()
const out = path.join(outDir, 'compat-standalone.js')
fs.mkdirSync(outDir, { recursive: true })
fs.writeFileSync(out, script)
console.log(`已写出 ${out}（${script.length} 字节）`)
