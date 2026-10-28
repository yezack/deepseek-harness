#!/bin/bash
# DeepSeek Harness - UOS 离线安装
#
# 安装包分成两个独立的发布单元，装到两个目录：
#
#   $DSH_DEST/app/            本体（dsh 官方包 + 依赖树）
#   $DSH_DEST/node/           Node 22 运行时（复制到白名单路径 /var/tmp/dsh-node）
#   $DSH_DEST/plugins/app/    插件（第三方插件 + 它们自己的依赖）
#
# 本脚本只装本体；插件由 install-plugins.sh 装（整包里含插件载荷时本脚本会顺带
# 调用它）。升级本体不碰 $DSH_DEST/plugins，升级插件不重装本体。
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${DSH_DEST:-/deepseek-harness}"
PLUGINS_DIR="$DEST/plugins"
# 白名单运行时目录。可用环境变量覆盖，便于在同一台机器上做并行试装
# （默认值就是生产路径 /var/tmp/dsh-node 与 /var/tmp/dsh-electron）。
INSTALL_NODE_DIR="${DSH_NODE_DIR:-/var/tmp/dsh-node}"
# 默认升级服务器（可用 DSH_UPDATE_URL 覆盖）。写入客户端 update.json，托盘「检查更新」从这里取清单。
DEFAULT_UPDATE_URL="http://autoupdate.kxzd.sjq.sh/deepseek_harness/latest.json"

# --upgrade：由桌面壳的"检查更新"调用。语义区别只有三点：
#   1) 不询问浏览器升级（沿用现有浏览器）；
#   2) 保留 profile / 桌面入口 / update.json（不重配环境）；
#   3) 结束时写 .installed-version，供下一次"检查更新"比较。
#   另外：不碰 $DEST/plugins（插件是独立单元）。
# --seed-only：只重播 profile（install-plugins.sh 换完插件树后调用）。
UPGRADE=0
SEED_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --upgrade) UPGRADE=1 ;;
    --seed-only) SEED_ONLY=1 ;;
    --help|-h)
      echo "用法: sudo ./install.sh [--upgrade|--seed-only]"
      echo "  --upgrade    升级安装（保留 profile 与插件；由桌面壳自动调用）"
      echo "  --seed-only  只重播 profile 预装插件清单"
      exit 0 ;;
  esac
done
if [ "$UPGRADE" = "1" ]; then
  # 升级不碰浏览器：直接走"跳过浏览器升级"的既有分支。
  export DSH_BROWSER_UPGRADE="${DSH_BROWSER_UPGRADE:-n}"
fi

# ============ profile 播种（安装/升级/插件换版后唯一的写入口） ============
# 设计约定：**写 profile 只发生在安装/升级阶段**（以及手动重跑 seed-profile.sh）。
# start-web.sh 只做只读预检，不再每次重启都改用户配置 —— 早先把 seeding 放在
# 启动里，维护脚本一有 bug 就会反复破坏用户配置（模型条目被当孤儿删掉）。
TARGET_USER="${DSH_USER:-${SUDO_USER:-}}"
TARGET_HOME=""
seed_profile() {
  if [ ! -f "$DEST/seed-profile.sh" ]; then
    echo "      [警告] 缺少 $DEST/seed-profile.sh，跳过 profile 播种"
    return 0
  fi
  if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    if [ -n "${DSH_USER:-}" ] && [ "$TARGET_USER" = "root" ]; then
      echo "      [警告] DSH_USER=root 不可用：profile 应属于桌面登录用户"
    else
      echo "      [警告] 无法确定 profile 的目标用户（DSH_USER / SUDO_USER 都为空）"
      echo "             profile 未播种；稍后请以桌面用户身份执行："
      echo "             DSH_HOME=\$HOME/.dsh $DEST/seed-profile.sh $DEST"
    fi
    return 0
  fi
  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
    echo "      [警告] 用户 $TARGET_USER 的家目录不存在，跳过 profile 播种"
    return 0
  fi
  local DSH_HOME_DIR="$TARGET_HOME/.dsh"
  local PROFILE_DIR="$DSH_HOME_DIR/profiles/web"
  local TARGET_GROUP
  TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")"
  install -d -m 700 -o "$TARGET_USER" -g "$TARGET_GROUP" "$DSH_HOME_DIR" "$PROFILE_DIR" 2>/dev/null || true
  # 写 profile 前留带时间戳的备份，只保留最近 3 份。
  if [ -f "$PROFILE_DIR/cordis.patch.yml" ]; then
    cp -p "$PROFILE_DIR/cordis.patch.yml" "$PROFILE_DIR/cordis.patch.yml.$(date +%Y%m%d-%H%M%S).bak"
    ls -1t "$PROFILE_DIR"/cordis.patch.yml.*.bak 2>/dev/null | tail -n +4 | xargs -r rm -f
  fi
  echo "      播种 profile（用户 $TARGET_USER）..."
  local SEED_OUT SEED_OK
  if [ "$(id -u)" = "0" ] && [ "$TARGET_USER" != "root" ]; then
    # 先收输出再打印：管道会把退出码替换成 sed 的，失败会被静默吞掉（踩过）。
    if command -v sudo >/dev/null 2>&1; then
      SEED_OUT="$(sudo -u "$TARGET_USER" -H env DSH_HOME="$DSH_HOME_DIR" SEED_NODE="$INSTALL_NODE_DIR/bin/node" \
        "$DEST/seed-profile.sh" "$DEST" 2>&1)"
      SEED_OK=$?
    else
      SEED_OUT="$(runuser -u "$TARGET_USER" -- env DSH_HOME="$DSH_HOME_DIR" SEED_NODE="$INSTALL_NODE_DIR/bin/node" \
        "$DEST/seed-profile.sh" "$DEST" 2>&1)"
      SEED_OK=$?
    fi
    printf '%s\n' "$SEED_OUT" | sed 's/^/      /'
    if [ "${SEED_OK:-0}" = "0" ]; then
      echo "      profile 已就绪: $PROFILE_DIR"
    else
      echo "      [警告] profile 播种失败（退出码 $SEED_OK），请手动执行："
      echo "             sudo -u $TARGET_USER $DEST/seed-profile.sh $DEST"
    fi
  else
    env DSH_HOME="$DSH_HOME_DIR" SEED_NODE="$INSTALL_NODE_DIR/bin/node" \
      "$DEST/seed-profile.sh" "$DEST" 2>&1 | sed 's/^/      /' || true
  fi
}

