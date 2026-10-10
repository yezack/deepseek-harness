#!/bin/bash
# 预置 web profile 的预装 bundle。
#
# `dsh.profile.bundles` 的条目由 Loader 从 profile 目录用原生 Node 解析导入，
# 不是从安装目录解析；profile 下没有 node_modules 时启动只会打印
#   Cannot find package '<name>' imported from <DSH_HOME>/profiles/web/
# 并把插件记成 "failed to import"，插件静默停用（服务仍能起来，所以很容易漏掉）。
# 因此这里把包实体链接进 profile 的 node_modules，并在 manifest 的
# dependencies 里声明它们 —— 与手工安装插件的 profile 结构一致。
#
# 幂等：manifest 只在缺失时创建（DSH 的 initProfile 只在缺失时写，
# 会沿用这一份）；已存在时只补 dependencies，不动用户自己的配置。
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

# 与 packages/boot/app-boot/src/profile.ts 的 web 模板保持一致。
BUNDLES="dsh-capability-panel @michengai/dsh-archive-manager @lemoncat7/dsh-ssh"

for bundle in $BUNDLES; do
  source_dir="$DEST/app/node_modules/$bundle"
  [ -d "$source_dir" ] || continue
  link="$MODULES/$bundle"
  mkdir -p "$(dirname "$link")"
  [ -e "$link" ] || ln -s "$source_dir" "$link"
done

mkdir -p "$PROFILE"
MANIFEST="$PROFILE/package.json"
if [ ! -f "$MANIFEST" ]; then
  cat > "$MANIFEST" <<'JSON'
{
  "name": "dsh-profile-web",
  "private": true,
  "dependencies": {
    "dsh-capability-panel": "1.4.0",
    "@michengai/dsh-archive-manager": "1.0.15",
    "@lemoncat7/dsh-ssh": "1.11.1"
  },
  "dsh": {
    "profile": {
      "bundles": [
        "@deepseek-ai/dsh-base",
        "@deepseek-ai/dsh-web-app",
        "dsh-capability-panel",
        "@michengai/dsh-archive-manager",
        "@lemoncat7/dsh-ssh"
      ]
    }
  }
}
JSON
fi

"$NODE_BIN" -e '
const fs = require("node:fs");
const file = process.argv[1];
const manifest = JSON.parse(fs.readFileSync(file, "utf8"));
const pinned = {
  "dsh-capability-panel": "1.4.0",
  "@michengai/dsh-archive-manager": "1.0.15",
  "@lemoncat7/dsh-ssh": "1.11.1",
};
manifest.dependencies = { ...manifest.dependencies, ...pinned };
// 覆盖安装时 profile 已经存在，它的 bundles 列表来自上一个版本，可能没有这些
// 插件。只补 dependencies 不够：包在 node_modules 里，Loader 也不会加载它，
// 表现就是 "插件装上了但不生效"。追加在末尾，让插件的 patch 层最后应用。
manifest.dsh = manifest.dsh || {};
manifest.dsh.profile = manifest.dsh.profile || {};
const bundles = Array.isArray(manifest.dsh.profile.bundles) ? manifest.dsh.profile.bundles.slice() : [];
for (const name of Object.keys(pinned)) if (!bundles.includes(name)) bundles.push(name);
manifest.dsh.profile.bundles = bundles;
fs.writeFileSync(file, JSON.stringify(manifest, null, 2) + "\n");
' "$MANIFEST"
