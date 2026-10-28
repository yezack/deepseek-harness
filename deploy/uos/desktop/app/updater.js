// 桌面壳的自动升级（客户端）。
//
// 分发是「组件」粒度：一个 installer + 本体组件 + 每个插件一个组件，没有整包。
//   manifest.json      format 2 组件清单：components[] 各自带 name/kind/version/order/sha256。
//                      update.json 的 manifestUrl 指向它；installer 固定取 `<清单目录>/manifest.json`
//   $DEST/installer.sh 安装器：下载、校验 sha256、按 order 调组件安装脚本、重播 profile
//
// 壳只做两件事，下载/解包/备份/回滚全部由 installer 负责：
//   check()          读清单 + 本机已装状态，算出每个组件「是否需要更新 / 是否强制更新」
//   installUpdates() 用 sudo 调 `installer.sh upgrade all --server <清单目录>`，解析它的输出
//
// 本机已装状态有两个来源，优先级 installed.json > 组件自己的版本文件：
//   $DEST/installed.json                           { format:1, layout:'components', components:{...} }
//   $DEST/.installed-version                       本体
//   $DEST/plugins/<name>/.installed-version        插件
//
// installer 的输出协议（壳只认这些前缀，其余行按普通日志记录）：
//   PHASE <动作> <组件名|profile>      进度短语，如 `PHASE 安装 dsh-better-sidebar`
//   RESULT ok|skipped <组件名> <版本>  / RESULT removed <组件名> / RESULT done
//   RESULT ok profile seeded           profile 已重播
//   ERROR <消息>
const fs = require('node:fs')
const http = require('node:http')
const https = require('node:https')
const path = require('node:path')
const { spawn, execFileSync } = require('node:child_process')

const DEST = process.env.DSH_DEST || '/deepseek-harness'
const CONFIG_FILE = path.join(DEST, 'update.json')
const STATE_FILE = path.join(DEST, 'installed.json')
const INSTALLER = path.join(DEST, 'installer.sh')
const BODY_STATE = path.join(DEST, '.installed-version')
const PLUGINS_DIR = path.join(DEST, 'plugins')
const BODY_NAME = '@deepseek-ai/dsh'
const MANIFEST_FORMAT = 2
const MAX_REDIRECTS = 5
// installer 的输出可能很长，只留最近若干行给弹窗定位问题。
const KEEP_LINES = 200
const TAIL_LINES = 80
const PHASE_PREFIX = 'PHASE '
const RESULT_PREFIX = 'RESULT '
const ERROR_PREFIX = 'ERROR '

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (error) {
    return null
  }
}

// 默认更新源（未在 update.json / DSH_UPDATE_URL 里指定时使用）。
// 地址按普通清单 URL 使用；installer 只认 `<--server 目录>/manifest.json`，两者的换算见 serverBaseUrl()。
const DEFAULT_MANIFEST_URL = 'http://autoupdate.kxzd.sjq.sh/deepseek_harness/latest.json'

/** 更新配置：update.json 的 manifestUrl > 环境变量 DSH_UPDATE_URL > 内置默认服务器。 */
function updateConfig() {
  const config = readJson(CONFIG_FILE) ?? {}
  const fromConfig = typeof config.manifestUrl === 'string' ? config.manifestUrl.trim() : ''
  const fromEnv = (process.env.DSH_UPDATE_URL || '').trim()
  const manifestUrl = fromConfig !== '' ? fromConfig : (fromEnv !== '' ? fromEnv : DEFAULT_MANIFEST_URL)
  return { manifestUrl, source: fromConfig !== '' ? 'update.json' : (fromEnv !== '' ? 'env' : 'default') }
}

/**
 * 读一个版本状态文件（.installed-version）。
 * @param {string} file 状态文件绝对路径
 * @returns {object|null} 形如 { version, dshVersion, installedAt, mode }；缺失或损坏返回 null
 */
function readState(file) {
  const state = readJson(file)
  if (state === null || typeof state !== 'object' || typeof state.version !== 'string') return null
  return state
}

