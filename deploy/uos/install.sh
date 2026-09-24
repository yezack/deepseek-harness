#!/bin/bash
# DeepSeek Harness - UOS 离线安装
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${DSH_DEST:-/dsh-uos}"
INSTALL_NODE_DIR="/var/tmp/dsh-node"

echo "============================================"
echo "  DeepSeek Harness - UOS 离线安装"
echo "  dsh 0.1.7-rc.1 / Node 22.23.2"
echo "============================================"
echo
echo "  安装位置: $DEST"
echo "  （可用环境变量 DSH_DEST 覆盖，例如：DSH_DEST=/opt/dsh ./install.sh）"
echo

if [ "$(id -u)" != "0" ]; then
  echo "  提示: 当前非 root。$DEST 与 $INSTALL_NODE_DIR 需要写权限。"
  echo "        请用 root 运行： sudo ./install.sh"
  echo
fi

# 1. 展开 node 与 app
echo "[1/3] 解压 Node 22 ..."
rm -rf "$DEST/node"
mkdir -p "$DEST"
unzip -q -o "$HERE/node.zip" -d "$DEST"
if [ ! -x "$DEST/node/bin/node" ]; then echo "[错误] Node 解压失败"; exit 1; fi

echo "[2/3] 解压 DeepSeek Harness 应用（约 1.3GB，请稍候）..."
rm -rf "$DEST/app"
unzip -q -o "$HERE/app.zip" -d "$DEST"
if [ ! -f "$DEST/app/node_modules/@deepseek-ai/dsh/lib/bin.js" ]; then echo "[错误] 应用解压失败"; exit 1; fi

# 3. 把 node 放到白名单目录（UOS 的 deepin-elf-verify 只允许白名单路径执行二进制）
echo "[3/3] 安装 Node 到白名单路径 $INSTALL_NODE_DIR ..."
rm -rf "$INSTALL_NODE_DIR"
mkdir -p "$INSTALL_NODE_DIR"
cp -r "$DEST/node/." "$INSTALL_NODE_DIR/"

# 原生模块缓存必须放在白名单路径（/tmp 下会被拦截）
mkdir -p /var/tmp/dsh-native-cache
chmod 1777 /var/tmp/dsh-native-cache 2>/dev/null || true

# koffi 的原生 .node 也必须从白名单路径加载：
# 把预编译包放到 /var/tmp，再从应用内软链接过去。
KOROMIX_SRC="$DEST/app/node_modules/@koromix/koffi-linux-x64"
KOROMIX_WH="/var/tmp/dsh-native-cache/koromix/koffi-linux-x64"
if [ -d "$KOROMIX_SRC" ]; then
  mkdir -p /var/tmp/dsh-native-cache/koromix
  rm -rf "$KOROMIX_WH"
  cp -r "$KOROMIX_SRC" "$KOROMIX_WH"
  mkdir -p "$DEST/app/node_modules/koffi/build/koffi"
  ln -sfn "$KOROMIX_WH/linux_x64" "$DEST/app/node_modules/koffi/build/koffi/linux_x64"
  echo "      koffi 原生模块已链接到白名单路径"
fi

# 生成启动脚本
cat > "$DEST/start-web.sh" <<LAUNCH
#!/bin/bash
DEST="$DEST"
export DSH_HOME="\${DSH_HOME:-\$HOME/.dsh}"
export PATH="$INSTALL_NODE_DIR/bin:\$PATH"
export NARB_NATIVE_CACHE_DIR=/var/tmp/dsh-native-cache
mkdir -p "\$DSH_HOME" /var/tmp/dsh-native-cache 2>/dev/null
cd "\$DEST"
echo "============================================"
echo "  DeepSeek Harness - Web 服务"
echo "  浏览器打开下面打印的带 token 的地址"
echo "  关闭本窗口即停止服务"
echo "============================================"
exec "$INSTALL_NODE_DIR/bin/node" "$DEST/app/node_modules/@deepseek-ai/dsh/lib/bin.js" web --port 3080 "\$@"
LAUNCH
chmod +x "$DEST/start-web.sh"

# 生成卸载脚本
cat > "$DEST/uninstall.sh" <<UNINST
#!/bin/bash
echo "将删除：$DEST 以及 $INSTALL_NODE_DIR"
read -p "确认？(y/N) " a
[ "\$a" = "y" ] || exit 0
rm -rf "$DEST" "$INSTALL_NODE_DIR" /var/tmp/dsh-native-cache
echo "已删除。"
UNINST
chmod +x "$DEST/uninstall.sh"

echo
echo "============================================"
echo "  安装完成"
echo "  启动 Web:  $DEST/start-web.sh"
echo "  浏览器访问: http://127.0.0.1:3080/"
echo "============================================"
