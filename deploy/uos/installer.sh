#!/bin/bash
# DeepSeek Harness - UOS 组件安装器
#
# 分发目录里只有组件包，没有整包：
#
#   installer.sh            本脚本
#   manifest.json           组件清单（本体 1 个 + 每个插件 1 个）
#   VERSION                 本次分发版本
#   components/             各组件 tar.gz
#
# 每个组件包自带 install.sh，可以单独安装；installer 负责统一调度：
# 校验 sha256 → 按 order 依次调用各组件的安装脚本 → 记录状态 → 重播 profile。
#
# 用法：
#   sudo ./installer.sh apply                    自动判定：全新安装或升级（离线介质入口）
#   sudo ./installer.sh install all              全新安装（本体 + 全部插件）
#   sudo ./installer.sh install body             只装本体
#   sudo ./installer.sh install dsh-better-sidebar 只装一个插件
#   sudo ./installer.sh upgrade [all|<组件>...]  按清单升级版本不同的组件
#   sudo ./installer.sh remove <插件>...         卸载插件
#   sudo ./installer.sh seed                     只重播 profile
#   ./installer.sh status [--json]               本机已装组件 vs 清单
#   ./installer.sh list                          清单内容
#   ./installer.sh verify                        自检（组件目录/软链/宿主包链接）
#   ./installer.sh doctor                        调用已安装的 doctor.sh
#
# 选项：
#   --dist DIR         分发目录（默认本脚本所在目录）
#   --server URL       在线模式：清单和组件从 URL 前缀下载（磁盘上是离线模式）
#   --dry-run          只打印计划，不改动磁盘
#   --yes              非交互
#   --no-seed          不重播 profile（调试用）
#
# 输出约定（Electron 壳解析）：以 "PHASE "、"PROGRESS "、"RESULT "、"ERROR " 开头的行。
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${DSH_DEST:-/deepseek-harness}"
INSTALL_NODE_DIR="${DSH_NODE_DIR:-/var/tmp/dsh-node}"
STATE_FILE="$DEST/installed.json"
CACHE_ROOT="/var/tmp/dsh-installer"

DIST=""
SERVER=""
ASSUME_YES=0
DO_SEED=1
JSON=0
DRY_RUN=0
LOCK_HELD=0
COMMAND=""
ARGS=()
ORIGINAL_ARGS=("$@")

while [ $# -gt 0 ]; do
  case "$1" in
    --dist) DIST="${2:-}"; shift 2 ;;
    --server) SERVER="${2:-}"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --no-seed) DO_SEED=0; shift ;;
    --json) JSON=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*) echo "ERROR 未知选项: $1" >&2; exit 2 ;;
    *) if [ -z "$COMMAND" ]; then COMMAND="$1"; else ARGS+=("$1"); fi; shift ;;
  esac
done

say() { echo "$*"; }
log() { echo "    $*"; }
fail() { echo "ERROR $*" >&2; exit 1; }

# ---------- 自动提权 ----------
# 写安装目录/清单缓存需要 root。调用方不必自己加 sudo：需要时这里直接用 sudo
# 重新执行自己（免密优先，其次交互式提示）。只读命令（list/status/verify）不提权。
needs_root_command() {
  # --dry-run 只读计划，不提权。
  [ "$DRY_RUN" = "1" ] && return 1
  case "$COMMAND" in
    install|upgrade|apply|remove|seed) return 0 ;;
    *) return 1 ;;
  esac
}
if [ "$(id -u)" != "0" ] && needs_root_command; then
  if ! command -v sudo >/dev/null 2>&1; then
    fail "需要 root 权限，且系统没有 sudo；请以 root 运行"
  fi
  env_args=()
  for name in DSH_DEST DSH_NODE_DIR DSH_GLIBC_DIR DSH_ELECTRON_DIR DSH_DESKTOP DSH_HOME DSH_USER; do
    value="$(eval "printf '%s' \"\${$name:-}\"")"
    [ -n "$value" ] && env_args+=("$name=$value")
  done
  log "需要 root，自动提权执行：sudo $0 $COMMAND"
  if sudo -n true 2>/dev/null; then
    exec sudo -n env "${env_args[@]}" bash "$0" "${ORIGINAL_ARGS[@]}"
  fi
  exec sudo env "${env_args[@]}" bash "$0" "${ORIGINAL_ARGS[@]}"