if [ "$SEED_ONLY" = "1" ]; then
  echo "============================================"
  echo "  DeepSeek Harness - 重播 profile"
  echo "============================================"
  seed_profile
  exit 0
fi

if [ "$UPGRADE" = "1" ]; then
  echo "============================================"
  echo "  DeepSeek Harness - 升级安装（本体）"
  echo "============================================"
  echo
fi

echo "============================================"
echo "  DeepSeek Harness - UOS 离线安装"
echo "  dsh 0.2.1-rc.2 / Node 22.23.2"
echo "============================================"
echo
echo "  本体安装位置: $DEST"
echo "  插件安装位置: $PLUGINS_DIR"
echo "  （可用环境变量 DSH_DEST 覆盖，例如：DSH_DEST=/opt/dsh ./install.sh）"
echo

if [ "$(id -u)" != "0" ]; then
  echo "  提示: 当前非 root。$DEST 与 $INSTALL_NODE_DIR 需要写权限。"
  echo "        请用 root 运行： sudo ./install.sh"
  echo
fi

# D6 备份保留策略：保留最近 2 个 $DEST.bak-*，其余删除，避免小磁盘被历史副本吃光。
# （升级流程是 mv 旧目录到 .bak-<时间戳>，再由本脚本重装。）
KEEP_BACKUPS=2
if compgen -G "$DEST.bak-*" >/dev/null 2>&1; then
  BACKUPS="$(ls -1dt "$DEST".bak-* 2>/dev/null || true)"
  COUNT=0
  while IFS= read -r old; do
    [ -z "$old" ] && continue
    COUNT=$((COUNT + 1))
    if [ "$COUNT" -gt "$KEEP_BACKUPS" ]; then
      case "$old" in
        "$DEST".bak-*) rm -rf "$old" && echo "  清理旧备份: $old" ;;
      esac
    fi
  done <<EOF
$BACKUPS
EOF
fi

# 旧布局标记：插件曾混在本体树里（$DEST/app/node_modules/<插件>）。
# 这次安装会整棵替换 app/，所以纯本体包升级上去会让插件消失 —— 下面会提示改用整包。
LEGACY_PLUGINS=0
if [ -d "$DEST/app/node_modules/dsh-ga-controller" ] && [ ! -d "$PLUGINS_DIR/app" ]; then
  LEGACY_PLUGINS=1
fi

# 1. 展开 node 与本体
echo "[1/7] 解压 Node 22 ..."
rm -rf "$DEST/node"
mkdir -p "$DEST"
unzip -q -o "$HERE/node.zip" -d "$DEST"
if [ ! -x "$DEST/node/bin/node" ]; then echo "[错误] Node 解压失败"; exit 1; fi

echo "[2/7] 解压 DeepSeek Harness 本体（请稍候）..."
# 旧包装的是 app.zip、新包叫 body.zip；两者解出来的目录名都是 app/。
BODY_ZIP="$HERE/body.zip"
[ -f "$BODY_ZIP" ] || BODY_ZIP="$HERE/app.zip"
if [ ! -f "$BODY_ZIP" ]; then echo "[错误] 包内没有 body.zip/app.zip"; exit 1; fi
rm -rf "$DEST/app"
unzip -q -o "$BODY_ZIP" -d "$DEST"
if [ ! -f "$DEST/app/node_modules/@deepseek-ai/dsh/lib/bin.js" ]; then echo "[错误] 本体解压失败"; exit 1; fi

