#!/bin/bash
# 一条命令跑完 UOS 侧出包：物化 → 两个构建期补丁 → 版本闸门回归 → 打包 → 打印校验值。
# 目的：消除手工漏传/漏跑（此前出现过旧 install.sh、旧 seed-profile.sh 未覆盖的问题）。
#
# 用法: ./build-all.sh            # 全流程
#       ./build-all.sh --no-package  # 只做物化 + 校验（调试用）
set -e

BUILD="$(cd "$(dirname "$0")" && pwd)"
cd "$BUILD"
NODE=/var/tmp/node22/bin/node
[ -x "$NODE" ] || NODE=/var/tmp/dsh-node/bin/node
if [ ! -x "$NODE" ]; then
  echo "[错误] 找不到可执行的 node（/var/tmp/node22 或 /var/tmp/dsh-node）" >&2
  exit 1
fi

echo "================ 1/4 物化 ================"
./materialize-uos.sh

echo "================ 2/4 版本闸门回归 ================"
"$NODE" ./verify-plugins.mjs "$BUILD/app" "$BUILD/seed-profile.sh"

if [ "${1:-}" = "--no-package" ]; then
  echo "================ 完成（--no-package）================"
  exit 0
fi

echo "================ 3/4 打包 ================"
./make-package.sh

echo "================ 4/4 校验 ================"
ls -l "$BUILD/dsh-uos-offline.tar.gz"
sha256sum "$BUILD/dsh-uos-offline.tar.gz"
echo "包含的关键文件:"
tar tzf "$BUILD/dsh-uos-offline.tar.gz" | grep -E 'package/(install|seed-profile|enable-lan|doctor|collect-logs|maintain-profile)' | sed 's/^/  /'
echo "================ 完成 $(date) ================"