fi
need_root() {
  if [ "$(id -u)" != "0" ]; then
    fail "该操作需要 root（自动提权失败）：请手动 sudo ./installer.sh $COMMAND ..."
  fi
}

# ---------- 并发锁 ----------
# 桌面壳的"从离线包升级"和运维手工执行可能同时发生；两个 apply 并发会互相踩目录。
LOCK_FILE="$DEST/.installer.lock"
acquire_lock() {
  [ "$DRY_RUN" = "1" ] && return 0
  [ "$LOCK_HELD" = "1" ] && return 0
  if ! command -v flock >/dev/null 2>&1; then
    log "[警告] 系统没有 flock，跳过并发锁"
    return 0
  fi
  mkdir -p "$DEST" 2>/dev/null || true
  eval "exec 9>\"$LOCK_FILE\""
  flock -n 9 || fail "另一个安装/升级进程正在运行（锁 $LOCK_FILE）"
  LOCK_HELD=1
  log "已获取安装锁"
}

# ---------- 分发目录自动探查 ----------
# 不要求 --dist：按「脚本所在目录 → $DEST（安装后自带 installer）→ 当前目录」找 manifest.json。
if [ -z "$DIST" ]; then
  for candidate in "$HERE" "$DEST" "$(pwd)"; do
    [ -f "$candidate/manifest.json" ] && { DIST="$candidate"; break; }
  done
  [ -n "$DIST" ] || DIST="$HERE"
fi

# ---------- 清单获取 ----------
WORK="$DIST"
if [ -n "$SERVER" ]; then
  need_root
  mkdir -p "$CACHE_ROOT"
  # --server 既接受目录（拼 manifest.json），也接受清单文件 URL（……/manifest.json 或 ……/latest.json）。
  case "$SERVER" in
    *.json) MANIFEST_URL="$SERVER"; SERVER_BASE="${SERVER%/*}" ;;
    */) MANIFEST_URL="${SERVER}manifest.json"; SERVER_BASE="${SERVER%/}" ;;
    *) MANIFEST_URL="$SERVER/manifest.json"; SERVER_BASE="$SERVER" ;;
  esac
  tmp="$CACHE_ROOT/manifest.tmp"
  curl -fsSL --max-time 60 "$MANIFEST_URL" -o "$tmp" || fail "下载清单失败：$MANIFEST_URL"
  version="$("$INSTALL_NODE_DIR/bin/node" -p 'JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).version' "$tmp" 2>/dev/null || echo "")"
  [ -n "$version" ] || fail "远端清单格式不正确（缺 version）"
  WORK="$CACHE_ROOT/$version"
  mkdir -p "$WORK/components"
  cp "$tmp" "$WORK/manifest.json"
  rm -f "$tmp"
  # 组件包按清单里的相对路径从清单所在目录取。
  SERVER="$SERVER_BASE"
  log "在线模式：清单 $MANIFEST_URL（版本 $version）"
fi

MANIFEST="$WORK/manifest.json"
[ -f "$MANIFEST" ] || fail "找不到清单：$MANIFEST（用 --dist 指定分发目录，或 --server 指定更新源）"
NODE_BIN="$INSTALL_NODE_DIR/bin/node"
[ -x "$NODE_BIN" ] || NODE_BIN="$DEST/node/bin/node"
if [ ! -x "$NODE_BIN" ]; then
  # 全新安装时本机还没有 node：用组件包里带的那个解到白名单目录是 body 安装脚本的事，
  # 这里只需要读 JSON，先用系统 node 或 python 兜底。
  if command -v node >/dev/null 2>&1; then NODE_BIN="$(command -v node)"
  elif command -v python3 >/dev/null 2>&1; then NODE_BIN=""; else fail "找不到可用的 node/python3 读取清单"; fi
