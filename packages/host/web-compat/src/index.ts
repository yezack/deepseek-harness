/**
 * @deepseek-ai/dsh-host-web-compat — legacy-browser compatibility for the Web
 * shell. Injects one classic script as the first element of the served head,
 * ahead of every structured injection row and every parser-blocking bundle, so
 * the polyfills exist before the boot tail (`Promise.withResolvers`), before the
 * bootstrap module-loader queue, and before the shell's own entry.
 *
 * The injection is an index tap rather than a `webserver/index-inject` row: the
 * injection table renders in registration order, and the bootstrap `script-src`
 * rows execute during parsing, so only a tap — applied after row rendering —
 * can place this script ahead of a row contributed by another plugin. The tap
 * body is deterministic html-to-html text with no per-request state.
 *
 * The script is idempotent and self-disabling: every polyfill is installed only
 * when the kernel lacks it, and the `color-mix()` pass returns immediately where
 * the engine supports the function. On a current browser the injected bytes are
 * the whole cost.
 *
 * @module @deepseek-ai/dsh-host-web-compat
 */

import type { Context } from '@deepseek-ai/cordis'
import type {} from '@deepseek-ai/dsh-host-webserver'
import { compatScript } from './compat-script.ts'

/** Stable Cordis plugin name. */
export const name = 'web-compat'

/** Services required before the head tap can be installed. */
export const inject = ['webServer']

/** Marker attribute letting an operator confirm the injection from page source. */
const MARKER = 'data-dsh-web-compat'

/**
 * Place `markup` immediately after the opening head tag, which is ahead of every
 * already-rendered injection row.
 * @param html - the rendered index document.
 * @param markup - the script element to place first.
 * @returns the document with `markup` as the first head child.
 */
function injectFirstInHead(html: string, markup: string): string {
  const open = /<head(?:\s[^>]*)?>/i.exec(html)
  // A fragment without <head> is prepended: the parser then runs the script
  // ahead of every document script either way.
  if (open === null) return markup + html
  const at = open.index + open[0].length
  return html.slice(0, at) + markup + html.slice(at)
}

/**
 * Install the compatibility injection for every served index document.
 * @param ctx - the plugin context carrying the webserver service.
 */
export function apply(ctx: Context): void {
  const markup = '<script ' + MARKER + '>' + compatScript() + '</script>'
  ctx.effect(
    () => ctx.webServer.tapIndex(html => injectFirstInHead(html, markup)),
    'web-compat: legacy-browser polyfills and color-mix fallback',
  )
}
