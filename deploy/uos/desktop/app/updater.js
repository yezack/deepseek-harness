// 桌面壳的自动升级（客户端）。
//
// 约定：更新服务器就是一个**静态文件服务器**，放一份清单和若干升级包：
//   latest.json                  { version, sha256, size, url, dshVersion, publishedAt, notes,
//                                  units: { body: {...}, plugins: {...} } }
//   dsh-uos-offline.tar.gz       整包（旧壳兼容；清单没有 units 时唯一可用的命名）
//   dsh-uos-body-<ver>.tar.gz    本体包：app/ + node/ + 脚本
//   dsh-uos-plugins-<ver>.tar.gz 插件包：plugins/ 依赖树
// 客户端只做普通 HTTP GET，不登录、不带 token（服务端由运维另外实现/发布）。
//
// 安装拆成两个可独立升级的单元，版本各写各的：
//   body    -> DEST，版本写在 DEST/.installed-version（install.sh --upgrade）
//   plugins -> DEST/plugins，版本写在 DEST/plugins/.installed-version（install-plugins.sh --upgrade）
// 本体升级会整个搬走 DEST，所以插件目录要先暂存到 PRESERVE_DIR，成功和失败两条
// 路径都必须搬回来 —— 那份副本是插件唯一的来源，丢了就只能重下整包。
const crypto = require('node:crypto')
const fs = require('node:fs')
const http = require('node:http')
const https = require('node:https')
const path = require('node:path')
const { execFileSync } = require('node:child_process')

const DEST = process.env.DSH_DEST || '/deepseek-harness'
const STAGE_DIR = '/var/tmp/dsh-update'
const PACKAGE_DIR = path.join(STAGE_DIR, 'package')
const CONFIG_FILE = path.join(DEST, 'update.json')
const PLUGINS_DIR = path.join(DEST, 'plugins')
const BODY_STATE = path.join(DEST, '.installed-version')
const PLUGINS_STATE = path.join(PLUGINS_DIR, '.installed-version')
// 本体升级前把 DEST/plugins 暂存到这里（与 DEST 分开，避免被 mv DEST backup 一起搬走）。
const PRESERVE_DIR = '/var/tmp/dsh-update-plugins-keep'
// 单元顺序即安装顺序：先本体（install.sh 重建 app/node），再插件（依赖新 app 的 node）。
const UNIT_KEYS = ['body', 'plugins']
const UNIT_ENTRY = { body: 'install.sh', plugins: 'install-plugins.sh' }
const UNIT_LABEL = { body: '本体', plugins: '插件包' }
const MAX_REDIRECTS = 5

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (error) {
    return null
  }
}

// 默认升级服务器（未在 update.json / DSH_UPDATE_URL 里指定时使用）。
// latest.json 里的 url 是相对名，会按这个地址解析。
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
 * 读一个单元的版本状态文件（.installed-version）。
 * @param {string} file 状态文件绝对路径
 * @returns {object|null} 形如 { version, dshVersion, installedAt, mode }；缺失或损坏返回 null
 */
function readState(file) {
  const state = readJson(file)
  if (state === null || typeof state !== 'object' || typeof state.version !== 'string') return null
  return state
}

/** 两个单元的本地状态：{ body, plugins }，各自未安装时为 null。 */
function installedUnits() {
  return { body: readState(BODY_STATE), plugins: readState(PLUGINS_STATE) }
}