fi
json_get() { # json_get <file> <node 表达式，参数名 $v>
  if [ -n "$NODE_BIN" ]; then
    "$NODE_BIN" -e "const v=JSON.parse(require('node:fs').readFileSync(process.argv[1],'utf8'));console.log($2)" "$1"
  else
    python3 - "$1" "$2" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
expr = sys.argv[2]
# 只支持 components/version/dshVersion 这几个固定表达式
if expr == "v.version":
    print(data.get("version", ""))
elif expr == "v.dshVersion":
    print(data.get("dshVersion", ""))
else:
    print("")
PYEOF
  fi
}
MANIFEST_VERSION="$(json_get "$MANIFEST" 'v.version')"
DSH_VER="$(json_get "$MANIFEST" 'v.dshVersion')"

# ---------- 组件状态（自动探查，不依赖状态文件）----------
# 本机装了什么，以 $DEST 里的实际目录为准：本体看 .installed-version，插件逐个
# 扫 $DEST/plugins/<包名>/component.json。手工装/单独装/旧状态文件缺失都能认出来。
INSTALLED_SCAN=""
scan_installed() {
  [ -n "$INSTALLED_SCAN" ] && { printf '%s\n' "$INSTALLED_SCAN"; return 0; }
  if [ -n "$NODE_BIN" ]; then
    INSTALLED_SCAN="$("$NODE_BIN" - "$DEST" <<'JSEOF'
const fs = require('node:fs')
const path = require('node:path')
const dest = process.argv[2]
const rows = []
const readVersion = (file) => {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')).version } catch { return undefined }
}
const bodyVersion = readVersion(path.join(dest, '.installed-version'))
if (bodyVersion !== undefined) rows.push(['@deepseek-ai/dsh', 'body', bodyVersion].join('\t'))
const pluginsRoot = path.join(dest, 'plugins')
function walk(dir) {
  let entries
  try { entries = fs.readdirSync(dir, { withFileTypes: true }) } catch { return }
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name.startsWith('.')) continue
    const full = path.join(dir, entry.name)
    if (entry.name.startsWith('@')) { walk(full); continue }
    let name = entry.name
    let version = readVersion(path.join(full, '.installed-version'))
    try {
      const meta = JSON.parse(fs.readFileSync(path.join(full, 'component.json'), 'utf8'))
      if (typeof meta.name === 'string') name = meta.name
      if (typeof meta.version === 'string') version = meta.version
    } catch { /* 没有 component.json：按目录名 + .installed-version 认 */ }
    if (version !== undefined) rows.push([name, 'plugin', version].join('\t'))
  }
}
walk(pluginsRoot)
console.log(rows.join('\n'))
JSEOF
)"
  else
    INSTALLED_SCAN="$(python3 - "$DEST" <<'PYEOF'
import json, os, sys
dest = sys.argv[1]
rows = []
def read_version(path):
    try:
        return json.load(open(path)).get('version')
    except Exception:
        return None
body = read_version(os.path.join(dest, '.installed-version'))
if body:
    rows.append('@deepseek-ai/dsh\tbody\t' + str(body))
for dirpath, dirnames, filenames in os.walk(os.path.join(dest, 'plugins')):
    if 'component.json' not in filenames:
        continue
    try:
        meta = json.load(open(os.path.join(dirpath, 'component.json')))
    except Exception:
        continue
    name = meta.get('name') or os.path.basename(dirpath)
    version = meta.get('version') or read_version(os.path.join(dirpath, '.installed-version'))
    if version:
        rows.append(str(name) + '\tplugin\t' + str(version))
print('\n'.join(rows))
PYEOF
)"
  fi
  printf '%s\n' "$INSTALLED_SCAN"
}
installed_version_of() {
  local name="$1"
  scan_installed | awk -F'\t' -v want="$name" '$1==want{print $3; exit}'
}

