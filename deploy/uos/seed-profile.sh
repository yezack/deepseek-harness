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

# 预装插件的唯一清单：name@version。软链、dependencies、bundles 三处都由它派生，
# 避免清单写多份后漏改其中一处（dshmarket 那次就是漏改软链那一份）。
# 与 packages/boot/app-boot/src/profile.ts 的 web 模板保持一致。
BUNDLES="dsh-capability-panel@1.4.2 @lemoncat7/dsh-ssh@1.11.4 dshmarket@1.66.44 dsh-rewind-plugin@0.17.1 dsh-dream-skin@10.16.0 dsh-better-sidebar@0.28.0 @linxin666/dsh-client-ui-git-graph@0.4.8 dsh-session-manager@0.7.3 dsh-better-workspace@0.32.2 dsh-univer-office@0.3.7 @yezack/dsh-temp-workspace@0.2.2 @yezack/dsh-remote-mobile@1.9.2"

# 预装但默认禁用的插件。它们装进 node_modules 与 bundles，由 profile 的
# cordis.patch.yml 关掉，这样操作员要用的那天在设置里打开即可，不必重装。
#   dsh-dream-skin 会替换整个外观；首次部署先保持 DSH 内置外观。
DISABLED="dream-skin"

# 已被取代的包名。profile 是持久的，升级时旧条目会留在 bundles 与 node_modules
# 里；覆盖安装后那个路径已不存在，每次启动都会报
#   dsh: skipping profile bundle "<old>": cannot resolve ...
# 所以这里显式清掉：软链、dependencies、bundles 三处一起。
#   dsh-remote-mobile          -> @yezack/dsh-remote-mobile（换成自维护 fork）
#   @michengai/dsh-archive-manager -> 不在目标清单里，随本轮清单一起退役
RETIRED="dsh-remote-mobile @michengai/dsh-archive-manager"

for entry in $BUNDLES; do
  name="${entry%@*}"
  source_dir="$DEST/app/node_modules/$name"
  [ -d "$source_dir" ] || continue
  link="$MODULES/$name"
  mkdir -p "$(dirname "$link")"
  if [ -e "$link" ]; then
    continue
  fi
  # 悬空软链（目标已被新安装移除）要替换掉，-e 对它是 false，所以单独判断。
  if [ -L "$link" ]; then
    rm -f "$link"
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
// 先摘掉退役名，再补齐当前清单。不摘的话旧条目会一直留在持久 profile 里，
// 每次启动报一条 skipping profile bundle。
const bundles = current.filter((name) => !retired.has(name));
// 追加在末尾，让插件的 patch 层最后应用，可以覆盖基础层。
for (const name of [...base, ...plugins.map((plugin) => plugin.name)]) {
  if (!bundles.includes(name)) bundles.push(name);
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

# 渲染浏览器路径。dsh-univer-office 的截图 / print_pdf / unit_layout_lint 需要一个
# Chromium 内核浏览器，但它自己的探测只认少数硬编码路径：Windows 上是 Program
# Files 下的 Chrome 与 Edge，Linux 上是 /usr/bin/google-chrome 之类。公安镜像上
# 那个浏览器是 /usr/bin/browser360ent-cn-stable，两边都探测不到，于是报
# UNIVER_RENDER_BROWSER_UNAVAILABLE。
#
# browserExecutablePath 优先于任何自动探测，所以这里用与 chrome-devtools MCP 行
# 完全相同的表达式，让整个部署只有一个浏览器路径 —— 换机器时改 DSH_CHROME_PATH
# 即可，不必动 profile。
RENDER_BEGIN="# >>> dsh-offline: render browser"
RENDER_END="# <<< dsh-offline: render browser"

"$NODE_BIN" -e '
const fs = require("node:fs");
const [file, beginMark, endMark] = process.argv.slice(1);
const block = [
  beginMark,
  "# 由 seed-profile.sh 维护：univer 的渲染浏览器，与 chrome-devtools MCP 同一个。",
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
