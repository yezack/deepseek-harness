// DeepSeek Harness 桌面壳（Electron）。
//
// 职责边界：
//   - UI 就是现有 Web 界面：窗口直接加载 http://127.0.0.1:<port>/?token=...，
//     不复制前端代码，profile / 插件 / 兼容运行时完全沿用。
//   - 但**接管整个服务进程**：服务由本壳拉起（start-web.sh --no-open），
//     退出时结束整个进程组；关窗口只是隐藏到托盘，服务继续运行。
//
// 托盘：打开 Agent（显示并聚焦窗口）/ 在浏览器打开 / 重启服务 / 退出。
const { app, BrowserWindow, Menu, Tray, dialog, ipcMain, nativeImage, shell } = require('electron')
const { spawn, execFileSync } = require('node:child_process')
const fs = require('node:fs')
const http = require('node:http')
const path = require('node:path')
const updater = require('./updater')

const DEST = process.env.DSH_DEST || '/deepseek-harness'
const PORT = Number(process.env.DSH_PORT || 3080)
const START_SCRIPT = path.join(DEST, 'start-web.sh')
const LOG_FILE = path.join(process.env.HOME || '/tmp', '.dsh-desktop.log')
const TOKEN_PATTERN = /dsh web:\s*(http:\/\/\S+)/
const STARTUP_TIMEOUT_MS = 120000

let mainWindow = null
let tray = null
let serverChild = null
let serverUrl = null
let starting = false
let quitting = false

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

function log(message) {
  try {
    fs.appendFileSync(LOG_FILE, `${new Date().toISOString()} ${message}\n`)
  } catch (error) {
    /* 日志写失败不影响主流程 */
  }
}

function probePort() {
  return new Promise((resolve) => {
    const request = http.get({ host: '127.0.0.1', port: PORT, path: '/', timeout: 1500 }, (response) => {
      response.resume()
      resolve(true)
    })
    request.on('error', () => resolve(false))
    request.on('timeout', () => { request.destroy(); resolve(false) })
  })
}

/** 按安装路径精确匹配，停掉可能残留的旧服务进程（本机只应有一个）。 */
function pkillServer() {
  try {
    execFileSync('pkill', ['-f', `${DEST}/app/node_modules/@deepseek-ai/dsh/lib/bin.js web`])
  } catch (error) {
    /* 没有匹配进程 */
  }
}

/** 结束本壳拉起的服务进程组（detached → 自成一组）。 */
async function stopServer() {
  const child = serverChild
  serverChild = null
  serverUrl = null
  if (child === null) {
    pkillServer()
    return
  }
  const pid = child.pid
  try {
    process.kill(-pid, 'SIGTERM')
  } catch (error) {
    log(`stopServer SIGTERM ${pid}: ${error.message}`)
  }
  for (let attempt = 0; attempt < 20; attempt += 1) {
    try {
      process.kill(-pid, 0)
    } catch (error) {
      break
    }
    await sleep(200)
  }
  try {
    process.kill(-pid, 'SIGKILL')
  } catch (error) {
    /* 已退出 */
  }
  pkillServer()
  log(`server stopped (pid group ${pid})`)
}

function startServer() {
  return new Promise((resolve, reject) => {
    log(`starting ${START_SCRIPT}`)
    let child
    try {
      child = spawn(START_SCRIPT, ['--no-open'], {
        cwd: DEST,
        detached: true,
        env: { ...process.env, DISPLAY: process.env.DISPLAY || ':0' },
        stdio: ['ignore', 'pipe', 'pipe'],
      })
    } catch (error) {
      reject(error)
      return
    }
    serverChild = child
    let settled = false
    const consume = (buffer) => {
      const text = buffer.toString()
      log(`server: ${text.trimEnd()}`)
      const match = TOKEN_PATTERN.exec(text)
      if (match !== null && !settled) {
        settled = true
        serverUrl = match[1]
        resolve(serverUrl)
      }
    }
    child.stdout?.on('data', consume)
    child.stderr?.on('data', consume)
    child.on('exit', (code, signal) => {
      log(`server exited code=${code} signal=${signal}`)
      if (serverChild === child) serverChild = null
      if (!settled) {
        settled = true
        reject(new Error(`服务启动失败（退出码 ${code ?? signal}）`))
      }
    })
    setTimeout(() => {
      if (!settled) {
        settled = true
        reject(new Error('服务在 120 秒内没有打印 token'))
      }
    }, STARTUP_TIMEOUT_MS)
  })
}