state_write() { # state_write <name> <kind> <version> <file> <sha256>
  need_root
  mkdir -p "$DEST"
  if [ -n "$NODE_BIN" ]; then
    "$NODE_BIN" - "$STATE_FILE" "$1" "$2" "$3" "$4" "$5" <<'JSEOF'
const fs = require('node:fs')
const [file, name, kind, version, componentFile, sha256] = process.argv.slice(2)
let state = { format: 1, layout: 'components', components: {} }
try { state = JSON.parse(fs.readFileSync(file, 'utf8')) } catch (error) { if (error.code !== 'ENOENT') throw error }
state.format = 1
state.layout = 'components'
state.components = { ...(state.components ?? {}) }
state.components[name] = { kind, version, file: componentFile, sha256, installedAt: new Date().toISOString() }
state.updatedAt = new Date().toISOString()
fs.writeFileSync(file, JSON.stringify(state, null, 2) + '\n')
JSEOF
  else
    python3 - "$STATE_FILE" "$1" "$2" "$3" "$4" "$5" <<'PYEOF'
import json, os, sys, datetime
path, name, kind, version, component_file, sha256 = sys.argv[1:7]
state = {"format": 1, "layout": "components", "components": {}}
if os.path.exists(path):
    state = json.load(open(path))
state.setdefault("components", {})[name] = {
    "kind": kind, "version": version, "file": component_file, "sha256": sha256,
    "installedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
json.dump(state, open(path, "w"), ensure_ascii=False, indent=2)
open(path, "a").write("\n")
PYEOF
  fi
}

state_delete() {
  [ -f "$STATE_FILE" ] || return 0
  "$NODE_BIN" - "$STATE_FILE" "$1" <<'JSEOF'
const fs = require('node:fs')
const [file, name] = process.argv.slice(2)
const state = JSON.parse(fs.readFileSync(file, 'utf8'))
if (state.components) delete state.components[name]
fs.writeFileSync(file, JSON.stringify(state, null, 2) + '\n')
JSEOF
}

# 清单读取：有 node 用 node；全新安装时本机还没有 node（本体组件尚未解包），退到 python3。
json_query() { # json_query <file> count | field <index> <name> | version
  local file="$1" op="$2"
  shift 2
  if [ -n "$NODE_BIN" ]; then
    case "$op" in
      count)
        "$NODE_BIN" -e 'const fs=require("node:fs");console.log(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).components.length)' "$file" ;;
      field)
        "$NODE_BIN" -e '
          const fs=require("node:fs")
          const m=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))
          const c=m.components[Number(process.argv[2])]
          const value=c?.[process.argv[3]]
          if(Array.isArray(value)) console.log(value.join(",")); else if(value!==undefined) console.log(String(value))
        ' "$file" "$1" "$2" ;;
      *)
        "$NODE_BIN" -e 'const fs=require("node:fs");const m=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));console.log(m[process.argv[2]] ?? "")' "$file" "$op" ;;
    esac
    return 0
  fi
  python3 - "$file" "$op" "$@" <<'PYEOF'
import json, sys
file, op, *args = sys.argv[1:]
data = json.load(open(file))
if op == 'count':
    print(len(data.get('components', [])))
elif op == 'field':
    comp = data['components'][int(args[0])]
    value = comp.get(args[1])
    print(','.join(str(v) for v in value) if isinstance(value, list) else ('' if value is None else value))
else:
    print(data.get(op, ''))
PYEOF
}
component_field() { json_query "$MANIFEST" field "$1" "$2"; }
component_count() { json_query "$MANIFEST" count; }

resolve_component_file() { # resolve_component_file <manifest-relative-file>
  if [ -f "$WORK/$1" ]; then printf '%s' "$WORK/$1"; return 0; fi
  if [ -n "$SERVER" ]; then
    mkdir -p "$(dirname "$WORK/$1")"
    # 清单里的路径相对分发根（components/x.tar.gz），先按原路径取，再退回文件名。
    curl -fsSL --max-time 3600 "$SERVER/$1" -o "$WORK/$1" 2>/dev/null \
      || curl -fsSL --max-time 3600 "$SERVER/${1#components/}" -o "$WORK/$1" \
      || return 1
    return 0
  fi
  return 1
}