/**
 * installer 写的组件状态（installed.json）。它记着每个已装组件的 kind/version，
 * 是托盘「插件 N 个」和按组件查版本的来源。
 * @returns {{components:Object<string,object>}|null} 缺失、损坏或没有 components 对象时返回 null
 */
function installedState() {
  const state = readJson(STATE_FILE)
  if (state === null || typeof state !== 'object' || Array.isArray(state)) return null
  const components = state.components
  if (components === null || typeof components !== 'object' || Array.isArray(components)) return null
  return state
}

/**
 * 一个组件的本机版本（installed.json 优先，其次是组件自己的 .installed-version）。
 * @param {{name:string,kind:string}} component 清单里的组件
 * @param {object|null} state 已读好的 installedState()，避免逐个组件重复读盘
 * @returns {string|null} 未安装或读不到返回 null
 */
function installedVersionOf(component, state = installedState()) {
  const entry = state?.components?.[component.name]
  if (typeof entry?.version === 'string' && entry.version.trim() !== '') return entry.version.trim()
  const file = component.kind === 'body'
    ? BODY_STATE
    : path.join(PLUGINS_DIR, component.name, '.installed-version')
  const own = readState(file)
  return typeof own?.version === 'string' && own.version.trim() !== '' ? own.version.trim() : null
}

/**
 * 本体的本机版本状态（导出给壳显示当前版本）。
 * @returns {object|null} 形如 { version, ... }；优先 installed.json 的本体条目，其次 DEST/.installed-version
 */
function installedVersion() {
  const entry = installedState()?.components?.[BODY_NAME]
  if (typeof entry?.version === 'string' && entry.version.trim() !== '') return entry
  return readState(BODY_STATE)
}

/** 版本比较：构建号形如 20261023.1900，按数字段比较（缺失段按 0）。 */
function compareVersions(left, right) {
  const parse = (value) => String(value ?? '').split(/[^0-9]+/u).filter((part) => part !== '').map(Number)
  const a = parse(left)
  const b = parse(right)
  const length = Math.max(a.length, b.length)
  for (let index = 0; index < length; index += 1) {
    const x = a[index] ?? 0
    const y = b[index] ?? 0
    if (x !== y) return x < y ? -1 : 1
  }
  return 0
}

/**
 * 是否必须升级：组件给了 minVersion 且本机版本低于它（本机版本未知时也视为必须）。
 * @param {object} component 清单里的组件（只看 minVersion）
 * @param {{version:string}|null} installed 本机版本状态；null 表示未知
 * @returns {boolean}
 */
function isForced(component, installed) {
  const minVersion = typeof component?.minVersion === 'string' ? component.minVersion.trim() : ''
  if (minVersion === '') return false
  if (installed === null) return true
  return compareVersions(installed.version, minVersion) < 0
}

/**
 * 校验并展开清单里的组件列表（按 order 升序，order 相同保持清单顺序）。
 * 只保留壳需要的字段；file/sha256/size 由 installer 自己用。
 * @param {object} manifest manifest.json 解析结果
 * @returns {Array<{name:string,kind:string,version:string,order:number,minVersion:string,entryId:string,disabled:boolean}>}
 * @throws {Error} format 不是 2、components 不是非空数组、组件缺 name/kind/version
 */
function manifestComponents(manifest) {
  if (manifest.format !== MANIFEST_FORMAT) {
    throw new Error(`format 是 ${JSON.stringify(manifest.format)}，本壳只认 format ${MANIFEST_FORMAT} 组件清单`)
  }
  const list = manifest.components
  if (!Array.isArray(list) || list.length === 0) throw new Error('缺少 components 数组')
  const components = list.map((entry, index) => {
    if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) {
      throw new Error(`components[${index}] 不是对象`)
    }
    const name = typeof entry.name === 'string' ? entry.name.trim() : ''
    if (name === '') throw new Error(`components[${index}] 缺少 name`)
    if (entry.kind !== 'body' && entry.kind !== 'plugin') throw new Error(`${name} 的 kind 不是 body/plugin`)
    const version = typeof entry.version === 'string' ? entry.version.trim() : ''
    if (version === '') throw new Error(`${name} 缺少 version`)
    const order = entry.order === undefined || entry.order === null ? index : Number(entry.order)
    return {
      name,
      kind: entry.kind,
      version,
      order: Number.isFinite(order) ? order : index,
      minVersion: typeof entry.minVersion === 'string' ? entry.minVersion.trim() : '',
      entryId: typeof entry.entryId === 'string' ? entry.entryId : '',
      disabled: entry.disabled === true,
    }
  })
  return components.sort((left, right) => left.order - right.order)
}

