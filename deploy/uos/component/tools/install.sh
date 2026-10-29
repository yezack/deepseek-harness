#!/bin/bash
# dsh 工具组件（tools）：内置 pnpm + 项目级 glibc 兼容运行时。
#
# 组件包结构（tar.gz）：
#   package/component.json
#   package/install.sh
#   package/payload/tools/pnpm-*.tgz
#   package/payload/tools/glibc*.tar.gz
#
# 依赖 core 组件先装好（/var/tmp/dsh-node 与 $DSH_DEST/node 必须存在）。
#
# 用法： ./install.sh --component <组件包.tar.gz> [--upgrade]
set -e

DEST="${DSH_DEST:-/deepseek-harness}"
INSTALL_NODE_DIR="${DSH_NODE_DIR:-/var/tmp/dsh-node}"
GLIBC_DIR="${DSH_GLIBC_DIR:-/var/tmp/dsh-glibc}"

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
if [ ! -x "$INSTALL_NODE_DIR/bin/node" ]; then
  echo "[错误] 需要先安装 core 组件（$INSTALL_NODE_DIR/bin/node 不存在）" >&2; exit 1
fi

STAGE="$DEST/.install-stage-tools"
rm -rf "$STAGE"; mkdir -p "$STAGE"
trap 'rm -rf "$STAGE"' EXIT
tar xzf "$COMPONENT" -C "$STAGE" --strip-components=1 package/payload 2>/dev/null || {
  echo "[错误] 组件包结构异常：缺 package/payload" >&2; exit 1; }
PAYLOAD="$STAGE/payload"

echo "== 安装工具组件（pnpm + glibc 兼容运行时）=="

# ---------- 1. 内置 pnpm ----------
echo "[1/2] 内置 pnpm ..."
PNPM_TGZ=""
for candidate in "$PAYLOAD"/tools/pnpm-*.tgz; do [ -f "$candidate" ] && { PNPM_TGZ="$candidate"; break; }; done
if [ -n "$PNPM_TGZ" ] && [ -f "$INSTALL_NODE_DIR/lib/node_modules/npm/package.json" ]; then
  PNPM_DEST="$INSTALL_NODE_DIR/lib/node_modules/pnpm"
  rm -rf "$PNPM_DEST"; mkdir -p "$PNPM_DEST"
  if tar xzf "$PNPM_TGZ" -C "$PNPM_DEST" --strip-components=1 2>/dev/null && [ -f "$PNPM_DEST/bin/pnpm.mjs" ]; then
    printf '#!/bin/sh\nexec "%s/bin/node" "%s/bin/pnpm.mjs" "$@"\n' "$INSTALL_NODE_DIR" "$PNPM_DEST" > "$INSTALL_NODE_DIR/bin/pnpm"
    chmod 755 "$INSTALL_NODE_DIR/bin/pnpm"
    printf '#!/bin/sh\nexec "%s/bin/node" "%s/bin/pnpx.mjs" "$@"\n' "$INSTALL_NODE_DIR" "$PNPM_DEST" > "$INSTALL_NODE_DIR/bin/pnpx"
    chmod 755 "$INSTALL_NODE_DIR/bin/pnpx"
    echo "      pnpm 已内置: $("$INSTALL_NODE_DIR/bin/pnpm" --version 2>/dev/null || echo '安装失败')"
  else
    echo "      [警告] pnpm 解包失败，plugin-manager 的 pnpm 操作不可用"
  fi
else
  echo "      [提示] 组件包内没有 tools/pnpm-*.tgz，跳过 pnpm"
fi

# ---------- 2. 项目级兼容运行时 ----------
echo "[2/2] glibc 兼容运行时 ..."
NODE_GLIBC="$INSTALL_NODE_DIR/bin/node-glibc"
GLIBC_TARBALL=""
for candidate in "$PAYLOAD"/tools/glibc*.tar.gz; do [ -f "$candidate" ] && { GLIBC_TARBALL="$candidate"; break; }; done
if [ -n "$GLIBC_TARBALL" ]; then
  GLIBC_STAGE="$(mktemp -d "$STAGE/glibc.XXXXXX")"
  tar xzf "$GLIBC_TARBALL" -C "$GLIBC_STAGE"
  GLIBC_SRC="$(find "$GLIBC_STAGE" -maxdepth 1 -mindepth 1 -type d | head -1)"
  if [ -n "$GLIBC_SRC" ]; then
    rm -rf "$GLIBC_DIR"
    mkdir -p "$(dirname "$GLIBC_DIR")"
    mv "$GLIBC_SRC" "$GLIBC_DIR"
  fi
  rm -rf "$GLIBC_STAGE"
  chmod 755 "$GLIBC_DIR/ld-linux-x86-64.so.2" 2>/dev/null || true
  cat > "$NODE_GLIBC" <<GLIBC_WRAPPER
#!/bin/sh
# 用随包的新 glibc 运行 node。宿主 DSH 不使用本脚本；需要新 glibc 的插件子进程
# 通过 UNIVER_NODE_BINARY（univer）或 DSH_NODE_GLIBC（通用）引用它。
exec "$GLIBC_DIR/ld-linux-x86-64.so.2" --library-path "$GLIBC_DIR:$INSTALL_NODE_DIR/lib" "$INSTALL_NODE_DIR/bin/node" "\$@"
GLIBC_WRAPPER
  chmod 755 "$NODE_GLIBC"
  echo "      兼容运行时: $("$NODE_GLIBC" --version 2>/dev/null || echo '不可用')  [$("$GLIBC_DIR/ld-linux-x86-64.so.2" --version 2>/dev/null | head -1)]"
else
  echo "      [提示] 组件包内没有 tools/glibc*.tar.gz，跳过兼容运行时"
fi

echo "== 工具组件安装完成 =="
