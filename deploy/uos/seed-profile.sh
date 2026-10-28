#!/bin/bash
# 预置 web profile 的预装 bundle。
#
# `dsh.profile.bundles` 的条目由 Loader 从 profile 目录用原生 Node 解析导入，
# 不是从安装目录解析；profile 下没有 node_modules 时启动只会打印
#   Cannot find package '<name>' imported from <DSH_HOME>/profiles/web/
# 并把插件记成 "failed to import"，插件静默停用（服务仍能起来，所以很容易漏掉）。
# 因此这里把包实体链接进 profile 的 node_modules，并在 manifest 里同时声明
# dependencies 与 dsh.profile.bundles —— 与手工安装插件的 profile 结构一致。
#
# 幂等：manifest 不存在就创建，已存在则只合并这几个插件的条目，不动用户自己的
# 其他字段、也不打乱已有顺序。覆盖安装（profile 已由上一个版本创建）同样适用 ——
# 那时只有 dependencies 补齐是不够的，bundles 列表也必须补，否则包在
# node_modules 里 Loader 也不会加载。
#
# 用法: DSH_HOME=<home> ./seed-profile.sh <安装目录>
set -e

DEST="${1:-${DEST:-}}"
HOME_DIR="${DSH_HOME:-}"
if [ -z "$DEST" ]; then echo "seed-profile: 需要安装目录" >&2; exit 1; fi
if [ -z "$HOME_DIR" ]; then echo "seed-profile: 需要 DSH_HOME" >&2; exit 1; fi

NODE_BIN="${SEED_NODE:-node}"
PROFILE="$HOME_DIR/profiles/web"
MODULES="$PROFILE/node_modules"
# 插件是独立单元：优先从 $DEST/plugins/app 取包，旧布局（插件混在本体树里）
# 回落到 $DEST/app。链接目标变了要重指，否则升级插件后 profile 仍指向被替换的旧路径。
PLUGINS_ROOT="$DEST/plugins/app/node_modules"
[ -d "$PLUGINS_ROOT" ] || PLUGINS_ROOT="$DEST/app/node_modules"

# 写 profile 前留一份带时间戳的备份（保留最近 3 份）。seed-profile 现在是
# **安装/升级阶段**唯一的写入口；即便如此，用户配置仍然要先备份再动。
mkdir -p "$PROFILE"
if [ -f "$PROFILE/cordis.patch.yml" ]; then
  cp -p "$PROFILE/cordis.patch.yml" "$PROFILE/cordis.patch.yml.$(date +%Y%m%d-%H%M%S).bak"
  ls -1t "$PROFILE"/cordis.patch.yml.*.bak 2>/dev/null | tail -n +4 | xargs -r rm -f
fi

# 预装插件的唯一清单：name@version。软链、dependencies、bundles 三处都由它派生，
# 避免清单写多份后漏改其中一处（dshmarket 那次就是漏改软链那一份）。
# 与 packages/boot/app-boot/src/profile.ts 的 web 模板保持一致。
BUNDLES="dsh-capability-panel@1.4.2 @lemoncat7/dsh-ssh@1.11.5 dshmarket@1.66.47 dsh-rewind-plugin@0.18.0 dsh-dream-skin@10.22.0 dsh-better-sidebar@0.28.0 @linxin666/dsh-client-ui-git-graph@0.4.8 dsh-session-manager@0.7.4 dsh-better-workspace@0.35.1 @yezack/dsh-univer-office@0.3.8 @yezack/dsh-temp-workspace@0.2.4 @yezack/dsh-remote-mobile@1.10.0 dsh-ga-controller@0.1.0"

# 预装但默认禁用的插件。它们装进 node_modules 与 bundles，由 profile 的
# cordis.patch.yml 关掉，这样操作员要用的那天在设置里打开即可，不必重装。
# 注意：这里写的是 **bundle entry 的 id**，不是包名（两者不一定相同）。
#   dream-skin    -> dsh-dream-skin   会替换整个外观；首次部署先保持内置外观
#   dsh-market    -> dshmarket        插件市场（装/更新/检查更新需要联网，离线用不上）
DISABLED="dream-skin dsh-market"

# 强制启用的 bundle（entry id）。这些插件不允许被 profile 的 disabled 关掉：
# 播种时移除其 disabled 设置，桌面壳启动前也会再兜一次（见 desktop/app/main.js）。
#   ga-controller -> dsh-ga-controller（企业管控 + 会话备份上报，必须常驻）
FORCED="ga-controller"