verify_sha() { # verify_sha <file> <sha256>
  [ -n "$2" ] || return 0
  local got
  got="$(sha256sum "$1" | cut -d' ' -f1)"
  [ "$got" = "$2" ] || fail "sha256 校验失败：$1（期望 ${2:0:12}…，实际 ${got:0:12}…）"
}

# ---------- 安装一个组件 ----------
install_component() { # install_component <index> [upgrade]
  local index="$1" mode="${2:-install}"
  local name kind version file sha
  name="$(component_field "$index" name)"
  kind="$(component_field "$index" kind)"
  version="$(component_field "$index" version)"
  file="$(component_field "$index" file)"
  sha="$(component_field "$index" sha256)"
  [ -n "$name" ] || fail "清单第 $index 项缺 name"

  local current
  current="$(installed_version_of "$name" "$kind" || true)"
  if [ "$mode" = "upgrade" ] && [ "$current" = "$version" ]; then
    log "跳过 $name（已是 $version）"
    echo "RESULT skipped $name $version"
    return 0
  fi

  echo "PHASE 准备 $name"
  local comp
  comp="$(resolve_component_file "$file")" || fail "缺少组件包：$file（离线分发目录不完整，或更新源不可达）"
  echo "PHASE 校验 $name"
  verify_sha "$comp" "$sha"

  # 组件自带的安装脚本负责它自己的目录；installer 只负责调度与状态。
  local stage
  stage="$(mktemp -d /var/tmp/dsh-installer-run-XXXXXX)"
  tar xzf "$comp" -C "$stage" package/install.sh 2>/dev/null || { rm -rf "$stage"; fail "组件包结构异常（缺 package/install.sh）：$file"; }
  chmod 755 "$stage/package/install.sh"

  echo "PHASE 安装 $name"
  local args=("--component" "$comp")
  [ "$mode" = "upgrade" ] && args+=("--upgrade")
  # 每个组件的安装脚本自己会动 $DEST；插件安装包不带 profile 播种（统一由 installer 做）。
  # 路径类变量按需透传，支持沙箱 DEST 与自定义 electron/glibc 目录。
  local comp_env=(DSH_DEST="$DEST" DSH_NODE_DIR="$INSTALL_NODE_DIR" DSH_SKIP_SEED=1 DSH_USER="${DSH_USER:-${SUDO_USER:-}}")
  local pass_name pass_value
  for pass_name in DSH_ELECTRON_DIR DSH_GLIBC_DIR DSH_CHROME_PATH DSH_DESKTOP; do
    pass_value="$(eval "printf '%s' \"\${$pass_name:-}\"")"
    [ -n "$pass_value" ] && comp_env+=("$pass_name=$pass_value")
  done
  if ! env "${comp_env[@]}" bash "$stage/package/install.sh" "${args[@]}"; then
    rm -rf "$stage"
    echo "ERROR $name 安装失败"
    return 1
  fi
  rm -rf "$stage"
  state_write "$name" "$kind" "$version" "${file#components/}" "$sha"
  echo "RESULT ok $name $version"
}