/**
 * check() 要拉取的清单地址。配置里以 / 结尾时按"分发目录"补上 manifest.json。
 * @param {{manifestUrl:string}} config updateConfig() 的结果
 * @returns {string}
 * @throws {Error} 地址不是合法绝对 URL
 */
function manifestFileUrl(config) {
  return config.manifestUrl.endsWith('/') ? new URL('manifest.json', config.manifestUrl).toString() : config.manifestUrl
}

/**
 * installer 的 --server 参数。installer 自己拼 `<server>/manifest.json`（它只认这个文件名），
 * 所以这里给的是清单所在目录：配置里带文件名时把文件名去掉。
 * @param {{manifestUrl:string}} config updateConfig() 的结果
 * @returns {string} 以 / 结尾的目录地址
 * @throws {Error} 地址不是合法绝对 URL
 */
function serverBaseUrl(config) {
  return new URL('.', manifestFileUrl(config)).toString()
}

/** 本机状态摘要（日志与"已是最新"提示）：本体 x · 插件 N 个。 */
function describeLocal(views) {
  const body = views.find((view) => view.kind === 'body')
  const plugins = views.filter((view) => view.kind === 'plugin').length
  return `本体 ${body?.installed ?? '未知'} · 插件 ${plugins} 个`
}

function requestModule(url) {
  return new URL(url).protocol === 'https:' ? https : http
}

/** 普通 GET，跟随重定向，返回 { statusCode, body: Buffer }。 */
function request(url, { timeoutMs = 30000, redirects = MAX_REDIRECTS } = {}) {
  return new Promise((resolve, reject) => {
    const requestUrl = new URL(url)
    const transport = requestModule(url)
    const client = transport.get(requestUrl, { timeout: timeoutMs }, (response) => {
      if (response.statusCode >= 300 && response.statusCode < 400 && response.headers.location && redirects > 0) {
        response.resume()
        resolve(request(new URL(response.headers.location, requestUrl).toString(), { timeoutMs, redirects: redirects - 1 }))
        return
      }
      const chunks = []
      response.on('data', (chunk) => chunks.push(chunk))
      response.on('end', () => resolve({ statusCode: response.statusCode, body: Buffer.concat(chunks) }))
      response.on('error', reject)
    })
    client.on('timeout', () => client.destroy(new Error(`请求超时：${url}`)))
    client.on('error', reject)
  })
}

/**
 * installer 的 PHASE 行变成进度窗标题短语。
 * @param {string} body PHASE 之后的部分，如 `安装 dsh-better-sidebar` / `重播 profile`
 * @returns {string} 形如「正在安装 dsh-better-sidebar」
 */
function phaseTitle(body) {
  const [action, ...rest] = body.split(/\s+/u)
  if (action === undefined || action === '') return '正在升级…'
  const target = rest.join(' ').trim()
  return target === '' ? `正在${action}…` : `正在${action} ${target}`
}

/**
 * installer 的 RESULT 行变成一句中文（壳只写日志，不复用它的语义做判断）。
 * @param {string} body RESULT 之后的部分，如 `ok dsh-better-sidebar 0.28.0` / `done` / `ok profile seeded`
 * @returns {string}
 */