async function ensureServer() {
  if (serverUrl !== null) return serverUrl
  if (starting) return null
  starting = true
  try {
    if (await probePort()) {
      log('port busy: stopping previous instance so this shell owns the service')
      pkillServer()
      for (let attempt = 0; attempt < 25; attempt += 1) {
        await sleep(300)
        if (!(await probePort())) break
      }
    }
    return await startServer()
  } finally {
    starting = false
  }
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1440,
    height: 900,
    minWidth: 960,
    minHeight: 640,
    title: 'DeepSeek Harness',
    show: false,
    autoHideMenuBar: true,
    icon: path.join(__dirname, 'icon.png'),
    webPreferences: { contextIsolation: true, nodeIntegration: false },
  })
  mainWindow.once('ready-to-show', () => mainWindow?.show())
  // 关窗口 = 隐藏到托盘；退出走托盘菜单（或 before-quit），保证服务被一起结束。
  mainWindow.on('close', (event) => {
    if (quitting) return
    event.preventDefault()
    mainWindow?.hide()
  })
  // 页面里的外链交给系统浏览器，不在壳里开新窗口。
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    void shell.openExternal(url)
    return { action: 'deny' }
  })
  void mainWindow.loadFile(path.join(__dirname, 'loading.html'))
}

function openAgent() {
  if (mainWindow === null) createWindow()
  mainWindow?.show()
  mainWindow?.focus()
  if (serverUrl === null) void loadUi()
}

async function loadUi() {
  try {
    const url = await ensureServer()
    if (url === null || mainWindow === null) return
    log(`loading ${url}`)
    await mainWindow.loadURL(url)
  } catch (error) {
    log(`loadUi failed: ${error.message}`)
    dialog.showErrorBox('DeepSeek Harness 启动失败', String(error.message ?? error))
  }
}

function openInBrowser() {
  const url = serverUrl ?? `http://127.0.0.1:${PORT}/`
  log(`open in browser: ${url}`)
  void shell.openExternal(url)
}

async function restartServer() {
  log('restart requested')
  await stopServer()
  if (mainWindow !== null) await mainWindow.loadFile(path.join(__dirname, 'loading.html'))
  await loadUi()
}

function buildTray() {
  const image = nativeImage.createFromPath(path.join(__dirname, 'tray.png'))
  tray = new Tray(image)
  tray.setToolTip('DeepSeek Harness')
  const installed = updater.installedVersion()
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: '打开 Agent', click: () => openAgent() },
    { label: '在浏览器打开', click: () => openInBrowser() },
    { type: 'separator' },
    { label: '检查更新', click: () => { void checkForUpdates() } },
    { label: '重启服务', click: () => { void restartServer() } },
    { type: 'separator' },
    { label: `当前版本: ${installed?.version ?? '未知'}`, enabled: false },
    { label: '退出', click: () => quitApplication() },
  ]))
  tray.on('click', () => openAgent())
}

// ===== 自动升级（内网静态清单 + 壳内驱动） =====
// 规则：
//   - 启动时检查一次；运行中每 1 小时静默检查；托盘可手动检查；
//   - 强制更新由清单的 minVersion 判定：本机版本 < minVersion 时**不启动 DSH 本体**，
//     直接显示强制更新窗口；
//   - 普通（建议）更新在对话框里问一句。
const AUTO = process.env.DSH_DESKTOP_AUTOTEST === 'update'
const CHECK_INTERVAL_MS = 60 * 60 * 1000
let upgrading = false
let progressWindow = null
let forcedWindow = null
let forcedState = null
let pendingUpdate = null
let periodicTimer = null

function createProgressWindow() {
  progressWindow = new BrowserWindow({
    width: 460,
    height: 190,
    title: '正在升级 DeepSeek Harness',
    resizable: false,
    minimizable: false,
    maximizable: false,
    alwaysOnTop: true,
    autoHideMenuBar: true,
    webPreferences: { contextIsolation: true, nodeIntegration: false },
  })
  progressWindow.loadFile(path.join(__dirname, 'progress.html'))
  return new Promise((resolve) => { progressWindow.webContents.once('did-finish-load', resolve) })
}

