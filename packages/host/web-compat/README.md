# @deepseek-ai/dsh-host-web-compat

Legacy-browser compatibility for the Web shell: injects one classic script as the first element of the served `<head>`.

## Why

The client bundles and the served boot tail assume runtime APIs that a kernel
before Chrome 119 does not provide. The first failure is unavoidable: the boot
tail `renderIndexInjections` appends —

```html
<script>(globalThis.__DSH_BOOT_READY__ ??= Promise.withResolvers()).resolve()</script>
```

— so on a kernel without `Promise.withResolvers` the readiness deferred never
settles, the client plugin tree never boots, and the page reports
`Promise.withResolvers is not a function` in the console.

The design tokens add a second, independent failure. Tints, borders, and shadows
are expressed as

```css
background: color-mix(in srgb, var(--dsw-alias-label-primary) 9%, transparent);
```

`color-mix()` reached Chrome in 111, so a legacy kernel drops those declarations
as invalid. No build-time transform can resolve them: nearly every operand is a
custom property whose value changes with the theme.

## Injection position

The injection is an index **tap** (`webServer.tapIndex`), not a
`webserver/index-inject` row. Rows render in registration order and the bootstrap
`script-src` rows execute while the parser is still in the head, so a row cannot
guarantee it precedes another plugin's contribution. A tap runs after row
rendering, and splicing at the head boundary puts this script ahead of every row
that was just rendered — ahead of the boot tail, the module-loader queue, and the
bootstrap bundles.

## JavaScript polyfills

Installed only when missing, so a current browser runs none of them.

| API | Native from |
|---|---|
| `Promise.withResolvers` | Chrome 119 |
| `AbortSignal.any` | Chrome 116 |
| `AbortSignal.timeout` | Chrome 103 |
| `structuredClone` | Chrome 98 |
| `Object.hasOwn` | Chrome 93 |
| `Object.groupBy` / `Map.groupBy` | Chrome 117 |
| `Array.prototype.at` | Chrome 92 |
| `Array.prototype.toSorted` / `toReversed` / `toSpliced` / `with` | Chrome 110 |
| `Array.fromAsync` | Chrome 121 |
| `String.prototype.replaceAll` | Chrome 85 |
| `String.prototype.isWellFormed` | Chrome 111 |
| `crypto.randomUUID` | Chrome 92 |
| `Set.prototype` union / intersection / difference / symmetricDifference / isSubsetOf / isSupersetOf / isDisjointFrom | Chrome 122 |
| global `Iterator` + helpers (`map` / `filter` / `take` / `drop` / `flatMap` / `toArray` / `forEach` / `some` / `every` / `find` / `reduce` / `Iterator.from`) | Chrome 122 |

Two implementation constraints matter:

- `structuredClone` walks the object graph rather than round-tripping JSON, so
  binary payloads (`ArrayBuffer`, typed arrays), `Date`, `Map`, `Set`, and cycles
  survive. The client passes attachments and caches through it.
- The shimmed global `Iterator` is a constructor whose `.prototype` **is**
  `%IteratorPrototype%`. Bundled libraries patch `Iterator.prototype` directly,
  and helper results must inherit that same prototype or chained helpers stop
  being iterators.

## CSS `color-mix()` fallback

Skipped entirely where `CSS.supports('color', 'color-mix(in srgb, red, blue)')`
is true. Otherwise a pass resolves every `color-mix()` whose operands are live
custom properties:

1. Custom properties compute with their `var()` references already substituted,
   so one `getComputedStyle` lookup resolves a token to a concrete color.
2. The engine parses the operands by assigning them to a probe element, which
   covers every color syntax the kernel itself understands.
3. The mix follows CSS Color 5: the pair mixes at its normalized ratio on
   premultiplied alpha, so a `transparent` operand does not darken the result,
   and a specified total below 100% scales the result alpha by that total —
   `color-mix(in srgb, C 30%, D 30%)` is half-and-half at 60% alpha.
4. A declaration whose operands cannot be resolved keeps its authored text
   rather than being forced to a wrong color.

Every reachable stylesheet is rewritten through CSSOM, one declaration at a time,
so one unresolvable value never abandons the rest of the rule. The authored block
is remembered per rule and the whole pass re-runs when the theme attribute
changes, so a theme switch re-resolves the tokens instead of freezing the palette
captured at boot. Both channels are covered: the shell's static CSS arrives
through links and every plugin injects its own style element at runtime.

Three engine behaviors shape the implementation, and each was found by testing
against a baseline the engine itself computed:

- **Read the raw block, not the longhands.** A shorthand carrying `var()` is a
  pending-substitution value: `style.item()` enumerates its longhands with empty
  values and the authored text is reachable only through the shorthand name or
  `style.cssText`. Reading longhands silently misses every
  `border: … color-mix(…)`, which is a common shape in this tree.
- **Accept both color serializations.** A literal reads back as `rgb()`/`rgba()`,
  while a value that passed through a modern color function reads back as
  `color(srgb …)`. Parsing only the legacy form fails on exactly the operands
  that matter.
- **Collapse nested mixes first.** An operand may itself be a `color-mix()`, and
  the kernel that needs this fallback cannot parse that form, so the inner mix
  has to become a literal before the outer one reads its operands.

### Verification

A differential test compares the fallback against the engine. On a browser that
supports `color-mix()`, it records each probe's computed color, then forces the
fallback by reporting `color-mix` as unsupported and re-reads the same probes.
Thirteen probes cover the shapes above — token operands, a `var()` chain, a
custom property holding a mix, a nested mix, a `border` shorthand, a
semi-transparent operand, omitted percentages, totals above and below 100%, and a
zero total — and every one matches the engine numerically.

### Known limitations

- **Resolved values are literals.** A `color-mix()` inside a custom property
  definition is replaced by the color that property had at rewrite time and then
  re-resolved on the next theme change; a live consumer that reads the custom
  property without toggling the theme sees the value from the last pass.
- **Two declarations are not handled**: `field-sizing: content` and
  `light-dark()`. Both are cosmetic in this tree, and the affected declarations
  simply do not apply on an old kernel.
- **`@supports` is not consulted per declaration.** The fallback is installed
  only when the engine as a whole lacks `color-mix()`, which matches how the
  design tokens are authored.
- **The tap targets the served HTML form only.** A static worker deployment
  ships rows over its boot payload and does not run index taps.

## Model Experience

None. The package rewrites served HTML and touches no model request, prompt, or
tool result.

## Usage

Mount it in the profile composition:

```yaml
- id: web-compat
  name: '@deepseek-ai/dsh-host-web-compat'
```

Verify the injection from page source: the script element carries
`data-dsh-web-compat`.