/** 本体（旧调用方假设的"当前版本"）的本地状态。 */
function installedVersion() {
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

/** 是否必须升级：manifest 给了 minVersion 且本机版本低于它（本机版本未知时也视为必须）。 */
function isForced(manifest, installed) {
  const minVersion = typeof manifest?.minVersion === 'string' ? manifest.minVersion.trim() : ''
  if (minVersion === '') return false
  if (installed === null) return true
  return compareVersions(installed.version, minVersion) < 0
}

/**
 * 把清单拆成单元列表。清单没有 units 时按旧语义降级为单个 body 单元：
 * 版本/哈希/大小/地址/最低版本全部取顶层字段（旧壳发布的就是这种整包清单）。
 * @param {object} manifest latest.json 解析结果
 * @returns {Array<{key:string,version:string,sha256:string,size:number,url:string,minVersion:string}>}
 * @throws {Error} 单元缺少 version/sha256/url，或既没有 units 也没有顶层 version+sha256
 */
function unitManifests(manifest) {
  const units = manifest?.units
  const hasUnits = units !== null && typeof units === 'object' && !Array.isArray(units)
  if (!hasUnits) {
    const version = manifest?.version
    const sha256 = manifest?.sha256
    if (typeof version !== 'string' || version.trim() === '' || typeof sha256 !== 'string' || sha256.trim() === '') {
      throw new Error('缺少 units，且顶层没有 version/sha256')
    }
    return [{
      key: 'body',
      version: version.trim(),
      sha256: sha256.trim(),
      size: typeof manifest.size === 'number' ? manifest.size : 0,
      url: typeof manifest.url === 'string' && manifest.url.trim() !== '' ? manifest.url.trim() : 'dsh-uos-offline.tar.gz',
      minVersion: typeof manifest.minVersion === 'string' ? manifest.minVersion.trim() : '',
    }]
  }
  const list = []
  for (const key of UNIT_KEYS) {
    const entry = units[key]
    if (entry === undefined || entry === null) continue
    if (typeof entry !== 'object' || Array.isArray(entry)) throw new Error(`units.${key} 不是对象`)
    if (typeof entry.version !== 'string' || entry.version.trim() === '') throw new Error(`units.${key} 缺少 version`)
    if (typeof entry.sha256 !== 'string' || entry.sha256.trim() === '') throw new Error(`units.${key} 缺少 sha256`)
    if (typeof entry.url !== 'string' || entry.url.trim() === '') throw new Error(`units.${key} 缺少 url`)
    list.push({
      key,
      version: entry.version.trim(),
      sha256: entry.sha256.trim(),
      size: typeof entry.size === 'number' ? entry.size : 0,
      url: entry.url.trim(),
      minVersion: typeof entry.minVersion === 'string' ? entry.minVersion.trim() : '',
    })
  }
  if (list.length === 0) throw new Error('units 里没有可用的 body/plugins')
  return list
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

/** 下载到 STAGE_DIR，边下边算 sha256，并回报进度。 */
function download(url, target, expectedSize, onProgress) {
  return new Promise((resolve, reject) => {
    const requestUrl = new URL(url)
    const transport = requestModule(url)
    fs.mkdirSync(path.dirname(target), { recursive: true })
    const out = fs.createWriteStream(target)
    const hash = crypto.createHash('sha256')
    let received = 0
    let lastReport = 0

    const client = transport.get(requestUrl, { timeout: 60000 }, (response) => {
      if (response.statusCode >= 300 && response.statusCode < 400 && response.headers.location) {
        response.resume()
        resolve(download(new URL(response.headers.location, requestUrl).toString(), target, expectedSize, onProgress))
        return
      }
      if (response.statusCode !== 200) {
        response.resume()
        reject(new Error(`下载失败 HTTP ${response.statusCode}`))
        return
      }
      response.on('data', (chunk) => {
        received += chunk.length
        hash.update(chunk)
        const now = Date.now()
        if (now - lastReport > 200) {
          lastReport = now
          onProgress({ received, total: expectedSize })
        }
      })
      response.pipe(out)
      out.on('finish', () => {
        out.close(() => {
          onProgress({ received, total: expectedSize })
          resolve({ sha256: hash.digest('hex'), size: received })
        })
      })
      response.on('error', reject)
    })
    client.on('timeout', () => client.destroy(new Error('下载超时')))
    client.on('error', (error) => { out.destroy(); reject(error) })
  })
}

/**
 * 解包一个单元到 STAGE_DIR（先清空 package/），并校验它的安装入口脚本存在。
 * @param {string} key 'body' | 'plugins'
 * @param {string} tarball 下载好的 tar.gz
 */
function extractUnit(key, tarball) {
  const entry = UNIT_ENTRY[key]
  if (entry === undefined) throw new Error(`未知的升级单元：${key}`)
  fs.mkdirSync(STAGE_DIR, { recursive: true })
  fs.rmSync(PACKAGE_DIR, { recursive: true, force: true })
  execFileSync('tar', ['xzf', tarball, '-C', STAGE_DIR], { stdio: 'pipe' })
  if (!fs.existsSync(path.join(PACKAGE_DIR, entry))) {
    throw new Error(`升级包结构异常：缺少 ${entry}`)
  }
}

/** 旧名字：解整包（结构等同 body 包，必须含 install.sh）。 */
function extractPackage(tarball) {
  extractUnit('body', tarball)
}

function hasPasswordlessSudo() {
  try {
    execFileSync('sudo', ['-n', 'true'], { stdio: 'ignore' })
    return true
  } catch (error) {
    return false
  }
}

/** 以 root 跑一条命令（免密 sudo）。失败会抛错，由调用方决定是否回滚。 */
function runSudo(args, options = {}) {
  return execFileSync('sudo', ['-n', ...args], { stdio: 'pipe', ...options })
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

/** 检查更新。返回 { status: no-config | up-to-date | available | error, ... }。 */
async function check({ log } = {}) {
  const config = updateConfig()
  if (config === null) {
    return { status: 'no-config', message: '未配置更新源（安装时用 DSH_UPDATE_URL，或写 /deepseek-harness/update.json）' }
  }
  let manifest
  try {
    const response = await request(config.manifestUrl)
    if (response.statusCode !== 200) throw new Error(`HTTP ${response.statusCode}`)
    manifest = JSON.parse(response.body.toString('utf8'))
  } catch (error) {
    log?.(`check: 拉取清单失败 ${error.message}`)
    return { status: 'error', message: `无法获取更新清单（${config.manifestUrl}）：${error.message}` }
  }
  if (manifest === null || typeof manifest !== 'object') {
    return { status: 'error', message: '更新清单格式不正确（不是 JSON 对象）' }
  }
  let units
  try {
    units = unitManifests(manifest)
  } catch (error) {
    return { status: 'error', message: `更新清单格式不正确（${error.message}）` }
  }
  const installed = installedUnits()
  const views = units.map((unit) => {
    const local = installed[unit.key] ?? null
    return {
      key: unit.key,
      manifest: unit,
      installed: local,
      // 与旧行为一致：版本字符串不同就要更新（本机未知也算）。
      needsUpdate: local === null || local.version !== unit.version,
      forced: isForced(unit, local),
    }
  })
  const pending = views.filter((view) => view.needsUpdate)
  const forced = views.some((view) => view.forced)
  const describe = (stateOf) => views
    .map((view) => `${UNIT_LABEL[view.key] ?? view.key} ${stateOf(view) ?? '未知'}`)
    .join(' · ')
  log?.(`check: 远端 ${describe((view) => view.manifest.version)}；本地 ${describe((view) => view.installed?.version)}`)
  if (pending.length === 0) {
    return {
      status: 'up-to-date',
      message: `已是最新版本（${describe((view) => view.installed?.version)}）`,
      config,
      manifest,
      installed: installed.body ?? null,
      units: views,
      forced,
    }
  }
  return {
    status: 'available',
    config,
    manifest,
    installed: installed.body ?? null,
    units: views,
    forced,
  }
}

/**
 * 下载并校验一个单元的升级包（复用 request/download）。
 * @param {object} unit unitManifests() 的元素（check() 结果里是 units[].manifest）
 * @param {{manifestUrl:string}} config updateConfig() 的结果，用来解析相对 url
 * @param {{log?:Function,onProgress?:Function}} hooks onProgress 收到 { received, total }
 * @returns {Promise<string>} STAGE_DIR 里的 tarball 路径
 */
async function fetchUnit(unit, config, { log, onProgress } = {}) {
  if (typeof config?.manifestUrl !== 'string' || config.manifestUrl === '') {
    throw new Error('缺少更新源地址（config.manifestUrl），无法解析下载地址')
  }
  const report = typeof onProgress === 'function' ? onProgress : () => {}
  fs.mkdirSync(STAGE_DIR, { recursive: true })
  const target = path.join(STAGE_DIR, `dsh-uos-${unit.key}.tar.gz`)
  const downloadUrl = new URL(unit.url, config.manifestUrl).toString()
  log?.(`fetch: ${UNIT_LABEL[unit.key] ?? unit.key} ${unit.version} ${downloadUrl}`)
  const result = await download(downloadUrl, target, unit.size, report)
  // size=0 是清单模板里的占位值，不当作"期望 0 字节"。
  if (typeof unit.size === 'number' && unit.size > 0 && unit.size !== result.size) {
    throw new Error(`包大小不符：期望 ${unit.size}，实际 ${result.size}`)
  }
  if (result.sha256 !== unit.sha256) {
    throw new Error(`sha256 校验失败：期望 ${unit.sha256.slice(0, 12)}…，实际 ${result.sha256.slice(0, 12)}…`)
  }
  log?.(`fetch: ${UNIT_LABEL[unit.key] ?? unit.key}校验通过 ${result.size} 字节`)
  return target
}

/**
 * 本体安装：暂存插件 → 备份 DEST → install.sh --upgrade → 补写 update.json →
 * 搬回插件 → 删除备份。任何一步失败都回滚到升级前的 DEST，并把插件搬回。
 * 注意：搬回插件之后不再有任何会抛错的操作 —— 否则回滚会连同刚搬回的插件一起删掉。
 * @param {string} tarball fetchUnit() 的返回值
 * @param {{config:{manifestUrl:string},log?:Function,onProgress?:Function}} options
 * @returns {object|null} 安装后的 DEST/.installed-version
 */
function installBodyUnit(tarball, { config, log, onProgress } = {}) {
  if (typeof config?.manifestUrl !== 'string' || config.manifestUrl === '') {
    throw new Error('缺少更新源地址（config.manifestUrl），无法在升级后保留 update.json')
  }
  if (!pathExists(DEST)) {
    throw new Error(`安装目录不存在：${DEST}（无法升级，请先完整安装）`)
  }
  extractPackage(tarball)
  onProgress?.({ phase: 'installing' })
  const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14)
  const backup = `${DEST}.bak-${stamp}`
  let backedUp = false
  let preserved = false
  try {
    // 1) 插件目录先挪出 DEST：下一步整个搬走 DEST，而 install.sh 不认领 plugins。
    if (pathExists(PLUGINS_DIR)) {
      runSudo(['rm', '-rf', PRESERVE_DIR])
      runSudo(['mv', PLUGINS_DIR, PRESERVE_DIR])
      preserved = true
      log?.(`install: 插件目录已暂存 ${PLUGINS_DIR} -> ${PRESERVE_DIR}`)
    }
    // 2) 备份当前安装（与人工升级流程一致；install.sh 的备份保留策略会清理过旧的 .bak）。
    log?.(`install: 备份 ${DEST} -> ${backup}`)
    runSudo(['mv', DEST, backup])
    backedUp = true
    // 3) 跑安装器。sudo 默认会重置环境，DSH_UPDATE_URL 必须显式经 `env` 传进去，
    //    否则 install.sh 收不到、升级后 update.json 变成空配置（实测踩过）。
    const output = runSudo([
      'env',
      `DSH_UPDATE_URL=${config.manifestUrl}`,
      'bash', path.join(PACKAGE_DIR, 'install.sh'), '--upgrade',
    ], { timeout: 20 * 60 * 1000 })
    log?.(`install: 完成\n${output.toString().slice(-4000)}`)
    // 4) 兜底补写更新源：即使 install.sh 没写（例如老版本安装器），也把配置补回去。
    //    放在搬回插件之前，失败时插件仍在 PRESERVE_DIR，回滚是安全的。
    runSudo(['tee', path.join(DEST, 'update.json')], {
      input: `${JSON.stringify({ manifestUrl: config.manifestUrl }, null, 2)}\n`,
    })
    // 5) 插件目录搬回。install.sh 不碰 plugins，正常情况下 DEST/plugins 不存在。
    if (preserved) {
      runSudo(['mv', PRESERVE_DIR, PLUGINS_DIR])
      preserved = false
      log?.('install: 插件目录已恢复')
    }
    // 6) 删除备份：此刻新安装与插件都已就位，失败只记日志（不能因此回滚）。
    try {
      runSudo(['rm', '-rf', backup])
    } catch (error) {
      log?.(`install: 删除备份失败（不影响本次升级）: ${error.message}`)
    }
  } catch (error) {
    const detail = (error.stdout?.toString() ?? '') + (error.stderr?.toString() ?? '')
    log?.(`install: 失败，回滚\n${detail.slice(-4000)}`)
    try {
      if (backedUp) {
        runSudo(['rm', '-rf', DEST])
        runSudo(['mv', backup, DEST])
      }
      if (preserved) {
        // 插件是唯一不在这两份副本里的数据（backup 里没有 plugins），必须搬回。
        if (pathExists(PLUGINS_DIR)) runSudo(['rm', '-rf', PLUGINS_DIR])
        runSudo(['mv', PRESERVE_DIR, PLUGINS_DIR])
        preserved = false
      }
      log?.('install: 已回滚到升级前')
    } catch (rollbackError) {
      log?.(`install: 回滚失败 ${rollbackError.message}`)
      if (preserved) log?.(`install: 插件目录仍保留在 ${PRESERVE_DIR}，请手工搬回 ${PLUGINS_DIR}`)
    }
    throw new Error(`本体升级失败（已尝试回滚）：${error.message}`)
  }
  fs.rmSync(STAGE_DIR, { recursive: true, force: true })
  return readState(BODY_STATE)
}

/**
 * 插件安装：install-plugins.sh 自己解 plugins.zip 并原子换目录，失败不改动现有
 * DEST/plugins，所以这里不做备份/回滚，只把失败抛给调用方。
 * @param {string} tarball fetchUnit() 的返回值
 * @param {{log?:Function,onProgress?:Function}} options
 * @returns {object|null} 安装后的 DEST/plugins/.installed-version
 */
function installPluginsUnit(tarball, { log, onProgress } = {}) {
  extractUnit('plugins', tarball)
  onProgress?.({ phase: 'installing' })
  const output = runSudo([
    'env', `DSH_DEST=${DEST}`,
    'bash', path.join(PACKAGE_DIR, 'install-plugins.sh'), '--upgrade',
  ], { timeout: 20 * 60 * 1000 })
  log?.(`install: 插件安装完成\n${output.toString().slice(-4000)}`)
  fs.rmSync(STAGE_DIR, { recursive: true, force: true })
  return readState(PLUGINS_STATE)
}

/**
 * 安装一个单元。
 * @param {object} unit unitManifests() 的元素
 * @param {string} tarball fetchUnit() 的返回值
 * @param {{config?:object,log?:Function,onProgress?:Function}} options body 需要 config.manifestUrl
 * @returns {object|null} 该单元安装后的状态（对应 .installed-version）
 */
function installUnit(unit, tarball, options = {}) {
  if (!hasPasswordlessSudo()) {
    throw new Error('升级需要免密 sudo（sudo -n）。请让运维给该账户配置 sudoers，或手工升级。')
  }
  if (unit?.key === 'body') return installBodyUnit(tarball, options)
  if (unit?.key === 'plugins') return installPluginsUnit(tarball, options)
  throw new Error(`未知的升级单元：${unit?.key}`)
}

/** 旧的整包下载入口（兼容别名）：清单没有 units 时降级为 body 单元。 */
async function fetchPackage(manifest, config, { log, onProgress } = {}) {
  const [unit] = unitManifests(manifest)
  return fetchUnit(unit, config, { log, onProgress })
}

/** 旧的整包安装入口（兼容别名）：等价于对 body 单元调用 installUnit。 */
function installPackage(tarball, options = {}) {
  return installUnit({ key: 'body' }, tarball, options)
}

module.exports = {
  check,
  fetchPackage,
  installPackage,
  updateConfig,
  installedVersion,
  compareVersions,
  isForced,
  STAGE_DIR,
  DEST,
  PLUGINS_DIR,
  BODY_STATE,
  PLUGINS_STATE,
  PRESERVE_DIR,
  readState,
  installedUnits,
  unitManifests,
  fetchUnit,
  installUnit,
}
