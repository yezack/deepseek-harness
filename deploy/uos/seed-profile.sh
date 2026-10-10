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
BUNDLES="dsh-capability-panel@1.4.0 @michengai/dsh-archive-manager@1.0.15 @lemoncat7/dsh-ssh@1.11.1 dsh-remote-mobile@1.9.0 dshmarket@1.66.11"

for entry in $BUNDLES; do
  name="${entry%@*}"
  source_dir="$DEST/app/node_modules/$name"
  [ -d "$source_dir" ] || continue
  link="$MODULES/$name"
  mkdir -p "$(dirname "$link")"
  [ -e "$link" ] || ln -s "$source_dir" "$link"
done

mkdir -p "$PROFILE"
MANIFEST="$PROFILE/package.json"
"$NODE_BIN" -e '
const fs = require("node:fs");
const [file, ...entries] = process.argv.slice(1);
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
for (const plugin of plugins) manifest.dependencies[plugin.name] = plugin.version;
manifest.dsh = { ...manifest.dsh };
manifest.dsh.profile = { ...manifest.dsh.profile };
const bundles = Array.isArray(manifest.dsh.profile.bundles) ? manifest.dsh.profile.bundles.slice() : base.slice();
// 追加在末尾，让插件的 patch 层最后应用，可以覆盖基础层。
for (const name of [...base, ...plugins.map((plugin) => plugin.name)]) {
  if (!bundles.includes(name)) bundles.push(name);
}
manifest.dsh.profile.bundles = bundles;
fs.writeFileSync(file, JSON.stringify(manifest, null, 2) + "\n");
' "$MANIFEST" $BUNDLES