# 预置脚本随包发布，由 start-web.sh 每次启动前调用（幂等）。
if [ ! -f "$HERE/seed-profile.sh" ]; then
  echo "[错误] 缺少 $HERE/seed-profile.sh"
  exit 1
fi
cp "$HERE/seed-profile.sh" "$DEST/seed-profile.sh"
# 用绝对模式，不用 chmod +x：从 Windows 经 SFTP 带过来的文件可能是 711，
# +x 不会补上组/其他的读位，而 bash 解析脚本需要读权限 —— 结果是启动时
# 静默失败、插件全部停用。
chmod 755 "$DEST/seed-profile.sh"

# 局域网访问脚本：0.2.1 只能绑一个具体地址，同时服务回环与局域网需要 DNAT 转发。
# 安装时不自动执行（改防火墙要操作员知情），README 里写明用法。
if [ -f "$HERE/enable-lan.sh" ]; then
  cp "$HERE/enable-lan.sh" "$DEST/enable-lan.sh"
  chmod 755 "$DEST/enable-lan.sh"
fi

# 自检与运维脚本（D4）。doctor 每次启动前由 start-web.sh 简要跑一遍也可以，
# 但为避免拖慢启动，只在安装结束时提示操作员手动执行。
for tool in doctor.sh collect-logs.sh maintain-profile.mjs; do
  if [ -f "$HERE/$tool" ]; then
    cp "$HERE/$tool" "$DEST/$tool"
    case "$tool" in
      *.sh) chmod 755 "$DEST/$tool" ;;
      *) chmod 644 "$DEST/$tool" ;;
    esac
  fi
done

echo "[3/7] 把 node 放到白名单目录 $INSTALL_NODE_DIR ..."
# 3. 把 node 放到白名单目录（UOS 的 deepin-elf-verify 只允许白名单路径执行二进制）
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

# B1 修复 npm/npx 的 shim。官方 tarball 里 bin/npm 是指向 npm-cli.js 的相对符号
# 链接；用 cp -r 复制时容易退化成普通文件（内含相对 require），于是任何 `npm`
# 调用都报模块找不到。这里无条件重建成绝对路径的 wrapper。
NPM_CLI="$INSTALL_NODE_DIR/lib/node_modules/npm/bin/npm-cli.js"
if [ -f "$NPM_CLI" ]; then
  printf '#!/bin/sh\nexec "%s/bin/node" "%s" "$@"\n' "$INSTALL_NODE_DIR" "$NPM_CLI" > "$INSTALL_NODE_DIR/bin/npm"
  chmod 755 "$INSTALL_NODE_DIR/bin/npm"
  NPX_CLI="$INSTALL_NODE_DIR/lib/node_modules/npm/bin/npx-cli.js"
  if [ -f "$NPX_CLI" ]; then
    printf '#!/bin/sh\nexec "%s/bin/node" "%s" "$@"\n' "$INSTALL_NODE_DIR" "$NPX_CLI" > "$INSTALL_NODE_DIR/bin/npx"
    chmod 755 "$INSTALL_NODE_DIR/bin/npx"
  fi
  echo "      npm shim 已修正: $("$INSTALL_NODE_DIR/bin/npm" --version 2>/dev/null || echo '仍不可用')"
fi

# B2 内置 pnpm：plugin-manager 用 pnpm 做 list/install，离线镜像里没有会被
# spawn pnpm ENOENT。包内 tools/ 携带 pnpm 的 npm 包，解到白名单 node 的
# node_modules 并生成 wrapper。
PNPM_TGZ=""
for candidate in "$HERE"/tools/pnpm-*.tgz; do
  [ -f "$candidate" ] && { PNPM_TGZ="$candidate"; break; }
done
if [ -n "$PNPM_TGZ" ] && [ -f "$INSTALL_NODE_DIR/lib/node_modules/npm/package.json" ]; then
  PNPM_DEST="$INSTALL_NODE_DIR/lib/node_modules/pnpm"
  rm -rf "$PNPM_DEST"
  mkdir -p "$PNPM_DEST"
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
  echo "      [提示] 包内没有 tools/pnpm-*.tgz，跳过 pnpm 内置（插件管理需联网）"
fi

# ============ 项目级兼容运行时（新 glibc） ============
# 部分插件的原生 .node 按更高 glibc 编译（univer 的两个 Rust 绑定实际要
# GLIBC >= 2.35，而 UOS 20 是 2.28）。这里随包带一份 Debian 12 的 libc6（2.36），
# 装到白名单路径 /var/tmp/dsh-glibc，并提供 wrapper 用它的 loader 启动同一个 node。
#
# 关键取舍：**宿主 DSH 仍用系统 glibc**，只有显式使用 wrapper 的插件子进程走新
# glibc（univer 的 Gateway / Unit Content Worker）。这避免换掉整个运行时带来的
# NSS、系统库混用等风险；其他插件遇到同类问题可以直接复用这个 wrapper。
GLIBC_DIR="${DSH_GLIBC_DIR:-/var/tmp/dsh-glibc}"
NODE_GLIBC="$INSTALL_NODE_DIR/bin/node-glibc"
GLIBC_TARBALL=""
for candidate in "$HERE"/tools/glibc*.tar.gz; do
  [ -f "$candidate" ] && { GLIBC_TARBALL="$candidate"; break; }