# 已被取代的包名。profile 是持久的，升级时旧条目会留在 bundles 与 node_modules
# 里；覆盖安装后那个路径已不存在，每次启动都会报
#   dsh: skipping profile bundle "<old>": cannot resolve ...
# 所以这里显式清掉：软链、dependencies、bundles 三处一起。
#   dsh-remote-mobile          -> @yezack/dsh-remote-mobile（换成自维护 fork）
#   @michengai/dsh-archive-manager -> 不在目标清单里，随本轮清单一起退役
RETIRED="dsh-remote-mobile @michengai/dsh-archive-manager dsh-univer-office"

for entry in $BUNDLES; do
  name="${entry%@*}"
  source_dir="$PLUGINS_ROOT/$name"
  [ -d "$source_dir" ] || continue
  link="$MODULES/$name"
  mkdir -p "$(dirname "$link")"
  if [ -L "$link" ]; then
    # 已存在的软链：目标不一致就重指（插件从 $DEST/app 迁到 $DEST/plugins，
    # 或某个插件包在升级后换了目录时，旧链会指向已删除的路径）。
    current="$(readlink "$link" 2>/dev/null || true)"
    if [ "$current" != "$source_dir" ]; then
      rm -f "$link"
      ln -s "$source_dir" "$link"
    fi
    continue
  fi
  if [ -e "$link" ]; then
    # 实目录：用户自己 pnpm 装的包，保留原样，不接管。
    continue
  fi
  ln -s "$source_dir" "$link"
done

# 退役名：先删软链，再由下面的 node 脚本从 manifest 里摘掉。
for name in $RETIRED; do
  link="$MODULES/$name"
  [ -L "$link" ] && rm -f "$link"
done

mkdir -p "$PROFILE"
MANIFEST="$PROFILE/package.json"
"$NODE_BIN" -e '
const fs = require("node:fs");
const [file, ...rest] = process.argv.slice(1);
// 最后一个参数是逗号分隔的退役名，前面都是 name@version。
const retired = new Set((rest.pop() ?? "").split(",").filter((n) => n !== ""));
const entries = rest;
const plugins = entries.map((entry) => {
  const at = entry.lastIndexOf("@");
  return { name: entry.slice(0, at), version: entry.slice(at + 1) };
});
const base = ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"];
let manifest;
try {
  manifest = JSON.parse(fs.readFileSync(file, "utf8"));
} catch (error) {
  // 首次启动：profile 还不存在，由这里创建。
  if (error.code !== "ENOENT") throw error;
  manifest = { name: "dsh-profile-web" };
}
manifest.private = true;
manifest.dependencies = { ...manifest.dependencies };
for (const retiredName of retired) delete manifest.dependencies[retiredName];
for (const plugin of plugins) manifest.dependencies[plugin.name] = plugin.version;
manifest.dsh = { ...manifest.dsh };
manifest.dsh.profile = { ...manifest.dsh.profile };
const current = Array.isArray(manifest.dsh.profile.bundles) ? manifest.dsh.profile.bundles.slice() : base.slice();
// 先摘掉退役名，再按**确定性顺序**重排：官方核心 → 清单顺序（BUNDLES）→ 操作员自己加的。
// 不能"保留旧顺序 + 追加缺失项"：持久 profile 的顺序来自上一次播种（甚至是出厂模板），
// 新加的 bundle 会被排到中间。dsh-ga-controller 这类层要求最后应用的插件就会失效。
const retiredFiltered = current.filter((name) => !retired.has(name));
const managed = plugins.map((plugin) => plugin.name);
const isCore = (name) => name.startsWith("@deepseek-ai/");
const core = retiredFiltered.filter(isCore);
const managedOrdered = managed.filter((name) => retiredFiltered.includes(name));
const extras = retiredFiltered.filter((name) => !isCore(name) && !managed.includes(name));
// 去重：core 里已经包含 base/web-app，managedOrdered 只补插件名，不能重复 push。
const bundles = [...new Set([...core, ...managedOrdered, ...extras])];
// 明确要求"必须最后"的包：即使操作员后来追加了插件，也把它挪到末端。
const TAIL = ["dsh-ga-controller"];
for (const name of TAIL) {
  const at = bundles.indexOf(name);
  if (at !== -1 && at !== bundles.length - 1) {
    bundles.splice(at, 1);
    bundles.push(name);
  }
}
manifest.dsh.profile.bundles = bundles;
fs.writeFileSync(file, JSON.stringify(manifest, null, 2) + "\n");
' "$MANIFEST" $BUNDLES "$(echo $RETIRED | tr ' ' ',')"

