#!/usr/bin/env node
/*
 * cdp-lite-mcp — a Chrome DevTools Protocol MCP server with no puppeteer.
 *
 * Why this exists: on vendor Chromium builds, puppeteer-based MCP servers can
 * initialise and list their tools yet never complete a real operation, because
 * the failure sits in puppeteer's own connection and session layer rather than
 * in the browser's CDP endpoint. A native CDP client works against the same
 * browser. This server therefore speaks CDP directly over the built-in fetch
 * and WebSocket, so the only requirement is what already works by hand:
 *
 *     curl http://127.0.0.1:9222/json/version
 *
 * Zero runtime dependencies. Node >= 22 (global fetch + global WebSocket).
 *
 * Usage:
 *     node cdp-lite-mcp.js [--endpoint http://127.0.0.1:9222]
 * Environment:
 *     DSH_CDP_ENDPOINT   same as --endpoint
 *
 * The browser must already be running with --remote-debugging-port. This server
 * never launches a browser, which is deliberate: launching is the step that
 * differs most between builds.
 */

const DEFAULT_ENDPOINT = 'http://127.0.0.1:9222'

function parseArgs(argv) {
  const options = { endpoint: process.env.DSH_CDP_ENDPOINT || DEFAULT_ENDPOINT }
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--endpoint' && argv[i + 1]) {
      options.endpoint = argv[i + 1]
      i += 1
    }
  }
  return options
}

const options = parseArgs(process.argv.slice(2))

/* ---------------------------------------------------------------- transport */

class CdpConnection {
  constructor(url) {
    this.url = url
    this.socket = null
    this.nextId = 1
    this.pending = new Map()
    this.opened = null
  }

  connect() {
    if (this.opened) return this.opened
    this.opened = new Promise((resolve, reject) => {
      let socket
      try {
        // Node's global WebSocket sends no Origin header, which is what keeps
        // this working on builds that reject non-allowlisted origins.
        socket = new WebSocket(this.url)
      } catch (error) {
        reject(new Error(`cannot open WebSocket ${this.url}: ${error.message}`))
        return
      }
      this.socket = socket
      const timer = setTimeout(() => reject(new Error(`timeout connecting to ${this.url}`)), 15000)
      socket.addEventListener('open', () => {
        clearTimeout(timer)
        resolve()
      })
      socket.addEventListener('error', (event) => {
        clearTimeout(timer)
        reject(new Error(`WebSocket error on ${this.url}${event && event.message ? `: ${event.message}` : ''}`))
      })
      socket.addEventListener('message', (event) => this.#onMessage(event.data))
      socket.addEventListener('close', () => {
        for (const [, entry] of this.pending) entry.reject(new Error('CDP socket closed'))
        this.pending.clear()
      })
    })
    return this.opened
  }

  #onMessage(raw) {
    let payload
    try {
      payload = JSON.parse(typeof raw === 'string' ? raw : String(raw))
    } catch {
      return
    }
    if (payload.id === undefined) return
    const entry = this.pending.get(payload.id)
    if (!entry) return
    this.pending.delete(payload.id)
    if (payload.error) entry.reject(new Error(`${payload.error.message || 'CDP error'} (code ${payload.error.code})`))
    else entry.resolve(payload.result)
  }

  /** Send one CDP command, optionally scoped to a flattened session. */
  send(method, params = {}, sessionId) {
    const id = this.nextId
    this.nextId += 1
    const message = { id, method, params }
    if (sessionId) message.sessionId = sessionId
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(`timeout: ${method} did not answer within 30s`))
      }, 30000)
      this.pending.set(id, {
        resolve: (value) => {
          clearTimeout(timer)
          resolve(value)
        },
        reject: (error) => {
          clearTimeout(timer)
          reject(error)
        },
      })
      this.socket.send(JSON.stringify(message))
    })
  }

  close() {
    try {
      if (this.socket) this.socket.close()
    } catch {
      /* already gone */
    }
  }
}

let connection = null

async function cdp() {
  if (connection === null) {
    const endpoint = options.endpoint.replace(/\/+$/, '')
    let version
    try {
      const response = await fetch(`${endpoint}/json/version`)
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      version = await response.json()
    } catch (error) {
      throw new Error(`cannot reach the CDP endpoint at ${endpoint}/json/version: ${error.message}`)
    }
    if (!version.webSocketDebuggerUrl) {
      throw new Error(`${endpoint}/json/version returned no webSocketDebuggerUrl`)
    }
    connection = new CdpConnection(version.webSocketDebuggerUrl)
    await connection.connect()
  }
  return connection
}

/* -------------------------------------------------------------- target glue */