function describeResult(body) {
  const [status, ...rest] = body.split(/\s+/u)
  if (status === 'done') return '本轮安装结束'
  if (status === 'ok' && rest[0] === 'profile' && rest[1] === 'seeded') return 'profile 已重播'
  if (status === 'ok' && rest.length >= 2) return `已安装 ${rest[0]} ${rest[1]}`
  if (status === 'ok') return `已完成${rest.length > 0 ? ` ${rest.join(' ')}` : ''}`
  if (status === 'skipped' && rest.length >= 2) return `跳过 ${rest[0]}（已是 ${rest[1]}）`
  if (status === 'skipped') return `已完成${rest.length > 0 ? ` ${rest.join(' ')}` : ''}`
  if (status === 'removed') return `已卸载 ${rest.join(' ')}`.trim()
  return body
}

/** 免密 sudo 是否可用：installer 需要 root，壳不能弹密码框。 */
function hasPasswordlessSudo() {
  try {
    execFileSync('sudo', ['-n', 'true'], { stdio: 'ignore' })
    return true
  } catch (error) {
    return false
  }
}

/** 路径是否存在。DEST 归 root 时普通用户 stat 可能被拒，回落到 sudo test。 */
function pathExists(target) {
  if (fs.existsSync(target)) return true
  try {
    execFileSync('sudo', ['-n', 'test', '-e', target], { stdio: 'ignore' })
    return true
  } catch (error) {
    return false
  }
}

/**
 * 检查更新。
 * @param {{log?:Function}} hooks log 收到普通日志行
 * @returns {Promise<object>} 四种结果之一：
 *   {status:'no-config', message}
 *   {status:'error', message}                          拉清单失败/格式错，message 带 URL
 *   {status:'up-to-date', message, manifest, components, forced}
 *   {status:'available', manifest, components, forced}
 *   components 的每一项是 {name,kind,version,installed,needsUpdate,forced}
 */
async function check({ log } = {}) {
  const config = updateConfig()
  if (config.manifestUrl === '') {
    return { status: 'no-config', message: `未配置更新源（写 ${CONFIG_FILE} 的 manifestUrl，或设环境变量 DSH_UPDATE_URL）` }
  }
  let manifestUrl
  try {
    manifestUrl = manifestFileUrl(config)
  } catch (error) {
    return { status: 'error', message: `更新源地址无效（${config.manifestUrl}）：${error.message}` }
  }
  let manifest
  try {
    const response = await request(manifestUrl)
    if (response.statusCode !== 200) throw new Error(`HTTP ${response.statusCode}`)
    manifest = JSON.parse(response.body.toString('utf8'))
  } catch (error) {
    log?.(`check: 拉取清单失败 ${error.message}`)
    return { status: 'error', message: `无法获取更新清单（${manifestUrl}）：${error.message}` }
  }
  if (manifest === null || typeof manifest !== 'object' || Array.isArray(manifest)) {
    return { status: 'error', message: `更新清单格式不正确（不是 JSON 对象）：${manifestUrl}` }
  }
  let components
  try {
    components = manifestComponents(manifest)
  } catch (error) {
    return { status: 'error', message: `更新清单格式不正确（${error.message}）：${manifestUrl}` }
  }
  const state = installedState()
  const views = components.map((component) => {
    const installed = installedVersionOf(component, state)
    return {
      name: component.name,
      kind: component.kind,
      version: component.version,
      installed,
      // 与旧行为一致：版本字符串不同就要更新（本机没装也算）。
      needsUpdate: installed === null || installed !== component.version,
      // 强制更新只看 minVersion 与本机版本；本机版本未知时 isForced 视为必须。
      forced: isForced(component, installed === null ? null : { version: installed }),
    }
  })
  const pending = views.filter((view) => view.needsUpdate)
  const forced = views.some((view) => view.forced)
  log?.(`check: 远端 ${manifest.version ?? '未知'}（dsh ${manifest.dshVersion ?? '未知'}），本地 ${describeLocal(views)}，${pending.length} 个组件待更新${forced ? '（含强制更新）' : ''}`)
  if (pending.length === 0) {
    return {
      status: 'up-to-date',
      message: `已是最新版本（${describeLocal(views)}）`,
      manifest,
      components: views,
      forced,
    }
  }
  return { status: 'available', manifest, components: views, forced }
}

