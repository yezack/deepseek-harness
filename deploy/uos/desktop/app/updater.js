// 桌面壳的自动升级（客户端）。
//
// 约定：更新服务器就是一个**静态文件服务器**，放两个文件：
//   latest.json              { version, sha256, size, url, dshVersion, publishedAt, notes }
//   dsh-uos-offline.tar.gz   包本体（url 用相对名，按 manifest 的 URL 解析）
// 客户端只做普通 HTTP GET，不登录、不带 token（服务端由运维另外实现/发布）。
//
// 升级动作与"手工升级"一致：备份当前安装 → 解包 → install.sh --upgrade → 写版本；
// 失败则把备份搬回来。
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
const STATE_FILE = path.join(DEST, '.installed-version')
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

function installedVersion() {
  const state = readJson(STATE_FILE)
  return state && typeof state.version === 'string' ? state : null
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

function extractPackage(tarball) {
  fs.rmSync(PACKAGE_DIR, { recursive: true, force: true })
  execFileSync('tar', ['xzf', tarball, '-C', STAGE_DIR], { stdio: 'pipe' })
  if (!fs.existsSync(path.join(PACKAGE_DIR, 'install.sh'))) {
    throw new Error('升级包结构异常：缺少 install.sh')
  }
}

function hasPasswordlessSudo() {
  try {
    execFileSync('sudo', ['-n', 'true'], { stdio: 'ignore' })
    return true
  } catch (error) {
    return false
  }
}

/** 检查更新。返回 { status: no-config | up-to-date | available | error, ... }。 */
async function check({ log }) {
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
  if (typeof manifest.version !== 'string' || typeof manifest.sha256 !== 'string') {
    return { status: 'error', message: '更新清单格式不正确（缺少 version/sha256）' }
  }
  const installed = installedVersion()
  const current = installed?.version ?? 'unknown'
  log?.(`check: 远端 ${manifest.version} / 本地 ${current}`)
  const forced = isForced(manifest, installed)
  if (installed !== null && manifest.version === current) {
    return { status: 'up-to-date', manifest, installed, forced, message: `已是最新版本（${current}）` }
  }
  return { status: 'available', manifest, installed, forced, config }
}

/** 下载 + 校验。返回 tarball 路径。 */
async function fetchPackage(manifest, config, { log, onProgress }) {
  fs.mkdirSync(STAGE_DIR, { recursive: true })
  const target = path.join(STAGE_DIR, 'dsh-uos-offline.tar.gz')
  const downloadUrl = new URL(manifest.url ?? 'dsh-uos-offline.tar.gz', config.manifestUrl).toString()
  log?.(`fetch: ${downloadUrl}`)
  const result = await download(downloadUrl, target, manifest.size, onProgress)
  if (typeof manifest.size === 'number' && manifest.size !== result.size) {
    throw new Error(`包大小不符：期望 ${manifest.size}，实际 ${result.size}`)
  }
  if (result.sha256 !== manifest.sha256) {
    throw new Error(`sha256 校验失败：期望 ${manifest.sha256.slice(0, 12)}…，实际 ${result.sha256.slice(0, 12)}…`)
  }
  log?.(`fetch: 校验通过 ${result.size} 字节`)
  return target
}

/**
 * 安装：备份当前安装 → 跑安装器 --upgrade → 失败则搬回旧目录。
 * 与人工升级流程一致（install.sh 的备份保留策略会清理过旧的 .bak）。
 */
function installPackage(tarball, { config, log, onProgress }) {
  if (!hasPasswordlessSudo()) {
    throw new Error('升级需要免密 sudo（sudo -n）。请让运维给该账户配置 sudoers，或手工升级。')
  }
  extractPackage(tarball)
  onProgress({ phase: 'installing' })
  const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14)
  const backup = `${DEST}.bak-${stamp}`
  log?.(`install: 备份 ${DEST} -> ${backup}`)
  execFileSync('sudo', ['-n', 'mv', DEST, backup], { stdio: 'pipe' })
  try {
    // 注意：sudo 默认会重置环境，DSH_UPDATE_URL 必须显式经 `env` 传进去，
    // 否则 install.sh 收不到、升级后 update.json 变成空配置（实测踩过）。
    const output = execFileSync('sudo', [
      '-n', 'env',
      `DSH_UPDATE_URL=${config.manifestUrl}`,
      'bash', path.join(PACKAGE_DIR, 'install.sh'), '--upgrade',
    ], {
      stdio: 'pipe',
      timeout: 20 * 60 * 1000,
    })
    log?.(`install: 完成\n${output.toString().slice(-4000)}`)
    // 兜底：即使 install.sh 没写（例如老版本安装器），也把更新源补回去。
    execFileSync('sudo', ['-n', 'tee', path.join(DEST, 'update.json')], {
      input: `${JSON.stringify({ manifestUrl: config.manifestUrl }, null, 2)}\n`,
      stdio: 'pipe',
    })
  } catch (error) {
    const detail = (error.stdout?.toString() ?? '') + (error.stderr?.toString() ?? '')
    log?.(`install: 失败，回滚\n${detail.slice(-4000)}`)
    try {
      fs.rmSync(DEST, { recursive: true, force: true })
      execFileSync('sudo', ['-n', 'mv', backup, DEST], { stdio: 'pipe' })
      log?.('install: 已回滚到升级前')
    } catch (rollbackError) {
      log?.(`install: 回滚失败 ${rollbackError.message}`)
    }
    throw new Error(`升级安装失败（已尝试回滚）：${error.message}`)
  }
  fs.rmSync(STAGE_DIR, { recursive: true, force: true })
  return installedVersion()
}

module.exports = { check, fetchPackage, installPackage, updateConfig, installedVersion, compareVersions, isForced, STAGE_DIR }