/** Attach to a page target and return its flattened session id. */
async function attachPage(pageId) {
  const client = await cdp()
  const { sessionId } = await client.send('Target.attachToTarget', { targetId: pageId, flatten: true })
  return { client, sessionId }
}

async function listPageTargets() {
  const client = await cdp()
  const { targetInfos } = await client.send('Target.getTargets')
  return targetInfos.filter((info) => info.type === 'page')
}

/** Accept either a raw target id or a 1-based index from a previous list. */
async function resolvePage(ref) {
  const pages = await listPageTargets()
  if (ref === undefined || ref === null || ref === '') return pages[pages.length - 1]
  const asIndex = Number(ref)
  if (Number.isInteger(asIndex) && asIndex >= 1 && asIndex <= pages.length) return pages[asIndex - 1]
  return pages.find((page) => page.targetId === ref) || null
}

function describePages(pages, activeId) {
  if (pages.length === 0) return 'no pages are open'
  return pages
    .map((page, index) => {
      const marker = page.targetId === activeId ? ' [selected]' : ''
      return `${index + 1}: ${page.url || 'about:blank'}${marker}`
    })
    .join('\n')
}

/* ------------------------------------------------------------------- tools */

const TOOLS = [
  {
    name: 'list_pages',
    description: 'List the open pages in the attached browser.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    handler: async () => {
      const pages = await listPageTargets()
      return describePages(pages, null)
    },
  },
  {
    name: 'new_page',
    description: 'Open a new page at the given URL and return its id.',
    inputSchema: {
      type: 'object',
      properties: { url: { type: 'string', description: 'URL to open. Defaults to about:blank.' } },
      additionalProperties: false,
    },
    handler: async (args) => {
      const client = await cdp()
      const { targetId } = await client.send('Target.createTarget', { url: args.url || 'about:blank' })
      const pages = await listPageTargets()
      return `opened ${targetId}\n${describePages(pages, targetId)}`
    },
  },
  {
    name: 'close_page',
    description: 'Close a page by target id or by its index from list_pages.',
    inputSchema: {
      type: 'object',
      properties: { page: { type: 'string', description: 'Target id, or 1-based index.' } },
      required: ['page'],
      additionalProperties: false,
    },
    handler: async (args) => {
      const page = await resolvePage(args.page)
      if (!page) throw new Error(`no page matches ${args.page}`)
      const client = await cdp()
      await client.send('Target.closeTarget', { targetId: page.targetId })
      return `closed ${page.targetId}`
    },
  },
  {
    name: 'navigate',
    description: 'Navigate a page to a URL and wait for the load event.',
    inputSchema: {
      type: 'object',
      properties: {
        url: { type: 'string' },
        page: { type: 'string', description: 'Target id or 1-based index. Defaults to the newest page.' },
      },
      required: ['url'],
      additionalProperties: false,
    },
    handler: async (args) => {
      const page = await resolvePage(args.page)
      if (!page) throw new Error(`no page matches ${args.page}`)
      const { client, sessionId } = await attachPage(page.targetId)
      await client.send('Page.enable', {}, sessionId)
      await client.send('Page.navigate', { url: args.url }, sessionId)
      // Page.loadEventFired is not awaited: a page that never fires it would
      // hang the tool, and a short settle is enough for a readable DOM.
      await new Promise((resolve) => setTimeout(resolve, 1200))
      const { result } = await client.send('Runtime.evaluate', {
        expression: 'document.title + " | " + location.href',
        returnByValue: true,
      }, sessionId)
      return `navigated to ${args.url}\ntitle/url: ${result.value}`
    },
  },
  {
    name: 'evaluate',
    description: 'Evaluate a JavaScript expression in a page and return its value.',
    inputSchema: {
      type: 'object',
      properties: {
        expression: { type: 'string' },
        page: { type: 'string', description: 'Target id or 1-based index. Defaults to the newest page.' },
      },
      required: ['expression'],
      additionalProperties: false,
    },
    handler: async (args) => {
      const page = await resolvePage(args.page)
      if (!page) throw new Error(`no page matches ${args.page}`)
      const { client, sessionId } = await attachPage(page.targetId)
      await client.send('Runtime.enable', {}, sessionId)
      const outcome = await client.send('Runtime.evaluate', {
        expression: args.expression,
        returnByValue: true,
        awaitPromise: true,
      }, sessionId)
      if (outcome.exceptionDetails) {
        const text = outcome.exceptionDetails.exception
          ? outcome.exceptionDetails.exception.description
          : outcome.exceptionDetails.text
        throw new Error(`evaluation threw: ${text}`)
      }
      const value = outcome.result ? outcome.result.value : undefined
      return typeof value === 'string' ? value : JSON.stringify(value, null, 2)
    },
  },
  {
    name: 'screenshot',
    description: 'Capture a PNG screenshot of a page, returned as base64.',
    inputSchema: {
      type: 'object',
      properties: { page: { type: 'string', description: 'Target id or 1-based index.' } },
      additionalProperties: false,
    },
    handler: async (args) => {
      const page = await resolvePage(args.page)
      if (!page) throw new Error(`no page matches ${args.page}`)
      const { client, sessionId } = await attachPage(page.targetId)
      await client.send('Page.enable', {}, sessionId)
      const { data } = await client.send('Page.captureScreenshot', { format: 'png' }, sessionId)
      return `base64 PNG (${data.length} chars):\n${data}`
    },
  },
  {
    name: 'page_content',
    description: 'Return the current DOM of a page as HTML.',
    inputSchema: {
      type: 'object',
      properties: { page: { type: 'string', description: 'Target id or 1-based index.' } },
      additionalProperties: false,
    },
    handler: async (args) => {
      const page = await resolvePage(args.page)
      if (!page) throw new Error(`no page matches ${args.page}`)
      const { client, sessionId } = await attachPage(page.targetId)
      await client.send('Runtime.enable', {}, sessionId)
      const { result } = await client.send('Runtime.evaluate', {
        expression: 'document.documentElement.outerHTML',
        returnByValue: true,
      }, sessionId)
      return result.value
    },
  },
  {
    name: 'cdp_version',
    description: 'Report the browser build and the CDP endpoint this server attached to.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    handler: async () => {
      const endpoint = options.endpoint.replace(/\/+$/, '')
      const response = await fetch(`${endpoint}/json/version`)
      const version = await response.json()
      return `endpoint: ${endpoint}\n${JSON.stringify(version, null, 2)}`
    },
  },
]