/**
 * 调 installer 升级所有需要更新的组件。
 * installer 负责下载/校验/按 order 安装/重播 profile；壳只解析它打印的 PHASE/RESULT/ERROR 行。
 * @param {object} result check() 的结果（这里只用来写日志）
 * @param {{log?:Function,onProgress?:Function}} hooks
 *   onProgress 收到 {phase}，phase 可以直接当进度窗标题（如「正在安装 dsh-better-sidebar」）
 * @returns {Promise<{ok:boolean,output:string}>} output 是最近 80 行日志
 * @throws {Error} 无免密 sudo、找不到 installer、installer 退出码非 0（消息带最近 80 行日志）
 */
async function installUpdates(result, { log, onProgress } = {}) {
  const config = updateConfig()
  let server
  try {
    server = serverBaseUrl(config)
  } catch (error) {
    throw new Error(`更新源地址无效（${config.manifestUrl}）：${error.message}`)
  }
  if (!hasPasswordlessSudo()) {
    throw new Error('升级需要免密 sudo（sudo -n）。请让运维给该账户配置 sudoers，或改用离线包手工升级。')
  }
  if (!pathExists(INSTALLER)) {
    throw new Error(`找不到组件安装器：${INSTALLER}（请先用离线包完整安装一次）`)
  }
  // sudo 默认重置环境，DSH_DEST 必须写在 sudo 之后（env），否则自定义安装目录会被
  // installer 当成默认的 /deepseek-harness，两边读写的 installed.json 不是同一份。
  const args = ['-n', 'env', `DSH_DEST=${DEST}`, 'bash', INSTALLER, 'upgrade', 'all', '--server', server]
  log?.(`install: sudo ${args.join(' ')}（目标清单版本 ${result?.manifest?.version ?? '未知'}）`)
  return new Promise((resolve, reject) => {
    const child = spawn('sudo', args, { stdio: ['ignore', 'pipe', 'pipe'] })
    const recent = []
    const errors = []
    let buffer = ''
    let settled = false

    const tail = (count) => recent.slice(-count).join('\n')
    const finish = (error, value) => {
      if (settled) return
      settled = true
      if (error === null) resolve(value)
      else reject(error)
    }
    const handleLine = (raw) => {
      const line = raw.replace(/\r$/u, '')
      if (line === '') return
      recent.push(line)
      if (recent.length > KEEP_LINES) recent.shift()
      if (line.startsWith(PHASE_PREFIX)) {
        onProgress?.({ phase: phaseTitle(line.slice(PHASE_PREFIX.length).trim()) })
        return
      }
      if (line.startsWith(ERROR_PREFIX)) {
        errors.push(line.slice(ERROR_PREFIX.length).trim())
        log?.(`installer: ${line}`)
        return
      }
      if (line.startsWith(RESULT_PREFIX)) {
        log?.(`installer: ${describeResult(line.slice(RESULT_PREFIX.length).trim())}`)
        return
      }
      log?.(`installer: ${line}`)
    }
    // 子进程的 chunk 可能把一行切成几段，按换行攒够一行再解析。
    const consume = (chunk) => {
      buffer += chunk.toString()
      let index = buffer.indexOf('\n')
      while (index !== -1) {
        handleLine(buffer.slice(0, index))
        buffer = buffer.slice(index + 1)
        index = buffer.indexOf('\n')
      }
    }
    child.stdout?.on('data', consume)
    child.stderr?.on('data', consume)
    child.on('error', (error) => finish(new Error(`无法执行 sudo：${error.message}`), null))
    child.on('close', (code, signal) => {
      if (buffer !== '') handleLine(buffer)
      buffer = ''
      if (code === 0) {
        finish(null, { ok: true, output: tail(TAIL_LINES) })
        return
      }
      const reason = errors.length > 0 ? `：${errors.join('；')}` : ''
      finish(new Error(`升级失败（退出码 ${code ?? signal}）${reason}\n${tail(TAIL_LINES)}`), null)
    })
  })
}

module.exports = {
  check,
  installUpdates,
  updateConfig,
  installedVersion,
  installedState,
  compareVersions,
  isForced,
  DEST,
}