# ---------- 种子 ----------
seed_profile() {
  [ "$DO_SEED" = "1" ] || return 0
  [ -f "$DEST/seed-profile.sh" ] || { log "跳过 profile 播种（缺 $DEST/seed-profile.sh）"; return 0; }
  local target_user="${DSH_USER:-${SUDO_USER:-}}"
  local seed_node="$INSTALL_NODE_DIR/bin/node"
  [ -x "$seed_node" ] || seed_node="$DEST/node/bin/node"
  echo "PHASE 重播 profile"
  # DSH_HOME 显式指定时用它（沙箱测试 / 自定义部署）；否则用目标用户的家目录。
  local seed_home="${DSH_HOME:-}"
  if [ -z "$seed_home" ] && [ -n "$target_user" ] && [ "$target_user" != "root" ]; then
    local home
    home="$(getent passwd "$target_user" | cut -d: -f6)"
    [ -n "$home" ] && [ -d "$home" ] && seed_home="$home/.dsh"
  fi
  if [ -n "$seed_home" ] && [ "$(id -u)" = "0" ] && [ -n "$target_user" ] && [ "$target_user" != "root" ]; then
    mkdir -p "$seed_home"
    chown "$target_user":"$(id -gn "$target_user" 2>/dev/null || echo "$target_user")" "$seed_home" 2>/dev/null || true
    if sudo -u "$target_user" -H env DSH_HOME="$seed_home" SEED_NODE="$seed_node" \
        bash "$DEST/seed-profile.sh" "$DEST"; then
      echo "RESULT ok profile seeded"
      return 0
    fi
    echo "ERROR profile 播种失败（用户 $target_user）"
    return 1
  fi
  if [ -n "$seed_home" ]; then
    env DSH_HOME="$seed_home" SEED_NODE="$seed_node" bash "$DEST/seed-profile.sh" "$DEST" || { echo "ERROR profile 播种失败"; return 1; }
    echo "RESULT ok profile seeded"
    return 0
  fi
  SEED_NODE="$seed_node" bash "$DEST/seed-profile.sh" "$DEST" || { echo "ERROR profile 播种失败"; return 1; }
  echo "RESULT ok profile seeded"
}

# 清单留存：装完后把 $WORK/manifest.json 复制到 $DEST，之后的 status/verify 不再依赖介质。
persist_manifest() {
  [ -f "$WORK/manifest.json" ] || return 0
  mkdir -p "$DEST"
  cp -f "$WORK/manifest.json" "$DEST/manifest.json" 2>/dev/null || true
  chmod 644 "$DEST/manifest.json" 2>/dev/null || true
}

# ---------- 命令 ----------
cmd_list() {
  echo "分发目录: $WORK"
  echo "版本: $MANIFEST_VERSION（dsh $DSH_VER）"
  local count i
  count="$(component_count)"
  i=0
  while [ "$i" -lt "$count" ]; do
    local name kind version current state
    name="$(component_field "$i" name)"
    kind="$(component_field "$i" kind)"
    version="$(component_field "$i" version)"
    current="$(installed_version_of "$name" "$kind" || true)"
    if [ -z "$current" ]; then state="未安装"; elif [ "$current" = "$version" ]; then state="已安装"; else state="可升级 $current -> $version"; fi
    printf '  %-44s %-6s %-20s %s\n' "$name" "$kind" "$version" "$state"
    i=$((i + 1))
  done
}

cmd_status() {
  if [ "$JSON" = "1" ]; then
    SCAN="$(scan_installed)" "$NODE_BIN" - "$MANIFEST" "$DEST" <<'JSEOF'
      const fs = require('node:fs')
      const [manifestFile, dest] = process.argv.slice(1)
      const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'))
      const installed = new Map()
      for (const line of (process.env.SCAN ?? '').split('\n')) {
        if (line === '') continue
        const [name, kind, version] = line.split('\t')
        installed.set(name, { kind, version })
      }
      const components = manifest.components.map((component) => {
        const local = installed.get(component.name)
        return {
          name: component.name,
          kind: component.kind,
          version: component.version,
          installed: local?.version ?? null,
          needsUpdate: local === undefined ? true : local.version !== component.version,
          forced: false,
        }
      })
      console.log(JSON.stringify({
        distVersion: manifest.version,
        dshVersion: manifest.dshVersion,
        installedVersion: installed.get('@deepseek-ai/dsh')?.version ?? null,
        pluginCount: [...installed.values()].filter((entry) => entry.kind === 'plugin').length,
        components,
      }))
JSEOF
    return 0
  fi
  cmd_list
}

