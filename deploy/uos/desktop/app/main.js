// DeepSeek Harness 桌面壳（Electron）。
//
// 职责边界：
//   - UI 就是现有 Web 界面：窗口直接加载 http://127.0.0.1:<port>/?token=...，
//     不复制前端代码，profile / 插件 / 兼容运行时完全沿用。
//   - 但**接管整个服务进程**：服务由本壳拉起（start-web.sh --no-open），
//     退出时结束整个进程组；关窗口只是隐藏到托盘，服务继续运行。
//
// 托盘：打开 Agent（显示并聚焦窗口）/ 在浏览器打开 / 重启服务 / 退出。
const { app, BrowserWindow, Menu, Tray, dialog, nativeImage, shell } = require('electron')
const { spawn, execFileSync } = require('node:child_process')
const fs = require('node:fs')
const http = require('node:http')
const path = require('node:path')

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
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: '打开 Agent', click: () => openAgent() },
    { label: '在浏览器打开', click: () => openInBrowser() },
    { type: 'separator' },
    { label: '重启服务', click: () => { void restartServer() } },
    { label: '退出', click: () => quitApplication() },
  ]))
  tray.on('click', () => openAgent())
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
    createWindow()
    await loadUi()
    // 自动验收（仅测试用）：验证"在浏览器打开"与"退出即结束整个服务进程"两条路径。
    if (process.env.DSH_DESKTOP_AUTOTEST === 'quit') {
      log('autotest: openInBrowser then quit')
      openInBrowser()
      setTimeout(() => quitApplication(), 2000)
    }
  })
}