done
if [ -n "$GLIBC_TARBALL" ]; then
  # 先解到临时目录再整体换上：正在跑的 univer 子进程不会在中途读到半份 libc，
  # 也避免"解到 /var/tmp 再用"把自定义的 DSH_GLIBC_DIR 覆盖掉。
  GLIBC_STAGE="$(mktemp -d /var/tmp/dsh-glibc-stage.XXXXXX)"
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
  echo "      [提示] 包内没有 tools/glibc*.tar.gz，跳过兼容运行时（需要新 glibc 的插件不可用）"
fi

echo "[4/7] 插件单元 ..."
if [ -f "$HERE/plugins.zip" ] || [ -f "$HERE/plugins/plugins.zip" ] || [ -d "$HERE/plugins-app" ]; then
  if [ -f "$HERE/install-plugins.sh" ]; then
    echo "      发现插件载荷，安装到 $PLUGINS_DIR ..."
    # 播种统一由本脚本在最后做（一次），插件脚本只换目录。
    PLUGIN_ARGS=()
    [ "$UPGRADE" = "1" ] && PLUGIN_ARGS+=(--upgrade)
    DSH_DEST="$DEST" DSH_PLUGINS_SKIP_SEED=1 bash "$HERE/install-plugins.sh" "${PLUGIN_ARGS[@]}"
  else
    echo "      [警告] 包内有插件载荷但缺 install-plugins.sh，跳过插件安装"
  fi
else
  if [ "$LEGACY_PLUGINS" = "1" ]; then
    echo "      [警告] 这是旧布局（插件混在本体树里），本体已整棵替换，插件需要重新安装。"
    echo "             请改用整包安装，或装完本体后执行： sudo ./install-plugins.sh"
  elif [ "$UPGRADE" = "1" ]; then
    echo "      纯本体升级包：保留现有插件目录 $PLUGINS_DIR 不动"
  else
    echo "      [提示] 包内没有插件载荷，只装本体（插件可用 install-plugins.sh 单独安装）"
  fi
fi

# 系统浏览器升级（可选）。系统浏览器 = /usr/share/browser，跑 DSH UI 的那个。
# 只对「已装同名包 org.deepin.browser 且版本更低」的机器询问，不新装浏览器。
# 此步必须早于下面的浏览器探测：升级成功后 CHROME_BIN 才能拿到新内核。
# 无论升不升都打印检测结果，便于从安装日志定位"为什么没升"。
# 非交互安装（CI / 无人值守）可用 DSH_BROWSER_UPGRADE=y|n 直接决定。
BROWSER_DEB_DIR="$HERE/browser"
DEEPIN_VER="$(dpkg-query -W -f='${Version}' org.deepin.browser 2>/dev/null || true)"
echo "      系统浏览器 org.deepin.browser: ${DEEPIN_VER:-未安装}"
BROWSER_DEB=""
if [ -d "$BROWSER_DEB_DIR" ]; then
  BROWSER_DEB="$(ls "$BROWSER_DEB_DIR"/org.deepin.browser_*_amd64.deb 2>/dev/null | head -1)"
fi
if [ -z "$BROWSER_DEB" ]; then
  echo "      包内未携带浏览器 deb（package/browser/ 不存在或为空），跳过升级检测"
else
  NEW_VER="$(dpkg-deb -f "$BROWSER_DEB" Version 2>/dev/null || true)"
  echo "      包内浏览器 deb:   org.deepin.browser ${NEW_VER:-版本读取失败}（Chromium 126）"
  if [ -z "$DEEPIN_VER" ]; then
    echo "      系统未安装 org.deepin.browser，不自动新装（升级只针对同包名的旧版本）"
  elif ! dpkg --compare-versions "$DEEPIN_VER" lt "$NEW_VER" 2>/dev/null; then
    echo "      系统浏览器版本不低于包内版本，无需升级"
  elif [ -n "${DSH_BROWSER_UPGRADE:-}" ]; then
    case "$DSH_BROWSER_UPGRADE" in
      y|Y|yes|YES)
        if dpkg -i "$BROWSER_DEB"; then echo "      浏览器已升级到 $NEW_VER"
        else echo "      [警告] 升级失败，DSH 本体不受影响；可手动: sudo dpkg -i $BROWSER_DEB"; fi ;;
      *) echo "      已跳过浏览器升级（DSH_BROWSER_UPGRADE=$DSH_BROWSER_UPGRADE）" ;;
    esac
  elif [ "$(id -u)" != "0" ] || [ ! -e /dev/tty ]; then
    echo "      当前非 root 或没有终端，跳过；可手动: sudo dpkg -i $BROWSER_DEB"
  else
    printf "      检测到系统浏览器 %s 低于包内 %s。是否升级？[y/N] " "$DEEPIN_VER" "$NEW_VER"
    read -r BROWSER_UPGRADE_ANS < /dev/tty 2>/dev/null || BROWSER_UPGRADE_ANS=""
    case "$BROWSER_UPGRADE_ANS" in
      y|Y|yes|YES)
        if dpkg -i "$BROWSER_DEB"; then echo "      浏览器已升级到 $NEW_VER"
        else echo "      [警告] 升级失败，DSH 本体不受影响；可手动: sudo dpkg -i $BROWSER_DEB"; fi ;;
      *) echo "      已跳过浏览器升级（非交互安装可设 DSH_BROWSER_UPGRADE=y）" ;;
    esac
  fi