# ---------- 计划 ----------
print_plan() {
  local targets=("${ARGS[@]}")
  [ "${#targets[@]}" -eq 0 ] && targets=("all")
  local count i=0 target
  count="$(component_count)"
  echo "PHASE 计划"
  while [ "$i" -lt "$count" ]; do
    local name kind version current action wanted=0
    name="$(component_field "$i" name)"
    kind="$(component_field "$i" kind)"
    version="$(component_field "$i" version)"
    for target in "${targets[@]}"; do
      [ "$target" = "all" ] && wanted=1
      [ "$target" = "$name" ] && wanted=1
      [ "$target" = "body" ] && [ "$kind" = "body" ] && wanted=1
    done
    if [ "$wanted" = "1" ]; then
      current="$(installed_version_of "$name" "$kind" || true)"
      if [ -z "$current" ]; then action="安装"
      elif [ "$current" = "$version" ]; then action="跳过（已是最新）"
      else action="升级 $current -> $version"; fi
      printf '  %-44s %-6s %s\n' "$name" "$kind" "$action"
    fi
    i=$((i + 1))
  done
}

# apply：自动判定全新安装或升级（离线介质入口 install.sh 调它）。
cmd_apply() {
  print_plan
  if [ "$DRY_RUN" = "1" ]; then
    echo "RESULT plan-only"
    return 0
  fi
  need_root
  acquire_lock
  if [ -f "$DEST/app/node_modules/@deepseek-ai/dsh/package.json" ]; then
    cmd_upgrade
  else
    cmd_install
  fi
}

cmd_install() {
  need_root
  acquire_lock
  local count i targets=("${ARGS[@]}")
  count="$(component_count)"
  if [ "${#targets[@]}" -eq 0 ]; then targets=("all"); fi
  local only_body=0
  case "${targets[0]}" in
    all|"") ;;
    body) only_body=1 ;;
  esac
  local failed=0 body_done=0
  i=0
  while [ "$i" -lt "$count" ]; do
    local name kind
    name="$(component_field "$i" name)"
    kind="$(component_field "$i" kind)"
    local wanted=0
    for target in "${targets[@]}"; do
      [ "$target" = "all" ] && wanted=1
      [ "$target" = "$name" ] && wanted=1
      [ "$target" = "body" ] && [ "$kind" = "body" ] && wanted=1
    done
    if [ "$wanted" = "1" ]; then
      # 插件依赖本体：没有任何本体安装在位时，先装本体。
      if [ "$kind" = "plugin" ] && [ "$body_done" = "0" ] && [ ! -f "$DEST/app/node_modules/@deepseek-ai/dsh/package.json" ]; then
        log "插件依赖本体，先安装本体组件"
        install_component 0 install || { failed=$((failed + 1)); break; }
        body_done=1
      fi
      install_component "$i" install || failed=$((failed + 1))
      [ "$kind" = "body" ] && body_done=1
    fi
    i=$((i + 1))
  done
  seed_profile || failed=$((failed + 1))
  [ "$failed" -eq 0 ] || { echo "ERROR 有 $failed 个步骤失败"; return 1; }
  persist_manifest
  echo "RESULT done"
}

cmd_upgrade() {
  need_root
  acquire_lock
  local count i targets=("${ARGS[@]}")
  count="$(component_count)"
  [ "${#targets[@]}" -eq 0 ] && targets=("all")
  local failed=0 upgraded=0
  i=0
  while [ "$i" -lt "$count" ]; do
    local name kind
    name="$(component_field "$i" name)"
    kind="$(component_field "$i" kind)"
    local wanted=0
    for target in "${targets[@]}"; do
      [ "$target" = "all" ] && wanted=1
      [ "$target" = "$name" ] && wanted=1
    done
    if [ "$wanted" = "1" ]; then
      install_component "$i" upgrade || failed=$((failed + 1))
    fi
    i=$((i + 1))
  done
  seed_profile || failed=$((failed + 1))
  [ "$failed" -eq 0 ] || { echo "ERROR 有 $failed 个组件升级失败"; return 1; }
  persist_manifest
  echo "RESULT done"
}