function reportProgress(progress) {
  if (progressWindow === null) return
  const ratio = progress.total ? progress.received / progress.total : progress.phase === 'installing' ? 1 : 0
  const label = progress.phase === 'installing'
    ? '正在安装（约 3–5 分钟，请勿关闭）'
    : `${(progress.received / 1048576).toFixed(1)} / ${((progress.total ?? 0) / 1048576).toFixed(1)} MB`
  const title = progress.phase === 'installing' ? '正在安装升级包…' : '正在下载升级包…'
  progressWindow?.webContents
    .executeJavaScript(`window.setProgress(${ratio}, ${JSON.stringify(label)}); window.setPhase(${JSON.stringify(title)})`)
    .catch(() => {})
}

/** 统一提示：AUTO（无人值守演练）模式下只写日志，不弹窗。 */
function notify(message, detail, isError = false) {
  if (AUTO) {
    log(`notify${isError ? '[error]' : ''}: ${message}${detail ? ` / ${detail}` : ''}`)
    return
  }
  if (isError) dialog.showErrorBox(message, detail ?? '')
  else dialog.showMessageBoxSync({ type: 'info', title: '检查更新', message, detail })
}

// ---- 强制更新窗口（不启动 DSH 本体时显示） ----
function showForcedWindow(state) {
  forcedState = state
  if (forcedWindow !== null) {
    forcedWindow.show()
    forcedWindow.focus()
    return
  }
  forcedWindow = new BrowserWindow({
    width: 760,
    height: 540,
    title: '需要更新后才能继续使用',
    resizable: false,
    minimizable: false,
    maximizable: false,
    autoHideMenuBar: true,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      preload: path.join(__dirname, 'preload.js'),
    },
  })
  forcedWindow.on('closed', () => { forcedWindow = null })
  void forcedWindow.loadFile(path.join(__dirname, 'forced.html'))
}

ipcMain.on('force-data', (event) => {
  const state = forcedState
  event.returnValue = state === null
    ? {}
    : {
        installed: state.installed?.version ?? 'unknown',
        minVersion: state.manifest.minVersion ?? '',
        latest: state.manifest.version,
        dshVersion: state.manifest.dshVersion ?? '',
        notes: state.manifest.notes ?? '',
      }
})
ipcMain.on('force-upgrade', () => {
  if (forcedState !== null) void upgradeAndRestart(forcedState)
})
ipcMain.on('force-quit', () => quitApplication())

/** 执行升级：进度窗 → 下载校验 → 备份安装 → 重启。 */
async function upgradeAndRestart(result) {
  if (upgrading) return
  upgrading = true
  let progressReady = false
  try {
    const manifest = result.manifest
    await createProgressWindow()
    progressReady = true
    reportProgress({ received: 0, total: manifest.size })
    const tarball = await updater.fetchPackage(manifest, result.config, { log, onProgress: reportProgress })
    const installed = updater.installPackage(tarball, { config: result.config, log, onProgress: reportProgress })
    progressWindow?.close()
    progressWindow = null
    notify(`已升级到 ${installed?.version ?? manifest.version}`)
    log(`upgrade done -> ${installed?.version ?? manifest.version}`)
    await stopServer()
    app.relaunch()
    app.exit(0)
  } catch (error) {
    log(`upgrade failed: ${error.message}`)
    if (progressReady) { progressWindow?.close(); progressWindow = null }
    notify('升级失败', String(error.message ?? error), true)
  } finally {
    upgrading = false
  }
}