# 默认禁用列表写进 profile 的 cordis.patch.yml。这段是本脚本独占的标记块：
# 每次替换自己那一段，其余内容（操作员手写的 webserver 覆盖等）原样保留。
# 标记块可以随手删掉，删了就等于全部启用。
PATCH="$PROFILE/cordis.patch.yml"
BEGIN_MARK="# >>> dsh-offline: default-disabled plugins"
END_MARK="# <<< dsh-offline: default-disabled plugins"

"$NODE_BIN" -e '
const fs = require("node:fs");
const [file, beginMark, endMark, names] = process.argv.slice(1);
const disabled = names.split(",").filter((n) => n !== "");
const block = [
  beginMark,
  "# 由 seed-profile.sh 维护：列在这里的插件装好了但默认不启用。",
  "# 需要时删掉整块（或其中一项）再重启即可。",
  ...disabled.flatMap((id) => [`- id: ${id}`, "  disabled: true"]),
  endMark,
].join("\n");
let current = "";
try {
  current = fs.readFileSync(file, "utf8");
} catch (error) {
  // 首次启动：profile 还没有 patch 文件。
  if (error.code !== "ENOENT") throw error;
}
const beginAt = current.indexOf(beginMark);
const endAt = current.indexOf(endMark);
let next;
if (beginAt !== -1 && endAt > beginAt) {
  // 替换已有块，保留块前块后的内容。
  next = current.slice(0, beginAt) + block + current.slice(endAt + endMark.length);
} else {
  next = current.trimEnd() === "" ? block : current.trimEnd() + "\n\n" + block;
}
fs.mkdirSync(require("node:path").dirname(file), { recursive: true });
fs.writeFileSync(file, next.trimEnd() + "\n");
console.log("[seed-profile] 默认禁用:", disabled.length === 0 ? "（无）" : disabled.join(", "));
' "$PATCH" "$BEGIN_MARK" "$END_MARK" "$(echo $DISABLED | tr ' ' ',')"

# 迁移：0.2.1 起 webserver 拒绝通配绑定（0.0.0.0 / ::），schemas 校验直接报
# "unspecified (wildcard) address" 并让启动失败 —— 而 profile 是持久的，旧部署
# （0.2.0 时代的 README 教人写 host: 0.0.0.0）升级安装后会原样留着，于是老机器
# 全部起不来。这里每次启动前只改 webserver 那一段的 host，改完打一行日志。
"$NODE_BIN" -e '
const fs = require("node:fs");
const file = process.argv[1];
let current;
try { current = fs.readFileSync(file, "utf8"); } catch (error) { if (error.code === "ENOENT") process.exit(0); throw error; }
const lines = current.split("\n");
let inWebserver = false;
let changed = false;
for (let index = 0; index < lines.length; index += 1) {
  const idMatch = /^\s*-\s*id:\s*(\S+)/.exec(lines[index]);
  if (idMatch) { inWebserver = idMatch[1] === "webserver"; continue; }
  if (!inWebserver) continue;
  const hostMatch = /^(\s*host:\s*)["\x27]?(0\.0\.0\.0|::)["\x27]?\s*$/.exec(lines[index]);
  if (hostMatch) { lines[index] = hostMatch[1] + "\x27127.0.0.1\x27"; changed = true; }
}
if (!changed) process.exit(0);
fs.writeFileSync(file, lines.join("\n"));
console.log("[seed-profile] webserver 通配绑定已改为 127.0.0.1（0.2.1 拒绝 0.0.0.0）");
console.log("[seed-profile]   要同时对外服务：sudo " + process.argv[2] + "/enable-lan.sh");
' "$PATCH" "$DEST"