fi

# chrome-devtools MCP 需要一个浏览器。只报告不阻断，其余功能不依赖它。
#
# 两个浏览器角色是分开的，不要混：
#   - 跑 DSH UI 的是**系统浏览器** /usr/share/browser（/usr/bin/browser）。
#     它的版本随镜像而定（老镜像 6.3.9 = Chrome 93），由 web-compat 兼容层兜底，
#     本包的兼容基线就是 Chrome 108，不假设它已被升级。
#   - DSH 使用中**拉起**的浏览器（chrome-devtools MCP、univer 渲染）固定用 360
#     企业浏览器：上海公安全能安全浏览器 13.3.3200.187 = Chrome/108.0.5359.95。
#     这正是 @yezack/chrome-devtools-mcp-108 fork 的适配内核（108-110 的目标
#     发现修复），所以即使系统浏览器被升到 126 也不改用 126 驱动。
if [ -n "${DSH_CHROME_PATH:-}" ]; then
  CHROME_BIN="$DSH_CHROME_PATH"
else
  CHROME_BIN=""
  for candidate in /usr/bin/browser360ent-cn-stable /usr/bin/browser /usr/bin/chromium /usr/bin/google-chrome; do
    if [ -x "$candidate" ]; then CHROME_BIN="$candidate"; break; fi
  done
fi
if [ -n "$CHROME_BIN" ] && [ -x "$CHROME_BIN" ]; then
  echo "      chrome-devtools 浏览器: $CHROME_BIN ($("$CHROME_BIN" --version 2>/dev/null | tail -1))"
else
  CHROME_BIN="${DSH_CHROME_PATH:-/usr/bin/browser}"
  echo "      [警告] $CHROME_BIN 不存在，chrome-devtools MCP 无法启动浏览器"
fi

# 浏览器子进程需要一个可写的 $HOME。360 企业版即使收到 --user-data-dir，仍固定
# 往 $HOME/.config/browser360ent 写 crashpad 数据库与着色器缓存；$HOME 不可写时
# crashpad 拿不到 --database，浏览器的 CDP 端点起不来，puppeteer 只会报
# "Protocol error ... Target closed" —— 与 --isolated / user-data-dir 无关。
CHROME_HOME="/var/tmp/dsh-chrome-home"
mkdir -p "$CHROME_HOME"
chmod 1777 "$CHROME_HOME" 2>/dev/null || true

echo "[5/7] 播种 profile ..."
seed_profile

