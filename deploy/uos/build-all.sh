#!/bin/bash
# 一条命令跑完 UOS 侧出包（组件分发，没有整包）：
#   物化（本体树 + 每插件自包含树）→ 组件闸门 → 打成组件包 + 清单
#
# 产物（./dist/）：
#   installer.sh   组件安装器
#   manifest.json  组件清单
#   components/    本体 1 个 + 每个插件 1 个 tar.gz
#
# 用法: ./build-all.sh              # 全流程
#       ./build-all.sh --no-dist    # 只做物化 + 校验（调试用）
# 环境: DSH_BUILD_VERSION 固定分发版本；NPM_REGISTRY 覆盖 npm 镜像
set -e

BUILD="$(cd "$(dirname "$0")" && pwd)"
cd "$BUILD"
NODE=/var/tmp/node22/bin/node
[ -x "$NODE" ] || NODE=/var/tmp/dsh-node/bin/node
if [ ! -x "$NODE" ]; then
  echo "[错误] 找不到可执行的 node（/var/tmp/node22 或 /var/tmp/dsh-node）" >&2
  exit 1
fi

echo "================ 1/4 物化（本体树 + 每插件树）================"
./materialize-uos.sh "$BUILD"

echo "================ 2/4 组件闸门 ================"
"$NODE" ./verify-plugins.mjs "$BUILD" ./extras.json ./components.json

if [ "${1:-}" = "--no-dist" ]; then
  echo "================ 完成（--no-dist）================"
  du -sh "$BUILD/app" "$BUILD/plugins-build" 2>/dev/null
  exit 0
fi

echo "================ 3/4 生成组件分发 ================"
./make-dist.sh "$BUILD"

echo "================ 4/4 结果 ================"
ls -lh "$BUILD/dist"
echo "--- components ---"
ls -lh "$BUILD/dist/components"
echo "--- 清单 ---"
cat "$BUILD/dist/manifest.json"
echo "================ 完成 $(date) ================"
