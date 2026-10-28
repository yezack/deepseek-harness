#!/bin/bash
# 两个单元各自的升级路径验证（沿用 test-unit-split.sh 装好的沙箱 DEST）
set -u
BUILD=/home/uos/uosbuild
ROOT=/home/uos/dsh-split-test
DEST="$ROOT/dest"
NODE_DIR="$ROOT/node"
HOME_DIR="$ROOT/home"
GLIBC=/var/tmp/dsh-glibc

echo "############ 0. 前置状态 ############"
echo "body  : $(cat "$DEST/.installed-version" 2>/dev/null | tr -d '\n' | tr -s ' ')"
echo "plugin: $(cat "$DEST/plugins/.installed-version" 2>/dev/null | tr -d '\n' | tr -s ' ')"
echo "插件链接: $(readlink "$HOME_DIR/profiles/web/node_modules/dsh-ga-controller")"
echo "插件数: $(ls "$DEST/plugins/app/node_modules" | wc -l)"

echo "############ 1. 插件单元升级（install-plugins.sh --upgrade）############"
rm -rf "$ROOT/pkg-plugins"; mkdir -p "$ROOT/pkg-plugins"
tar xzf "$BUILD"/dsh-uos-plugins-*.tar.gz -C "$ROOT/pkg-plugins"
ls "$ROOT/pkg-plugins/package"
sudo -n env DSH_DEST="$DEST" DSH_NODE_DIR="$NODE_DIR" \
  bash "$ROOT/pkg-plugins/package/install-plugins.sh" --upgrade 2>&1 | tail -25
echo "--- 升级后 ---"
echo "body  : $(cat "$DEST/.installed-version" | tr -d '\n' | tr -s ' ')"
echo "plugin: $(cat "$DEST/plugins/.installed-version" | tr -d '\n' | tr -s ' ')"
echo "插件链接: $(readlink "$HOME_DIR/profiles/web/node_modules/dsh-ga-controller")"
echo "@deepseek-ai 链接: $(readlink "$DEST/plugins/app/node_modules/@deepseek-ai")"
echo "插件数: $(ls "$DEST/plugins/app/node_modules" | wc -l)"
echo "profile 播种版本: $(grep -o '"pluginsVersion": "[^"]*"' "$HOME_DIR/profiles/web/.dsh-offline-state.json")"

echo "############ 2. 本体单元升级（install.sh --upgrade，必须保留插件）############"
PLUG_BEFORE=$(cat "$DEST/plugins/.installed-version")
rm -rf "$ROOT/pkg-body"; mkdir -p "$ROOT/pkg-body"
tar xzf "$BUILD"/dsh-uos-body-*.tar.gz -C "$ROOT/pkg-body"
ls "$ROOT/pkg-body/package"
sudo -n env DSH_DEST="$DEST" DSH_NODE_DIR="$NODE_DIR" DSH_ELECTRON_DIR="$ROOT/electron" \
  DSH_GLIBC_DIR="$GLIBC" DSH_DESKTOP=0 DSH_BROWSER_UPGRADE=n DSH_USER=root \
  DSH_UPDATE_URL=http://example.invalid/latest.json \
  bash "$ROOT/pkg-body/package/install.sh" --upgrade 2>&1 | tail -30
echo "--- 升级后 ---"
echo "body  : $(cat "$DEST/.installed-version" | tr -d '\n' | tr -s ' ')"
if [ -d "$DEST/plugins/app/node_modules" ]; then
  echo "插件目录保留 ✓（$(ls "$DEST/plugins/app/node_modules" | wc -l) 项）"
  if [ "$(cat "$DEST/plugins/.installed-version")" = "$PLUG_BEFORE" ]; then echo "插件版本未变 ✓"; else echo "插件版本被改动 ✗"; fi
else
  echo "插件目录丢失 ✗"
fi
echo "插件链接: $(readlink "$HOME_DIR/profiles/web/node_modules/dsh-ga-controller")"

echo "############ 3. 升级后重启服务验证 ############"
# 端口由 profile 的 webserver 配置决定（会盖掉 start-web.sh 的 --port）。
PORT="${PORT:-3099}"
sed -i "s/port: [0-9]*/port: $PORT/" "$HOME_DIR/profiles/web/cordis.patch.yml"
rm -f /tmp/web4.log
( cd "$ROOT" && DSH_HOME="$HOME_DIR" setsid nohup ./dest/start-web.sh > /tmp/web4.log 2>&1 & )
for i in $(seq 1 30); do sleep 3; grep -qa 'dsh web:' /tmp/web4.log 2>/dev/null && break; done
grep -aE 'dsh web:|startup failed|did not activate|插件单元' /tmp/web4.log | head
pkill -f "$DEST/app/node_modules/@deepseek-ai/dsh/lib/bin.js" 2>/dev/null
echo "############ 结束 ############"