echo "[6/7] 可选桌面壳 ..."
# ============ 可选桌面壳（Electron：主窗口 + 托盘，接管服务进程） ============
# 只替代浏览器：窗口加载 127.0.0.1:3080；服务由壳拉起，退出壳时结束整个进程组。
# 托盘：打开 Agent / 在浏览器打开 / 重启服务 / 退出。
ELECTRON_DIR="${DSH_ELECTRON_DIR:-/var/tmp/dsh-electron}"
DESKTOP_OK=0
if [ "${DSH_DESKTOP:-1}" != "0" ] && [ -f "$HERE/desktop/electron-v44.7.0-linux-x64.zip" ] && [ -f "$HERE/desktop/app/main.js" ]; then
  echo "      安装桌面壳（Electron）..."
  rm -rf "$ELECTRON_DIR"
  mkdir -p "$ELECTRON_DIR"
  unzip -q -o "$HERE/desktop/electron-v44.7.0-linux-x64.zip" -d "$ELECTRON_DIR"
  [ -f "$ELECTRON_DIR/electron" ] && chmod 755 "$ELECTRON_DIR/electron"
  cp -r "$HERE/desktop/app" "$ELECTRON_DIR/app"
  # 壳要以桌面用户身份运行：目录与文件必须对该用户可读（cp -r 会保留来源的 600 权限），
  # 可执行位也必须显式补上——否则 electron 报 "EACCES: permission denied, open .../package.json"。
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
  if [ -n "${TARGET_USER:-}" ] && [ "$TARGET_USER" != "root" ] && [ -n "${TARGET_HOME:-}" ]; then
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
    echo "      应用菜单入口: $APPS_DIR/dsh-desktop.desktop"
    # 桌面快捷方式。DDE 要求 .desktop 有可执行位，并用 gio 元数据标记 trusted，
    # 否则双击会被当成文本（"不可信启动器"）。
    DESKTOP_PATH=""
    if command -v xdg-user-dir >/dev/null 2>&1; then
      DESKTOP_PATH="$(sudo -u "$TARGET_USER" -H xdg-user-dir DESKTOP 2>/dev/null || true)"
    fi
    [ -z "$DESKTOP_PATH" ] && DESKTOP_PATH="$TARGET_HOME/Desktop"
    if [ -d "$DESKTOP_PATH" ]; then
      cp "$APPS_DIR/dsh-desktop.desktop" "$DESKTOP_PATH/dsh-desktop.desktop"
      chown "$TARGET_USER":"$TARGET_GROUP" "$DESKTOP_PATH/dsh-desktop.desktop" 2>/dev/null || true
      chmod 755 "$DESKTOP_PATH/dsh-desktop.desktop"
      # 标记为"可信启动器"：DDE 的 gio 版本对 metadata::trusted 支持不一致，
      # 两个工具都试一遍（gvfs-set-attribute 已废弃但仍可用，实测在本机才生效）。
      if command -v gio >/dev/null 2>&1; then
        sudo -u "$TARGET_USER" -H gio set "$DESKTOP_PATH/dsh-desktop.desktop" metadata::trusted true 2>/dev/null || true
      fi
      if command -v gvfs-set-attribute >/dev/null 2>&1; then
        sudo -u "$TARGET_USER" -H gvfs-set-attribute "$DESKTOP_PATH/dsh-desktop.desktop" metadata::trusted true >/dev/null 2>&1 || true
      fi
      echo "      桌面快捷方式: $DESKTOP_PATH/dsh-desktop.desktop"
    else
      echo "      [提示] 未找到桌面目录（$DESKTOP_PATH），跳过桌面快捷方式"
    fi
    if command -v update-desktop-database >/dev/null 2>&1; then
      sudo -u "$TARGET_USER" -H update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
    fi
  fi
  DESKTOP_OK=1
  echo "      桌面壳: $DEST/desktop.sh"
elif [ "${DSH_DESKTOP:-1}" = "0" ]; then
  echo "      [提示] DSH_DESKTOP=0，跳过桌面壳"
else
  echo "      [提示] 包内没有 desktop/ 载荷，跳过桌面壳"
fi

echo "[7/7] 生成启动脚本与版本标记 ..."
# 生成启动前的只读预检脚本（不修改任何文件；只报告问题并给出修复命令）。
cat > "$DEST/preflight.sh" <<'PREFLIGHT_TEMPLATE'
#!/bin/bash
# 启动前只读预检。不写任何文件；发现问题只打印提示与修复命令。
set -u
PREFLIGHT_DEST="__DEST__"
PREFLIGHT_PLUGINS="__PLUGINS__"
export DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
PREFLIGHT_NODE="__NODE__"
PROFILE="$DSH_HOME/profiles/web"
PATCH="$PROFILE/cordis.patch.yml"
problems=0
note() { echo "  [预检] $*"; }
fix()  { echo "          修复: $*"; }

if [ ! -f "$PROFILE/package.json" ]; then
  note "profile 不存在（$PROFILE）"
  fix "$PREFLIGHT_DEST/seed-profile.sh $PREFLIGHT_DEST（以桌面用户身份执行）"
  problems=$((problems + 1))
else
  MISSING="$("$PREFLIGHT_NODE" -e '