cmd_remove() {
  need_root
  acquire_lock
  [ "${#ARGS[@]}" -gt 0 ] || fail "用法: installer.sh remove <插件名>..."
  local failed=0
  for name in "${ARGS[@]}"; do
    case "$name" in
      @deepseek-ai/dsh|body) fail "本体不能用 remove 卸载；请用 $DEST/uninstall.sh" ;;
    esac
    if [ -d "$DEST/plugins/$name" ]; then
      echo "PHASE 卸载 $name"
      # 组件的卸载逻辑在它自己的安装脚本里；按文件名 slug 找组件包（组件包内
      # 也写了 component.json，但逐个解包太慢）。
      local comp="" slug
      slug="$(printf '%s' "$name" | sed 's/^@//; s#/#-#g')"
      for candidate in "$WORK"/components/"$slug"-*.tar.gz; do
        [ -f "$candidate" ] && { comp="$candidate"; break; }
      done
      if [ -n "$comp" ]; then
        local stage; stage="$(mktemp -d /var/tmp/dsh-installer-run-XXXXXX)"
        tar xzf "$comp" -C "$stage" package/install.sh 2>/dev/null || true
        if [ -f "$stage/package/install.sh" ]; then
          DSH_DEST="$DEST" DSH_NODE_DIR="$INSTALL_NODE_DIR" DSH_SKIP_SEED=1 \
            bash "$stage/package/install.sh" --component "$comp" --uninstall || failed=$((failed + 1))
        fi
        rm -rf "$stage"
      else
        rm -rf "$DEST/plugins/$name"
      fi
    else
      log "未安装：$name"
    fi
    state_delete "$name"
    echo "RESULT removed $name"
  done
  seed_profile || failed=$((failed + 1))
  [ "$failed" -eq 0 ] || { echo "ERROR 有组件卸载失败"; return 1; }
  echo "RESULT done"
}

cmd_seed() {
  need_root
  acquire_lock
  seed_profile
}

cmd_verify() {
  local problems=0
  check() { if eval "$1"; then log "OK   $2"; else log "FAIL $2"; problems=$((problems + 1)); fi; }
  check "[ -f '$DEST/app/node_modules/@deepseek-ai/dsh/package.json' ]" "本体已安装"
  check "[ -x '$INSTALL_NODE_DIR/bin/node' ]" "白名单 node 存在（$INSTALL_NODE_DIR）"
  local count i
  count="$(component_count)"
  i=0
  while [ "$i" -lt "$count" ]; do
    local name kind version current
    name="$(component_field "$i" name)"
    kind="$(component_field "$i" kind)"
    version="$(component_field "$i" version)"
    current="$(installed_version_of "$name" "$kind" || true)"
    if [ -n "$current" ]; then
      if [ "$kind" = "plugin" ]; then
        check "[ -f '$DEST/plugins/$name/package.json' ]" "$name 目录存在"
        check "[ -L '$DEST/plugins/$name/node_modules/@deepseek-ai' ] || [ -d '$DEST/plugins/$name/node_modules/@deepseek-ai' ]" "$name 宿主包链接存在"
      fi
      [ "$current" = "$version" ] && log "OK   $name@$current" || { log "WARN $name 版本 $current ≠ 清单 $version"; }
    fi
    i=$((i + 1))
  done
  local profile="${DSH_HOME:-$HOME/.dsh}/profiles/web"
  if [ -f "$profile/package.json" ]; then
    check "grep -q '@deepseek-ai/dsh' '$profile/package.json'" "profile 已播种"
  else
    log "WARN profile 不存在（$profile）"
  fi
  [ "$problems" -eq 0 ] || { echo "ERROR 自检有 $problems 项失败"; return 1; }
  echo "RESULT ok verify"
}

case "$COMMAND" in
  list) cmd_list ;;
  status) cmd_status ;;
  install) cmd_install ;;
  upgrade) cmd_upgrade ;;
  apply) cmd_apply ;;
  remove) cmd_remove ;;
  seed) cmd_seed ;;
  verify) cmd_verify ;;
  doctor)
    [ -x "$DEST/doctor.sh" ] || fail "未安装 doctor.sh（先装本体）"
    exec "$DEST/doctor.sh" "$DEST" ;;
  ""|help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) fail "未知命令：$COMMAND（可用：list status install upgrade remove seed verify doctor）" ;;
esac