/** 手动 / 每小时静默检查。silent=true 时只有强制更新才打扰用户。 */
async function checkForUpdates({ silent = false } = {}) {
  if (upgrading) return
  const result = await updater.check({ log })
  if (result.status === 'no-config') {
    if (!silent) notify('未配置更新源', result.message)
    return
  }
  if (result.status === 'error') {
    if (!silent) notify('检查更新失败', result.message, true)
    return
  }
  if (result.status === 'up-to-date') {
    if (!silent) notify(result.message)
    return
  }
  if (result.forced) {
    log('check: 命中强制更新（停止服务并显示强制更新窗口）')
    await stopServer()
    showForcedWindow(result)
    return
  }
  pendingUpdate = result
  if (silent) {
    log(`check: 发现新版本 ${result.manifest.version}（静默，等用户从托盘升级）`)
    return
  }
  if (AUTO) {
    log('autotest: 跳过确认，直接升级')
    await upgradeAndRestart(result)
    return
  }
  const manifest = result.manifest
  const detail = [
    `当前版本: ${result.installed?.version ?? '未知'}`,
    `新版本:   ${manifest.version}`,
    manifest.dshVersion ? `dsh:      ${manifest.dshVersion}` : '',
    manifest.publishedAt ? `发布时间: ${manifest.publishedAt}` : '',
    manifest.notes ? `\n更新说明:\n${manifest.notes}` : '',
  ].filter(Boolean).join('\n')
  const answer = dialog.showMessageBoxSync({
    type: 'question',
    title: '发现新版本',
    message: `发现新版本 ${manifest.version}`,
    detail,
    buttons: ['现在升级', '稍后'],
    defaultId: 0,
    cancelId: 1,
  })
  if (answer === 0) await upgradeAndRestart(result)
}

/**
 * 启动闸门。返回 true = 正常启动 DSH 本体；false = 已进入强制更新界面。
 * 拉不到清单时按"离线可用"处理（不能因为更新服务器挂了就让所有人开不了机）。
 */
async function startupGate() {
  let result
  try {
    result = await updater.check({ log })
  } catch (error) {
    log(`startup: 更新检查异常（按离线继续）: ${error.message}`)
    return true
  }
  if (result.status === 'available' && result.forced) {
    log(`startup: 强制更新 本地 ${result.installed?.version ?? 'unknown'} < 最低 ${result.manifest.minVersion}`)
    showForcedWindow(result)
    return false
  }
  if (result.status === 'available') {
    pendingUpdate = result
    log(`startup: 发现新版本 ${result.manifest.version}`)
  } else if (result.status === 'up-to-date') {
    log('startup: 已是最新')
  } else if (result.status === 'error') {
    log(`startup: 更新检查失败（按离线继续）: ${result.message}`)
  } else {
    log('startup: 未配置更新源')
  }
  return true
}

function startPeriodicCheck() {
  if (periodicTimer !== null) return
  periodicTimer = setInterval(() => { void checkForUpdates({ silent: true }) }, CHECK_INTERVAL_MS)
  log('update: 每小时静默检查已启用')
}

function quitApplication() {
  quitting = true
  void stopServer().finally(() => app.quit())
}

// 系统关机 / kill / 会话注销时也要把服务一起结束，避免残留进程占着端口。
for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) {
  process.on(signal, () => {
    quitting = true
    void stopServer().finally(() => app.exit(0))
  })
}

const gotLock = app.requestSingleInstanceLock()
if (!gotLock) {
  app.quit()
} else {
  app.on('second-instance', () => openAgent())
  app.on('before-quit', () => { quitting = true })
  app.on('window-all-closed', () => { /* 托盘常驻 */ })
  app.whenReady().then(async () => {
    buildTray()
    // 启动闸门：命中强制更新时不启动 DSH 本体，只显示强制更新窗口。
    const shouldStartServer = await startupGate()
    if (!shouldStartServer) {
      log('startup: 强制更新模式（未启动 DSH 本体）')
      return
    }
    createWindow()
    await loadUi()
    startPeriodicCheck()
    // 启动时发现"建议更新"：问一次（AUTO 演练则直接升级）。
    if (pendingUpdate !== null) {
      log('startup: 提示建议更新')
      void checkForUpdates()
    }
    // 自动验收（仅测试用）：验证"在浏览器打开"与"退出即结束整个服务进程"两条路径。
    if (process.env.DSH_DESKTOP_AUTOTEST === 'quit') {
      log('autotest: openInBrowser then quit')
      openInBrowser()
      setTimeout(() => quitApplication(), 2000)
    }
    // 自动验收（仅测试用）：完整走一遍"检查更新 → 下载 → 校验 → 安装 → 重启"。
    if (process.env.DSH_DESKTOP_AUTOTEST === 'update') {
      log('autotest: checkForUpdates')
      setTimeout(() => { void checkForUpdates() }, 5000)
    }
  })
}