const fs = require("node:fs")
const path = require("node:path")
const profile = process.argv[1]
let manifest
try { manifest = JSON.parse(fs.readFileSync(path.join(profile, "package.json"), "utf8")) } catch (error) { process.exit(0) }
const bundles = (manifest.dsh && manifest.dsh.profile && manifest.dsh.profile.bundles) || []
// 官方 @deepseek-ai/* 由本体自身的 node_modules 提供，不在 profile 里链接。
const thirdParty = bundles.filter((name) => !name.startsWith('@deepseek-ai/'))
// 软链必须解析到已存在的包（插件树被换掉/删掉时这里是空）。
const missing = thirdParty.filter((name) => !fs.existsSync(path.join(profile, "node_modules", name, "package.json")))
if (missing.length > 0) console.log(missing.join(" "))
' "$PROFILE" 2>/dev/null)"
  if [ -n "$MISSING" ]; then
    note "预装插件未链接到 profile: $MISSING"
    fix "$PREFLIGHT_DEST/seed-profile.sh $PREFLIGHT_DEST"
    problems=$((problems + 1))
  fi
  if grep -qE '^\s*host:\s*["'"'"']?(0\.0\.0\.0|::)' "$PATCH" 2>/dev/null; then
    note "webserver 仍绑定 0.0.0.0（0.2.1 会拒绝启动）"
    fix "$PREFLIGHT_DEST/seed-profile.sh $PREFLIGHT_DEST"
    problems=$((problems + 1))
  fi
  if [ -f "$PROFILE/.dsh-offline-state.json" ]; then
    SEEDED="$("$PREFLIGHT_NODE" -p 'JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).dshVersion' "$PROFILE/.dsh-offline-state.json" 2>/dev/null)"
    WANT="$("$PREFLIGHT_NODE" -p 'require(process.argv[1]).version' "$PREFLIGHT_DEST/app/node_modules/@deepseek-ai/dsh/package.json" 2>/dev/null)"
    if [ -n "$SEEDED" ] && [ -n "$WANT" ] && [ "$SEEDED" != "$WANT" ]; then
      note "profile 由 dsh $SEEDED 播种，当前安装是 $WANT"
      fix "$PREFLIGHT_DEST/seed-profile.sh $PREFLIGHT_DEST（同步预装插件版本）"
      problems=$((problems + 1))
    fi
  else
    note "profile 没有播种标记（.dsh-offline-state.json）"
    fix "$PREFLIGHT_DEST/seed-profile.sh $PREFLIGHT_DEST"
    problems=$((problems + 1))
  fi
  # 插件单元版本：改了插件树但没重播 profile 时这里会不一致（版本文件由安装脚本写）。
  if [ -f "$PREFLIGHT_PLUGINS/.installed-version" ] && [ -f "$PROFILE/.dsh-offline-state.json" ]; then
    PLUG_WANT="$("$PREFLIGHT_NODE" -p 'JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).version' "$PREFLIGHT_PLUGINS/.installed-version" 2>/dev/null)"
    PLUG_SEEDED="$("$PREFLIGHT_NODE" -p 'JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).pluginsVersion' "$PROFILE/.dsh-offline-state.json" 2>/dev/null)"
    if [ -n "$PLUG_WANT" ] && [ "$PLUG_WANT" != "unknown" ] && [ "$PLUG_SEEDED" != "$PLUG_WANT" ]; then
      note "插件单元版本 $PLUG_WANT，profile 播种的是 ${PLUG_SEEDED:-（无记录）}"
      fix "$PREFLIGHT_DEST/seed-profile.sh $PREFLIGHT_DEST"
      problems=$((problems + 1))
    fi
  fi
fi
if [ "$problems" -gt 0 ]; then
  echo "  [预检] 共 $problems 个问题；服务仍会启动，但插件可能不完整"
fi
exit 0
PREFLIGHT_TEMPLATE
# 把安装期的路径固化进去（模板用占位符避免 heredoc 转义地狱）。
sed -i "s|__DEST__|$DEST|g; s|__PLUGINS__|$PLUGINS_DIR|g; s|__NODE__|$INSTALL_NODE_DIR/bin/node|g" "$DEST/preflight.sh"
chmod 755 "$DEST/preflight.sh"

# 生成启动脚本
cat > "$DEST/start-web.sh" <<LAUNCH
#!/bin/bash
DEST="$DEST"
PLUGINS="$PLUGINS_DIR"
export DSH_HOME="\${DSH_HOME:-\$HOME/.dsh}"
export PATH="$INSTALL_NODE_DIR/bin:\$PATH"
export NARB_NATIVE_CACHE_DIR=/var/tmp/dsh-native-cache
# chrome-devtools MCP: the copy inside the installation, launched by this node,
# driving the platform's own Chromium. Exported rather than written into the
# profile so a non-default DSH_DEST needs no further edit.
export DSH_CHROME_DEVTOOLS_MCP="$DEST/app/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js"
export DSH_CHROME_PATH="\${DSH_CHROME_PATH:-$CHROME_BIN}"
# 浏览器子进程的 \$HOME：安装时选定的可写目录。MCP 行把它注入子进程环境，
# 360 的 crashpad 才有地方写 --database。
export DSH_CHROME_HOME="\${DSH_CHROME_HOME:-$CHROME_HOME}"
# UOS 的 deepin 浏览器 headless 必崩（trap int3），只能跑在桌面会话上，
# 所以 MCP 不带 --headless，并且这里保证 DISPLAY 可用。
export DISPLAY="\${DISPLAY:-:0}"
mkdir -p "\$DSH_HOME" "\$DSH_CHROME_HOME" /var/tmp/dsh-native-cache 2>/dev/null
# 写 profile 是安装/升级阶段的职责（seed-profile.sh，install 时以目标用户执行）。
# 启动只做**只读**预检：发现 profile 缺失/未同步时打印修复命令，绝不改文件。
"$DEST/preflight.sh" || true
cd "\$DEST"
# 项目级兼容运行时：需要更新 glibc 的插件子进程用这个 wrapper 启动 node。
# univer 的 fork（>=0.3.8）认 UNIVER_NODE_BINARY；其他插件可用通用的 DSH_NODE_GLIBC。
# 宿主 DSH 不受影响（仍用系统 glibc）。
export UNIVER_NODE_BINARY="\${UNIVER_NODE_BINARY:-$NODE_GLIBC}"
export DSH_NODE_GLIBC="\${DSH_NODE_GLIBC:-$NODE_GLIBC}"
# A4：启动时把"实际驱动 MCP / univer 的浏览器"打印出来。现场最容易踩的坑是
# 以为在用 360，实际落到了 /usr/bin/browser（老内核），排查时看不到这一行。
if [ -n "\${DSH_CHROME_PATH:-}" ]; then
  echo "  拉起用浏览器: \$DSH_CHROME_PATH"
