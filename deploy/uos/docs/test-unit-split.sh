#!/bin/bash
# 双单元安装包的沙箱验证（构建机上跑，不碰生产 /deepseek-harness 与 /var/tmp/dsh-*）
# 用法: bash test-unit-split.sh [package-tar]
set -u
BUILD=/home/uos/uosbuild
TAR="${1:-$BUILD/dsh-uos-offline.tar.gz}"
ROOT=/home/uos/dsh-split-test
DEST="$ROOT/dest"
NODE_DIR="$ROOT/node"
ELECTRON="$ROOT/electron"
HOME_DIR="$ROOT/home"
PKG="$ROOT/pkg"
# 兼容运行时解析路径：包里的 install.sh 把 glibc 解到 /var/tmp/dsh-glibc，
# 这里沿用生产目录（内容相同，解包是幂等的）。
GLIBC=/var/tmp/dsh-glibc
# 构建机上生产服务占着 3080，测试换一个端口（profile 的 webserver 配置也要跟着改）。
PORT="${PORT:-3099}"

echo "############ 1. 解包 ############"
rm -rf "$ROOT"; mkdir -p "$PKG" "$HOME_DIR/profiles"
tar xzf "$TAR" -C "$PKG" || { echo "[FAIL] 解包失败"; exit 1; }
ls "$PKG/package" | head -20

echo "############ 2. 安装（跳过 profile 播种）############"
sudo -n env \
  DSH_DEST="$DEST" DSH_NODE_DIR="$NODE_DIR" DSH_ELECTRON_DIR="$ELECTRON" \
  DSH_GLIBC_DIR="$GLIBC" DSH_DESKTOP=0 DSH_BROWSER_UPGRADE=n DSH_USER=root \
  DSH_UPDATE_URL=http://example.invalid/latest.json \
  bash "$PKG/package/install.sh" 2>&1 | tail -45
INSTALL_RC=${PIPESTATUS[0]}
echo "install exit=$INSTALL_RC"

echo "############ 3. 目录与版本标记 ############"
ls -d "$DEST/app" "$DEST/plugins/app" "$DEST/node" 2>&1
echo "--- body state:"; cat "$DEST/.installed-version"
echo "--- plugins state:"; cat "$DEST/plugins/.installed-version"
echo "--- 宿主包软链:"; ls -l "$DEST/plugins/app/node_modules/@deepseek-ai" | head -3
echo "--- 插件数:"; ls "$DEST/plugins/app/node_modules" | wc -l
du -sh "$DEST/app" "$DEST/plugins" 2>/dev/null
echo "--- start-web.sh 关键行:"; grep -E 'DSH_CHROME_DEVTOOLS_MCP|exec .*bin.js|插件单元' "$DEST/start-web.sh"

echo "############ 4. profile 迁移（复制真实 profile 后重指软链）############"
cp -a /home/uos/.dsh/profiles/web "$HOME_DIR/profiles/web" 2>/dev/null
echo "before: $(readlink "$HOME_DIR/profiles/web/node_modules/dsh-ga-controller")"
DSH_HOME="$HOME_DIR" SEED_NODE="$NODE_DIR/bin/node" bash "$DEST/seed-profile.sh" "$DEST" 2>&1 | tail -12
echo "after:  $(readlink "$HOME_DIR/profiles/web/node_modules/dsh-ga-controller")"
echo "after:  $(readlink "$HOME_DIR/profiles/web/node_modules/@yezack/dsh-univer-office")"
echo "--- profile manifest 里是否声明插件:"
grep -o '"dsh-ga-controller": "[^"]*"' "$HOME_DIR/profiles/web/package.json"
echo "--- state:"
cat "$HOME_DIR/profiles/web/.dsh-offline-state.json"

echo "############ 5. 启动服务（端口 $PORT）############"
# 端口必须改 profile 的 webserver 配置：profile 的 cordis.patch.yml 在启动参数之后
# 叠加，会盖掉 start-web.sh 里的 --port。构建机上生产服务占着 3080，测试用别的端口。
sed -i "s/port: 3080/port: $PORT/" "$HOME_DIR/profiles/web/cordis.patch.yml"
( DSH_HOME="$HOME_DIR" setsid nohup "$DEST/start-web.sh" > "$ROOT/web.log" 2>&1 & )
for i in $(seq 1 40); do sleep 3; grep -q 'token=' "$ROOT/web.log" 2>/dev/null && break; done
echo "--- 启动日志关键行:"
grep -aE 'dsh web:|did not activate|failed to import|startup failed|插件单元|兼容运行时' "$ROOT/web.log" | head -20
T=$(grep -o 'token=[A-Za-z0-9_-]*' "$ROOT/web.log" 2>/dev/null | head -1 | cut -d= -f2)
echo "token: ${T:0:8}…"
echo "--- HTTP:"
curl -s -o /dev/null -w "  无 token=%{http_code}\n" --max-time 5 http://127.0.0.1:$PORT/
curl -s -o /dev/null -w "  带 token=%{http_code}\n" --max-time 8 "http://127.0.0.1:$PORT/?token=$T"
echo "--- 插件客户端 bundle 路由:"
curl -s --max-time 8 "http://127.0.0.1:$PORT/?token=$T" -c /tmp/tcj.txt -o /tmp/tpage.html
grep -c 'plugins/' /tmp/tpage.html
for p in dsh-ga-controller dsh-capability-panel dsh-better-sidebar; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -b /tmp/tcj.txt "http://127.0.0.1:$PORT/plugins/$p/client.js")
  echo "  /plugins/$p/client.js -> $code"
done

echo "############ 6. 清理 ############"
pkill -f "$DEST/app/node_modules/@deepseek-ai/dsh/lib/bin.js" 2>/dev/null
echo "############ 结束 ############"