/* ------------------------------------------------------------ MCP plumbing */

const SERVER_INFO = { name: 'cdp-lite', title: 'CDP Lite MCP server', version: '1.0.0' }

function write(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`)
}

function reply(id, result) {
  write({ jsonrpc: '2.0', id, result })
}

function replyError(id, code, message) {
  write({ jsonrpc: '2.0', id, error: { code, message } })
}

async function handleToolCall(id, params) {
  const tool = TOOLS.find((entry) => entry.name === params.name)
  if (!tool) {
    replyError(id, -32602, `unknown tool: ${params.name}`)
    return
  }
  try {
    const text = await tool.handler(params.arguments || {})
    reply(id, { content: [{ type: 'text', text: text === undefined ? '' : String(text) }] })
  } catch (error) {
    // Report as a tool error rather than a protocol error, so the caller sees
    // the CDP message instead of a transport failure.
    reply(id, { content: [{ type: 'text', text: error.message }], isError: true })
  }
}

async function handle(message) {
  const { id, method, params } = message
  if (method === 'initialize') {
    reply(id, {
      protocolVersion: '2024-11-05',
      capabilities: { tools: { listChanged: false } },
      serverInfo: SERVER_INFO,
    })
    return
  }
  if (method === 'notifications/initialized' || method === 'notifications/cancelled') return
  if (method === 'ping') {
    reply(id, {})
    return
  }
  if (method === 'tools/list') {
    reply(id, {
      tools: TOOLS.map((tool) => ({
        name: tool.name,
        description: tool.description,
        inputSchema: tool.inputSchema,
      })),
    })
    return
  }
  if (method === 'tools/call') {
    await handleToolCall(id, params || {})
    return
  }
  if (id !== undefined) replyError(id, -32601, `method not found: ${method}`)
}

let buffer = ''
/* Declared before the reader so the handler below cannot observe it in the
 * temporal dead zone. */
let queue = Promise.resolve()

process.stdin.setEncoding('utf8')
process.stdin.on('data', (chunk) => {
  buffer += chunk
  let index = buffer.indexOf('\n')
  while (index !== -1) {
    const line = buffer.slice(0, index).trim()
    buffer = buffer.slice(index + 1)
    if (line !== '') {
      let message
      try {
        message = JSON.parse(line)
      } catch {
        message = null
      }
      if (message) {
        // Serialised so two tool calls cannot interleave their CDP traffic.
        queue = queue.then(() => handle(message)).catch(() => {})
      }
    }
    index = buffer.indexOf('\n')
  }
})

// A client that closes stdin right after writing its requests (a shell pipeline,
// a test harness) would otherwise cut the still-queued calls off with no reply.
process.stdin.on('end', () => {
  queue.then(() => {
    if (connection) connection.close()
    process.exit(0)
  })
})

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    if (connection) connection.close()
    process.exit(0)
  })
}
