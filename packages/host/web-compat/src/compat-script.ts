/**
 * Browser-side compatibility source injected into every served index page.
 *
 * Two independent jobs, both idempotent:
 *
 * 1. Runtime APIs the client bundles and the boot script call directly but a
 *    legacy kernel does not provide. The highest required floor in this tree is
 *    `Promise.withResolvers` (Chrome 119), which the served boot tail
 *    (`renderIndexInjections`'s readiness script) calls before any client
 *    bundle runs, so a missing polyfill fails the whole plugin tree.
 * 2. A `color-mix()` fallback. The design tokens express tints and borders as
 *    `color-mix(in srgb, var(--token) N%, transparent)`, which a kernel before
 *    Chrome 111 drops as an invalid declaration. Because every operand is a
 *    live custom property, no build-time transform can resolve it; this pass
 *    resolves the operands against the current theme at runtime and re-runs
 *    when the theme changes.
 *
 * The emitted text is a single classic script with one top-level IIFE. Every
 * internal statement is ordinary ES2022 syntax, which the target kernels parse:
 * only the runtime APIs above are missing, not the grammar.
 *
 * @module @deepseek-ai/dsh-host-web-compat/compat-script
 */

/**
 * The compat script as served text. Written without template placeholders so it
 * needs no escaping, and it ends on a complete statement so an HTML parser can
 * concatenate nothing after it.
 * @returns the script body, without a surrounding `<script>` element.
 */
export function compatScript(): string {
  return COMPAT_SCRIPT_SOURCE
}