# 渲染浏览器路径。dsh-univer-office 的截图 / print_pdf / unit_layout_lint 需要一个
# Chromium 内核浏览器，但它自己的探测只认少数硬编码路径：Windows 上是 Program
# Files 下的 Chrome 与 Edge，Linux 上是 /usr/bin/google-chrome 之类。公安镜像上
# 那个浏览器是 /usr/bin/browser360ent-cn-stable，两边都探测不到，于是报
# UNIVER_RENDER_BROWSER_UNAVAILABLE。
#
# browserExecutablePath 优先于任何自动探测，所以这里用与 chrome-devtools MCP 行
# 完全相同的表达式，让整个部署只有一个浏览器路径 —— 换机器时改 DSH_CHROME_PATH
# 即可，不必动 profile。
#
# 注意：两个消费者是**两条独立的配置行**（univer 的 browserExecutablePath 与
# web-app 模板里的 mcp-chrome-devtools 行），只是都读 DSH_CHROME_PATH 这个环境
# 变量。若绕过 start-web.sh 直接跑 bin.js，该变量未设，两边都会回落到
# /usr/bin/browser（老内核），排查时容易误判成"配置没生效"。
RENDER_BEGIN="# >>> dsh-offline: render browser"
RENDER_END="# <<< dsh-offline: render browser"

"$NODE_BIN" -e '
const fs = require("node:fs");
const [file, beginMark, endMark] = process.argv.slice(1);
const block = [
  beginMark,
  "# 由 seed-profile.sh 维护：univer 的渲染浏览器，与 chrome-devtools MCP 行读同一个",
  "# 环境变量 DSH_CHROME_PATH（分别的配置行，不是同一行）。",
  "# 需要换浏览器时改 start-web.sh 里的 DSH_CHROME_PATH，这里会自动跟随。",
  "- id: univer",
  "  config:",
  "    browserExecutablePath: !!js process.env.DSH_CHROME_PATH ?? \x27/usr/bin/browser\x27",
  endMark,
].join("\n");
let current = "";
try {
  current = fs.readFileSync(file, "utf8");
} catch (error) {
  if (error.code !== "ENOENT") throw error;
}
const beginAt = current.indexOf(beginMark);
const endAt = current.indexOf(endMark);
let next;
if (beginAt !== -1 && endAt > beginAt) {
  next = current.slice(0, beginAt) + block + current.slice(endAt + endMark.length);
} else {
  next = current.trimEnd() === "" ? block : current.trimEnd() + "\n\n" + block;
}
fs.mkdirSync(require("node:path").dirname(file), { recursive: true });
fs.writeFileSync(file, next.trimEnd() + "\n");
console.log("[seed-profile] 渲染浏览器: DSH_CHROME_PATH");
' "$PATCH" "$RENDER_BEGIN" "$RENDER_END"

# 配置卫生维护：把误入标记块的外来行移出、可疑行只提示（绝不自动删用户配置）、
# YAML 语法预检（失败回滚）。脚本随安装发布在 $DEST 下；缺失时跳过。
if [ -f "$DEST/maintain-profile.mjs" ]; then
  "$NODE_BIN" "$DEST/maintain-profile.mjs" "$PATCH" "$PROFILE/cordis.yml" "$DEST" "$(echo $DISABLED | tr ' ' ',')" "$(echo $FORCED | tr ' ' ',')"
else
  echo "[seed-profile] 缺少 maintain-profile.mjs，跳过配置卫生维护"
fi

# 播种标记：记录"哪个 dsh 版本播过种、谁播的、何时"。启动时的 preflight.sh 用它
# 判断 profile 是否与当前安装同步（只读，不触发任何写入）。
DSH_VER="$(LC_ALL=C "$NODE_BIN" -p "require('$DEST/app/node_modules/@deepseek-ai/dsh/package.json').version" 2>/dev/null || echo unknown)"
# 插件单元版本：与本体分开记录，插件单独升级后 preflight 才能发现 profile 没跟上。
PLUGINS_VER="$(LC_ALL=C "$NODE_BIN" -p "JSON.parse(require('node:fs').readFileSync('$DEST/plugins/.installed-version','utf8')).version" 2>/dev/null || echo "")"
"$NODE_BIN" -e '
const fs = require("node:fs")
const path = require("node:path")
const [profileDir, dshVersion, pluginsVersion] = process.argv.slice(1)
const file = path.join(profileDir, ".dsh-offline-state.json")
fs.writeFileSync(file, JSON.stringify({
  seedVersion: 2,
  dshVersion,
  ...(pluginsVersion ? { pluginsVersion } : {}),
  seededAt: new Date().toISOString(),
  seededBy: process.env.USER || process.env.LOGNAME || "unknown",
}, null, 2) + "\n")
' "$PROFILE" "$DSH_VER" "$PLUGINS_VER"
echo "[seed-profile] 播种标记: dsh $DSH_VER${PLUGINS_VER:+ / 插件 $PLUGINS_VER}"