else
  echo "  [警告] DSH_CHROME_PATH 未设置，MCP/univer 将回落到默认值"
fi
if [ -x "$NODE_GLIBC" ]; then
  echo "  兼容运行时:   \$DSH_NODE_GLIBC（glibc $("$GLIBC_DIR/ld-linux-x86-64.so.2" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)）"
else
  echo "  [提示] 兼容运行时未安装（$NODE_GLIBC 不存在）"
fi
if [ -d "\$PLUGINS/app/node_modules" ]; then
  echo "  插件单元:     \$PLUGINS/app（\$(cat "\$PLUGINS/.installed-version" 2>/dev/null | grep -o '"version": *"[^"]*"' | head -1 | cut -d'"' -f4)）"
else
  echo "  [提示] 插件单元未安装（\$PLUGINS），只有本体可用"
fi
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
echo "将删除：$DEST（含插件单元 $PLUGINS_DIR）以及 $INSTALL_NODE_DIR"
read -p "确认？(y/N) " a
[ "\$a" = "y" ] || exit 0
rm -rf "$DEST" "$INSTALL_NODE_DIR" /var/tmp/dsh-native-cache
echo "已删除。"
UNINST
chmod +x "$DEST/uninstall.sh"

# 记录安装版本，供桌面壳「检查更新」比较。VERSION 由 make-package.sh 写进包内。
# VERSION-BODY 是本体单元的版本；旧包只有 VERSION（两者相同）。
INSTALLED_VERSION="$(cat "$HERE/VERSION-BODY" 2>/dev/null || cat "$HERE/VERSION" 2>/dev/null || echo unknown)"
DSH_VER="$("$INSTALL_NODE_DIR/bin/node" -p "require('$DEST/app/node_modules/@deepseek-ai/dsh/package.json').version" 2>/dev/null || echo unknown)"
cat > "$DEST/.installed-version" <<VERSIONFILE
{
  "version": "$INSTALLED_VERSION",
  "dshVersion": "$DSH_VER",
  "installedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "mode": "$([ "$UPGRADE" = "1" ] && echo upgrade || echo fresh)"
}
VERSIONFILE
# 更新源：客户端只做普通 GET（服务端就是静态文件服务器），所以只记一个 URL。
# 优先级：DSH_UPDATE_URL（安装时显式指定）> 已有 update.json（升级时保留）> 内置默认服务器。
UPDATE_URL_EFFECTIVE="${DSH_UPDATE_URL:-$DEFAULT_UPDATE_URL}"
if [ -n "${DSH_UPDATE_URL:-}" ]; then
  printf '{\n  "manifestUrl": "%s"\n}\n' "$DSH_UPDATE_URL" > "$DEST/update.json"
elif [ ! -f "$DEST/update.json" ] || ! grep -q '"manifestUrl"[[:space:]]*:[[:space:]]*"[^"]' "$DEST/update.json" 2>/dev/null; then
  printf '{\n  "manifestUrl": "%s"\n}\n' "$DEFAULT_UPDATE_URL" > "$DEST/update.json"
fi

PLUGIN_VERSION=""
if [ -f "$PLUGINS_DIR/.installed-version" ]; then
  PLUGIN_VERSION="$("$INSTALL_NODE_DIR/bin/node" -p "JSON.parse(require('node:fs').readFileSync('$PLUGINS_DIR/.installed-version','utf8')).version" 2>/dev/null || echo unknown)"
fi

echo
echo "============================================"
echo "  安装完成"
echo "  本体版本:  $INSTALLED_VERSION  （dsh $DSH_VER）"
[ -n "$PLUGIN_VERSION" ] && echo "  插件版本:  $PLUGIN_VERSION" || echo "  插件版本:  未安装"
echo "  启动 Web:  $DEST/start-web.sh"
echo "  浏览器访问: http://127.0.0.1:3080/"
echo "  部署自检:  $DEST/doctor.sh        （PASS/WARN/FAIL 体检）"
echo "  日志打包:  $DEST/collect-logs.sh  （排查问题时发给开发侧）"
if [ "${DESKTOP_OK:-0}" = "1" ]; then
  echo "  桌面客户端: $DEST/desktop.sh      （主窗口 + 托盘；退出即停止服务）"
fi
echo "  局域网访问: sudo $DEST/enable-lan.sh   （0.2.1 需 DNAT 才能同时服务回环与局域网）"
echo "  兼容运行时: $NODE_GLIBC   （新 glibc，供 univer 等插件子进程）"
echo "  更新源:    $UPDATE_URL_EFFECTIVE"
if [ -z "${DSH_UPDATE_URL:-}" ]; then
  echo "             （默认服务器；可用 DSH_UPDATE_URL=… 覆盖，登录后也可改 $DEST/update.json）"
fi
echo "============================================"
