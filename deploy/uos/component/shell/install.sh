#!/bin/bash
# dsh 桌面壳组件（shell）：Electron 运行时 + 壳代码 + 桌面入口。
#
# 组件包结构（tar.gz）：
#   package/component.json
#   package/install.sh
#   package/payload/desktop/app/          壳代码（main.js / loading.html / icon / tray）
#   package/payload/desktop/electron-v*.zip  Electron 运行时
#
# 壳只负责界面、托盘与守护服务进程；不包含任何升级功能。
# 设置 DSH_DESKTOP=0 可跳过桌面壳（服务器/无桌面环境）。
#
# 用法： ./install.sh --component <组件包.tar.gz> [--upgrade]
set -e

DEST="${DSH_DEST:-/deepseek-harness}"
ELECTRON_DIR="${DSH_ELECTRON_DIR:-/var/tmp/dsh-electron}"

COMPONENT="${DSH_COMPONENT_FILE:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --component) COMPONENT="${2:-}"; shift 2 ;;
    --upgrade) shift ;;
    --help|-h) echo "用法: ./install.sh --component <组件包.tar.gz> [--upgrade]"; exit 0 ;;
    *) shift ;;
  esac
done
if [ -z "$COMPONENT" ] || [ ! -f "$COMPONENT" ]; then
  echo "[错误] 需要组件包： --component <tar.gz>" >&2; exit 1
fi

STAGE="$DEST/.install-stage-shell"
rm -rf "$STAGE"; mkdir -p "$STAGE"
trap 'rm -rf "$STAGE"' EXIT
tar xzf "$COMPONENT" -C "$STAGE" --strip-components=1 package/payload 2>/dev/null || {
  echo "[错误] 组件包结构异常：缺 package/payload" >&2; exit 1; }
PAYLOAD="$STAGE/payload"

TARGET_USER="${DSH_USER:-${SUDO_USER:-}}"
TARGET_HOME=""
[ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ] && TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"

echo "== 安装桌面壳组件 =="
if [ "${DSH_DESKTOP:-1}" = "0" ]; then
  echo "      已跳过（DSH_DESKTOP=0）"
  exit 0
fi
if [ ! -d "$PAYLOAD/desktop/app" ]; then
  echo "      [提示] 组件包内没有 desktop 载荷，跳过桌面壳"
  exit 0
fi
ELECTRON_ZIP="$(ls "$PAYLOAD"/desktop/electron-v*-linux-x64.zip 2>/dev/null | head -1)"
if [ -z "$ELECTRON_ZIP" ]; then
  echo "      [提示] 组件包内没有 electron 运行时，跳过桌面壳"
  exit 0
fi

# ---------- 1. Electron 运行时 + 壳代码 ----------
echo "[1/2] 安装 Electron 运行时与壳代码 ..."
rm -rf "$ELECTRON_DIR"; mkdir -p "$ELECTRON_DIR"
unzip -q -o "$ELECTRON_ZIP" -d "$ELECTRON_DIR"
[ -f "$ELECTRON_DIR/electron" ] && chmod 755 "$ELECTRON_DIR/electron"
cp -r "$PAYLOAD/desktop/app" "$ELECTRON_DIR/app"
chown -R "${TARGET_USER:-root}":"$(id -gn "${TARGET_USER:-root}" 2>/dev/null || echo root)" "$ELECTRON_DIR" 2>/dev/null || true
chmod -R a+rX "$ELECTRON_DIR" 2>/dev/null || true
chmod 755 "$ELECTRON_DIR/electron" 2>/dev/null || true

cat > "$DEST/desktop.sh" <<DESKTOP_LAUNCH
#!/bin/bash
# DeepSeek Harness 桌面壳启动器：主窗口 + 托盘常驻；Web 服务由壳接管（退出即结束）。
export DISPLAY="\${DISPLAY:-:0}"
export DSH_DEST="$DEST"
export DSH_HOME="\${DSH_HOME:-\$HOME/.dsh}"
exec "$ELECTRON_DIR/electron" --no-sandbox "$ELECTRON_DIR/app" "\$@"
DESKTOP_LAUNCH
chmod 755 "$DEST/desktop.sh"

# ---------- 2. 桌面入口 ----------
echo "[2/2] 桌面入口 ..."
if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ] && [ -n "$TARGET_HOME" ]; then
  APPS_DIR="$TARGET_HOME/.local/share/applications"
  TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")"
  install -d -m 755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$APPS_DIR" 2>/dev/null || true
  cat > "$APPS_DIR/dsh-desktop.desktop" <<DESKTOP_ENTRY
[Desktop Entry]
Type=Application
Name=DeepSeek Harness
Comment=DeepSeek Harness 桌面客户端（托盘常驻，退出即停止服务）
Exec=$DEST/desktop.sh
Icon=$ELECTRON_DIR/app/icon.png
Terminal=false
Categories=Development;
StartupNotify=true
DESKTOP_ENTRY
  chown "$TARGET_USER":"$TARGET_GROUP" "$APPS_DIR/dsh-desktop.desktop" 2>/dev/null || true
  chmod 644 "$APPS_DIR/dsh-desktop.desktop"
  DESKTOP_PATH=""
  if command -v xdg-user-dir >/dev/null 2>&1; then
    DESKTOP_PATH="$(sudo -u "$TARGET_USER" -H xdg-user-dir DESKTOP 2>/dev/null || true)"
  fi
  [ -n "$DESKTOP_PATH" ] || DESKTOP_PATH="$TARGET_HOME/Desktop"
  if [ -d "$DESKTOP_PATH" ]; then
    cp "$APPS_DIR/dsh-desktop.desktop" "$DESKTOP_PATH/dsh-desktop.desktop"
    chown "$TARGET_USER":"$TARGET_GROUP" "$DESKTOP_PATH/dsh-desktop.desktop" 2>/dev/null || true
    chmod 755 "$DESKTOP_PATH/dsh-desktop.desktop"
    command -v gio >/dev/null 2>&1 && sudo -u "$TARGET_USER" -H gio set "$DESKTOP_PATH/dsh-desktop.desktop" metadata::trusted true 2>/dev/null || true
  fi
  command -v update-desktop-database >/dev/null 2>&1 && sudo -u "$TARGET_USER" -H update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
  echo "      应用入口: $APPS_DIR/dsh-desktop.desktop"
else
  echo "      未指定桌面用户，跳过桌面入口（可直接运行 $DEST/desktop.sh）"
fi

echo "== 桌面壳组件安装完成（$DEST/desktop.sh）=="