const COMPAT_SCRIPT_SOURCE = String.raw`(function () {
  'use strict'
  var g = typeof globalThis !== 'undefined' ? globalThis : window
  if (g.__DSH_WEB_COMPAT__ === true) return
  g.__DSH_WEB_COMPAT__ = true

  function define(target, name, value) {
    try {
      Object.defineProperty(target, name, { value: value, writable: true, enumerable: false, configurable: true })
    } catch (error) {
      /* A non-configurable seat keeps whatever it already provides. */
    }
  }

  /* ---------- JavaScript runtime APIs ---------- */

  if (typeof Promise.withResolvers !== 'function') {
    define(Promise, 'withResolvers', function withResolvers() {
      var resolve, reject
      var promise = new Promise(function (res, rej) { resolve = res; reject = rej })
      return { promise: promise, resolve: resolve, reject: reject }
    })
  }

  if (typeof g.AbortSignal !== 'undefined' && typeof g.AbortSignal.any !== 'function') {
    define(g.AbortSignal, 'any', function any(signals) {
      var controller = new g.AbortController()
      var removers = []
      function release() {
        for (var i = 0; i < removers.length; i += 1) removers[i]()
        removers.length = 0
      }
      function abort(reason) {
        if (!controller.signal.aborted) controller.abort(reason)
        release()
      }
      for (var i = 0; i < signals.length; i += 1) {
        var signal = signals[i]
        if (signal.aborted) { abort(signal.reason); break }
        (function (source) {
          function onAbort() { abort(source.reason) }
          source.addEventListener('abort', onAbort)
          removers.push(function () { source.removeEventListener('abort', onAbort) })
        })(signal)
      }
      if (!controller.signal.aborted) controller.signal.addEventListener('abort', release)
      return controller.signal
    })
  }

  if (typeof g.AbortSignal !== 'undefined' && typeof g.AbortSignal.timeout !== 'function') {
    define(g.AbortSignal, 'timeout', function timeout(milliseconds) {
      var controller = new g.AbortController()
      var timer = setTimeout(function () {
        var failure
        try { failure = new g.DOMException('The operation timed out.', 'TimeoutError') }
        catch (error) { failure = new Error('The operation timed out.'); failure.name = 'TimeoutError' }
        controller.abort(failure)
      }, milliseconds)
      if (timer && typeof timer.unref === 'function') timer.unref()
      return controller.signal
    })
  }

  if (typeof g.structuredClone !== 'function') {
    /* A JSON round-trip would corrupt the binary and keyed values the client
    passes through here (attachments, caches), so the fallback walks the graph. */
    define(g, 'structuredClone', function structuredClone(value) {
      var seen = new g.Map()
      function copy(input) {
        if (input === null || typeof input !== 'object') return input
        if (seen.has(input)) return seen.get(input)
        var tag = Object.prototype.toString.call(input)
        if (tag === '[object Date]') return new g.Date(input.getTime())
        if (tag === '[object RegExp]') return new g.RegExp(input.source, input.flags)
        if (tag === '[object ArrayBuffer]') return input.slice(0)
        if (g.ArrayBuffer.isView(input)) {
          if (input instanceof g.DataView) return new g.DataView(copy(input.buffer), input.byteOffset, input.byteLength)
          return new input.constructor(input)
        }
        if (tag === '[object Map]') {
          var mapped = new g.Map()
          seen.set(input, mapped)
          input.forEach(function (entryValue, entryKey) { mapped.set(copy(entryKey), copy(entryValue)) })
          return mapped
        }
        if (tag === '[object Set]') {
          var collected = new g.Set()
          seen.set(input, collected)
          input.forEach(function (entryValue) { collected.add(copy(entryValue)) })
          return collected
        }
        if (g.Array.isArray(input)) {
          var list = []
          seen.set(input, list)
          for (var i = 0; i < input.length; i += 1) list.push(copy(input[i]))
          return list
        }
        var object = {}
        seen.set(input, object)
        var keys = Object.keys(input)
        for (var j = 0; j < keys.length; j += 1) object[keys[j]] = copy(input[keys[j]])
        return object
      }
      return copy(value)
    })
  }

  if (typeof Object.hasOwn !== 'function') {
    define(Object, 'hasOwn', function hasOwn(target, property) {
      return Object.prototype.hasOwnProperty.call(target, property)
    })
  }

  if (typeof Object.groupBy !== 'function') {
    define(Object, 'groupBy', function groupBy(items, callback) {
      var out = Object.create(null)
      var index = 0
      for (var item of items) {
        var key = callback(item, index)
        index += 1
        var bucket = out[key]
        if (bucket === undefined) { bucket = []; define(out, key, bucket) }
        bucket.push(item)
      }
      return out
    })
  }

  if (typeof g.Map.groupBy !== 'function') {
    define(g.Map, 'groupBy', function groupBy(items, callback) {
      var out = new g.Map()
      var index = 0
      for (var item of items) {
        var key = callback(item, index)
        index += 1
        var bucket = out.get(key)
        if (bucket === undefined) { bucket = []; out.set(key, bucket) }
        bucket.push(item)
      }
      return out
    })
  }

  var arrayPrototype = g.Array.prototype
  var slice = arrayPrototype.slice

  if (typeof arrayPrototype.at !== 'function') {
    define(arrayPrototype, 'at', function at(index) {
      var length = this.length >>> 0
      var relative = Math.trunc(index) || 0
      var resolved = relative < 0 ? length + relative : relative
      return resolved < 0 || resolved >= length ? undefined : this[resolved]
    })
  }

  if (typeof arrayPrototype.toSorted !== 'function') {
    define(arrayPrototype, 'toSorted', function toSorted(compare) {
      var copy = slice.call(this)
      return compare === undefined ? copy.sort() : copy.sort(compare)
    })
  }

  if (typeof arrayPrototype.toReversed !== 'function') {
    define(arrayPrototype, 'toReversed', function toReversed() {
      return slice.call(this).reverse()
    })
  }

  if (typeof arrayPrototype.toSpliced !== 'function') {
    define(arrayPrototype, 'toSpliced', function toSpliced(start, deleteCount) {
      var copy = slice.call(this)
      if (arguments.length === 0) return copy
      if (arguments.length === 1) { copy.splice(start); return copy }
      var call = [start, deleteCount].concat(slice.call(arguments, 2))
      arrayPrototype.splice.apply(copy, call)
      return copy
    })
  }

  if (typeof arrayPrototype.with !== 'function') {
    define(arrayPrototype, 'with', function withIndex(index, value) {
      var copy = slice.call(this)
      var length = copy.length
      var relative = Math.trunc(index) || 0
      var resolved = relative < 0 ? length + relative : relative
      if (resolved < 0 || resolved >= length) throw new g.RangeError('Invalid index')
      copy[resolved] = value
      return copy
    })
  }

  if (typeof g.Array.fromAsync !== 'function') {
    define(g.Array, 'fromAsync', function fromAsync(items, map, thisArg) {
      return (async function () {
        var out = []
        var index = 0
        for await (var item of items) {
          out.push(map === undefined ? item : await map.call(thisArg, item, index))
          index += 1
        }
        return out
      })()
    })
  }

  if (typeof String.prototype.replaceAll !== 'function') {
    define(String.prototype, 'replaceAll', function replaceAll(search, replacement) {
      var subject = String(this)
      if (search instanceof g.RegExp) {
        if (!search.global) throw new g.TypeError('replaceAll requires a global RegExp')
        return subject.replace(search, replacement)
      }
      return subject.split(String(search)).join(String(replacement))
    })
  }

  if (typeof String.prototype.isWellFormed !== 'function') {
    define(String.prototype, 'isWellFormed', function isWellFormed() {
      return true
    })
  }

  if (typeof g.crypto !== 'undefined' && typeof g.crypto.randomUUID !== 'function') {
    define(g.crypto, 'randomUUID', function randomUUID() {
      var bytes = new Uint8Array(16)
      if (typeof g.crypto.getRandomValues === 'function') g.crypto.getRandomValues(bytes)
      else for (var i = 0; i < 16; i += 1) bytes[i] = Math.floor(Math.random() * 256)
      bytes[6] = (bytes[6] & 15) | 64
      bytes[8] = (bytes[8] & 63) | 128
      var hex = []
      for (var j = 0; j < 16; j += 1) hex.push((bytes[j] + 256).toString(16).slice(1))
      return hex.slice(0, 4).join('') + '-' + hex.slice(4, 6).join('') + '-' + hex.slice(6, 8).join('')
        + '-' + hex.slice(8, 10).join('') + '-' + hex.slice(10, 16).join('')
    })
  }

  var setPrototype = g.Set.prototype
  if (typeof setPrototype.union !== 'function') {
    define(setPrototype, 'union', function union(other) {
      var out = new g.Set(this)
      other.forEach(function (value) { out.add(value) })
      return out
    })
    define(setPrototype, 'intersection', function intersection(other) {
      var out = new g.Set()
      this.forEach(function (value) { if (other.has(value)) out.add(value) })
      return out
    })
    define(setPrototype, 'difference', function difference(other) {
      var out = new g.Set()
      this.forEach(function (value) { if (!other.has(value)) out.add(value) })
      return out
    })
    define(setPrototype, 'symmetricDifference', function symmetricDifference(other) {
      var out = new g.Set()
      var self = this
      this.forEach(function (value) { if (!other.has(value)) out.add(value) })
      other.forEach(function (value) { if (!self.has(value)) out.add(value) })
      return out
    })
    define(setPrototype, 'isSubsetOf', function isSubsetOf(other) {
      var subset = true
      this.forEach(function (value) { if (!other.has(value)) subset = false })
      return subset
    })
    define(setPrototype, 'isSupersetOf', function isSupersetOf(other) {
      var superset = true
      other.forEach(function (value) { if (!this.has(value)) superset = false }, this)
      return superset
    })
    define(setPrototype, 'isDisjointFrom', function isDisjointFrom(other) {
      var disjoint = true
      this.forEach(function (value) { if (other.has(value)) disjoint = false })
      return disjoint
    })
  }

  if (typeof g.Iterator === 'undefined') {
    installIterator()
  }

  function installIterator() {
    var iteratorPrototype = Object.getPrototypeOf(Object.getPrototypeOf([][Symbol.iterator]()))
    function Iterator() { throw new g.TypeError('Abstract class Iterator not directly constructable') }
    /* The global must be a constructor whose prototype IS %IteratorPrototype%:
    bundled libraries patch Iterator.prototype directly, and helper results must
    inherit the same prototype or chained helpers stop being iterators. */
    Iterator.prototype = iteratorPrototype
    if (iteratorPrototype.constructor !== Iterator) define(iteratorPrototype, 'constructor', Iterator)

    function toIterator(value) {
      if (value === null || value === undefined) throw new g.TypeError('value is not iterable')
      if (typeof value.next === 'function') return value
      var method = value[Symbol.iterator]
      if (typeof method !== 'function') throw new g.TypeError('value is not iterable')
      return method.call(value)
    }

    function* mapIterator(source, mapper) {
      var index = 0
      for (var step = source.next(); !step.done; step = source.next()) {
        yield mapper(step.value, index)
        index += 1
      }
    }

    function* filterIterator(source, predicate) {
      var index = 0
      for (var step = source.next(); !step.done; step = source.next()) {
        if (predicate(step.value, index)) yield step.value
        index += 1
      }
    }

    function* takeIterator(source, limit) {
      if (limit <= 0) return
      var remaining = limit
      for (var step = source.next(); !step.done && remaining > 0; step = source.next()) {
        yield step.value
        remaining -= 1
      }
    }

    function* dropIterator(source, limit) {
      var remaining = limit
      for (var step = source.next(); !step.done; step = source.next()) {
        if (remaining > 0) { remaining -= 1; continue }
        yield step.value
      }
    }

    function* flatMapIterator(source, mapper) {
      var index = 0
      for (var step = source.next(); !step.done; step = source.next()) {
        var mapped = mapper(step.value, index)
        index += 1
        for (var inner of mapped) yield inner
      }
    }

    define(iteratorPrototype, 'map', function map(mapper) { return mapIterator(toIterator(this), mapper) })
    define(iteratorPrototype, 'filter', function filter(predicate) { return filterIterator(toIterator(this), predicate) })
    define(iteratorPrototype, 'take', function take(limit) { return takeIterator(toIterator(this), limit) })
    define(iteratorPrototype, 'drop', function drop(limit) { return dropIterator(toIterator(this), limit) })
    define(iteratorPrototype, 'flatMap', function flatMap(mapper) { return flatMapIterator(toIterator(this), mapper) })
    define(iteratorPrototype, 'toArray', function toArray() {
      var iterator = toIterator(this)
      var out = []
      for (var step = iterator.next(); !step.done; step = iterator.next()) out.push(step.value)
      return out
    })
    define(iteratorPrototype, 'forEach', function forEach(callback) {
      var iterator = toIterator(this)
      var index = 0
      for (var step = iterator.next(); !step.done; step = iterator.next()) {
        callback(step.value, index)
        index += 1
      }
    })
    define(iteratorPrototype, 'some', function some(predicate) {
      var iterator = toIterator(this)
      var index = 0
      for (var step = iterator.next(); !step.done; step = iterator.next()) {
        if (predicate(step.value, index)) return true
        index += 1
      }
      return false
    })
    define(iteratorPrototype, 'every', function every(predicate) {
      var iterator = toIterator(this)
      var index = 0
      for (var step = iterator.next(); !step.done; step = iterator.next()) {
        if (!predicate(step.value, index)) return false
        index += 1
      }
      return true
    })
    define(iteratorPrototype, 'find', function find(predicate) {
      var iterator = toIterator(this)
      var index = 0
      for (var step = iterator.next(); !step.done; step = iterator.next()) {
        if (predicate(step.value, index)) return step.value
        index += 1
      }
      return undefined
    })
    define(iteratorPrototype, 'reduce', function reduce(reducer, initial) {
      var iterator = toIterator(this)
      var index = 0
      var accumulator = initial
      var step = iterator.next()
      if (arguments.length < 2) {
        if (step.done) throw new g.TypeError('Reduce of empty iterator with no initial value')
        accumulator = step.value
        step = iterator.next()
        index = 1
      }
      for (; !step.done; step = iterator.next()) {
        accumulator = reducer(accumulator, step.value, index)
        index += 1
      }
      return accumulator
    })
    define(Iterator, 'from', function from(value) { return toIterator(value) })
    define(g, 'Iterator', Iterator)
  }

  /* ---------- CSS color-mix() fallback ---------- */

  installColorMixFallback()

  function installColorMixFallback() {
    if (typeof g.CSS === 'undefined' || typeof g.CSS.supports !== 'function') return
    var supported = false
    try { supported = g.CSS.supports('color', 'color-mix(in srgb, red, blue)') } catch (error) { supported = false }
    if (supported) return

    var probe = null
    var originals = new g.Map()
    var rewriting = false
    var scheduled = false

    function ensureProbe() {
      if (probe !== null && probe.isConnected) return probe
      probe = document.createElement('div')
      probe.setAttribute('aria-hidden', 'true')
      probe.setAttribute('data-dsh-compat-probe', '')
      probe.style.cssText = 'position:absolute!important;left:-99999px!important;top:0!important;'
        + 'width:0!important;height:0!important;overflow:hidden!important;pointer-events:none!important;visibility:hidden!important'
      var host = document.body
      if (host === null) return null
      host.appendChild(probe)
      return probe
    }

    function computed() { return g.getComputedStyle(ensureProbe()) }

    /* Custom properties compute with their var() references already
    substituted, so one lookup resolves a token to a concrete color. */
    function lookupCustomProperty(name) {
      var value = computed().getPropertyValue(name)
      return value === null ? '' : value.trim()
    }

    function splitTopLevel(text, separator) {
      var parts = []
      var depth = 0
      var current = ''
      for (var i = 0; i < text.length; i += 1) {
        var character = text.charAt(i)
        if (character === '(') depth += 1
        else if (character === ')') depth -= 1
        if (character === separator && depth === 0) { parts.push(current); current = ''; continue }
        current += character
      }
      parts.push(current)
      return parts
    }

    function replaceFunction(text, name, replacer) {
      var out = ''
      var index = 0
      var needle = name + '('
      while (index < text.length) {
        var at = text.indexOf(needle, index)
        if (at === -1) { out += text.slice(index); break }
        out += text.slice(index, at)
        var depth = 0
        var end = -1
        for (var i = at + name.length; i < text.length; i += 1) {
          var character = text.charAt(i)
          if (character === '(') depth += 1
          else if (character === ')') {
            depth -= 1
            if (depth === 0) { end = i; break }
          }
        }
        if (end === -1) { out += text.slice(at); break }
        out += replacer(text.slice(at + needle.length, end))
        index = end + 1
      }
      return out
    }

    function resolveVariables(text) {
      var guard = 0
      var out = text
      while (out.indexOf('var(') !== -1 && guard < 16) {
        guard += 1
        var next = replaceFunction(out, 'var', function (inner) {
          var parts = splitTopLevel(inner, ',')
          var name = parts[0].trim()
          var value = lookupCustomProperty(name)
          if (value === '') value = parts.length > 1 ? parts.slice(1).join(',').trim() : ''
          return value === '' ? 'rgba(0,0,0,0)' : value
        })
        if (next === out) break
        out = next
      }
      return out
    }

    function parseAlpha(text) {
      if (text === undefined) return 1
      return text.indexOf('%') === -1 ? parseFloat(text) : parseFloat(text) / 100
    }

    /* The engine parses the operand, so every color syntax it understands is
    covered. Its serialization is rgb()/rgba() for legacy syntax and
    color(srgb ...) when the value came through a modern color function, so
    both forms are read back here. */
    function toRgba(color) {
      var element = ensureProbe()
      if (element === null) return null
      element.style.color = ''
      element.style.color = color
      if (element.style.color === '') return null
      var computedColor = g.getComputedStyle(element).color
      var legacy = /^rgba?\(([^)]+)\)$/.exec(computedColor)
      if (legacy !== null) {
        var parts = legacy[1].split(/[\s,\/]+/).filter(function (part) { return part !== '' })
        if (parts.length < 3) return null
        return {
          r: parseFloat(parts[0]),
          g: parseFloat(parts[1]),
          b: parseFloat(parts[2]),
          a: parseAlpha(parts[3]),
        }
      }
      var wide = /^color\(srgb\s+([\d.]+%?)\s+([\d.]+%?)\s+([\d.]+%?)(?:\s*\/\s*([\d.]+%?))?\)$/.exec(computedColor)
      if (wide === null) return null
      function channel(text) {
        return text.indexOf('%') === -1 ? parseFloat(text) * 255 : parseFloat(text) * 2.55
      }
      return { r: channel(wide[1]), g: channel(wide[2]), b: channel(wide[3]), a: parseAlpha(wide[4]) }
    }

    function parseStop(text) {
      var trimmed = text.trim()
      var percentage = null
      var match = /(-?\d*\.?\d+)%\s*$/.exec(trimmed)
      if (match !== null) {
        percentage = parseFloat(match[1])
        trimmed = trimmed.slice(0, match.index).trim()
      }
      if (trimmed === '') return null
      return { color: trimmed, percentage: percentage }
    }

    function formatRgba(rgba) {
      var r = Math.round(Math.min(255, Math.max(0, rgba.r)))
      var green = Math.round(Math.min(255, Math.max(0, rgba.g)))
      var b = Math.round(Math.min(255, Math.max(0, rgba.b)))
      var alpha = Math.round(Math.min(1, Math.max(0, rgba.a)) * 1000) / 1000
      return alpha >= 1 ? 'rgb(' + r + ', ' + green + ', ' + b + ')'
        : 'rgba(' + r + ', ' + green + ', ' + b + ', ' + alpha + ')'
    }

    /* CSS Color 5: the pair mixes at its normalized ratio, on premultiplied
    alpha, so a transparent operand does not darken the result. A specified
    total below 100% leaves the result partly transparent: the normalized ratio
    still applies and the alpha scales by that total. */
    function mixColors(left, right, firstPercentage, secondPercentage) {
      var p1 = firstPercentage
      var p2 = secondPercentage
      if (p1 === null && p2 === null) { p1 = 50; p2 = 50 }
      else if (p1 === null) { p1 = 100 - p2 }
      else if (p2 === null) { p2 = 100 - p1 }
      var specified = p1 + p2
      if (!(specified > 0)) return { r: 0, g: 0, b: 0, a: 0 }
      var firstShare = p1 / specified
      var secondShare = p2 / specified
      var mixedAlpha = left.a * firstShare + right.a * secondShare
      if (mixedAlpha <= 0) return { r: 0, g: 0, b: 0, a: 0 }
      var scale = specified > 100 ? 1 : specified / 100
      return {
        r: (left.r * left.a * firstShare + right.r * right.a * secondShare) / mixedAlpha,
        g: (left.g * left.a * firstShare + right.g * right.a * secondShare) / mixedAlpha,
        b: (left.b * left.a * firstShare + right.b * right.a * secondShare) / mixedAlpha,
        a: Math.round(mixedAlpha * scale * 1000) / 1000,
      }
    }

    function resolveColorMix(inner) {
      var parts = splitTopLevel(inner, ',')
      if (parts.length === 3 && /^\s*in\s/.test(parts[0])) parts = parts.slice(1)
      if (parts.length !== 2) return null
      var first = parseStop(parts[0])
      var second = parseStop(parts[1])
      if (first === null || second === null) return null
      /* An operand may itself be a color-mix. It has to collapse to a literal
      first: the engine that needs this fallback cannot parse the nested form,
      so handing it straight to the probe would leave the operand unreadable. */
      var leftText = rewriteValue(first.color)
      var rightText = rewriteValue(second.color)
      if (leftText === null || rightText === null) return null
      var left = toRgba(resolveVariables(leftText))
      var right = toRgba(resolveVariables(rightText))
      if (left === null || right === null) return null
      return formatRgba(mixColors(left, right, first.percentage, second.percentage))
    }

    /* Returns null when any operand cannot be resolved, so callers leave the
    declaration exactly as authored rather than forcing a wrong color. */
    function rewriteValue(value) {
      if (value.indexOf('color-mix(') === -1) return value
      var guard = 0
      var out = value
      var failed = false
      while (out.indexOf('color-mix(') !== -1 && guard < 8) {
        guard += 1
        var next = replaceFunction(out, 'color-mix', function (inner) {
          var resolved = resolveColorMix(inner)
          if (resolved === null) { failed = true; return '' }
          return resolved
        })
        if (failed) return null
        if (next === out) break
        out = next
      }
      return out
    }

    function rewriteStyleSheet(sheet) {
      var rules = null
      try { rules = sheet.cssRules } catch (error) { return }
      if (rules === null) return
      for (var i = 0; i < rules.length; i += 1) rewriteRule(rules[i])
    }

    /**
     * Rewrite a declaration block, one declaration at a time, and return null
     * only when nothing changed. A declaration whose operands cannot be
     * resolved keeps its authored text, so one bad value never abandons the
     * rest of the rule.
     *
     * The block is read from the raw cssText rather than from the longhand
     * enumeration: a shorthand carrying var() is a pending-substitution value,
     * so style.item() lists its longhands with empty values and the authored
     * text is reachable only through the shorthand name or the raw block.
     */
    function rewriteDeclarationBlock(cssText) {
      var parts = splitTopLevel(cssText, ';')
      var out = []
      var changed = false
      for (var i = 0; i < parts.length; i += 1) {
        var part = parts[i]
        var colon = part.indexOf(':')
        if (colon === -1) {
          if (part.trim() !== '') out.push(part.trim())
          continue
        }
        var name = part.slice(0, colon).trim()
        var value = part.slice(colon + 1)
        if (value.indexOf('color-mix(') === -1) { out.push(name + ':' + value); continue }
        var resolved = rewriteValue(value)
        if (resolved === null) { out.push(name + ':' + value); continue }
        changed = true
        out.push(name + ': ' + resolved.trim())
      }
      return changed ? out.join('; ') : null
    }

    function rewriteRule(rule) {
      /* @import carries a nested sheet instead of a declaration block. */
      if (rule.styleSheet !== undefined && rule.styleSheet !== null) {
        rewriteStyleSheet(rule.styleSheet)
        return
      }
      var style = rule.style
      if (style === undefined || style === null) {
        /* @media, @supports and @layer only group further rules. */
        if (rule.cssRules !== undefined && rule.cssRules !== null) {
          for (var i = 0; i < rule.cssRules.length; i += 1) rewriteRule(rule.cssRules[i])
        }
        return
      }
      var authored = originals.get(style)
      if (authored === undefined) {
        authored = style.cssText
        originals.set(style, authored)
      }
      var rewritten = rewriteDeclarationBlock(authored)
      if (rewritten === null) return
      if (style.cssText !== rewritten) style.cssText = rewritten
    }

    /**
     * Rewrite every reachable stylesheet through CSSOM, one declaration at a
     * time. A declaration whose operands cannot be resolved is skipped and the
     * rest of the sheet still converts, which is why this is not a text pass
     * over the whole sheet: one unresolvable value must not abandon the others.
     * Both style elements and link-owned sheets are covered, since the shell
     * loads its static CSS through links and every plugin injects its own style
     * element at runtime.
     */
    function rewriteAll() {
      if (rewriting) return
      if (ensureProbe() === null) return
      rewriting = true
      try {
        var sheets = document.styleSheets
        for (var i = 0; i < sheets.length; i += 1) rewriteStyleSheet(sheets[i])
      } finally {
        rewriting = false
      }
    }

    function schedule() {
      if (scheduled) return
      scheduled = true
      var run = function () { scheduled = false; rewriteAll() }
      if (typeof g.requestAnimationFrame === 'function') g.requestAnimationFrame(run)
      else setTimeout(run, 0)
    }

    function start() {
      rewriteAll()
      var observer = new g.MutationObserver(function (records) {
        for (var i = 0; i < records.length; i += 1) {
          var record = records[i]
          if (record.type === 'attributes') { schedule(); return }
          for (var j = 0; j < record.addedNodes.length; j += 1) {
            var node = record.addedNodes[j]
            if (node.nodeType !== 1) continue
            if (node.nodeName === 'STYLE' || node.nodeName === 'LINK') { schedule(); return }
          }
        }
      })
      observer.observe(document.documentElement, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['data-ds-dark-theme', 'class', 'data-theme', 'style'],
      })
    }

    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', start)
    } else {
      start()
    }
  }
})();`
