# DSH 兼容性体检报告（面向上游修复）

- **被测环境**：DeepSeek Harness `0.2.1-rc.2`（安装内 357 个 `@deepseek-ai/*` 官方包全部同版本，单一一致安装）
- **运行时**：Node `v22.23.2` · linux-x64 · ABI 127 · **UOS Desktop 20 / Deepin1 · glibc 2.28**（libc、libm 最高符号均为 `GLIBC_2.28`）
- **服务状态**：`127.0.0.1:3080` 存活，HTTP 200
- **插件目录**：`~/.dsh/profiles/web`（12 个第三方插件）
- **方法**：静态清单 + 语义化版本判定 + 原生模块 `dlopen` 实测 + 端到端工具实测（MCP、univer、vision）+ 全量启动日志/会话扫描；结论以实机运行为准
- **日期**：2026-10-22

> 一句话结论：**插件与版本层 100% 兼容、无阻断**。真正的兼容性问题只有 1 个（**glibc 2.28 太旧，univer 等原生二进制无法加载，导致 univer office 内容读写全瘫**）；其余为配置卫生问题与离线环境特性。

---

## 0. 严重度总览

| ID | 标题 | 严重度 | 类型 | 影响面 | 归属 |
|----|------|--------|------|--------|------|
| **B1** | univer 原生公式/导出二进制要 glibc≥2.29，本机 2.28 → **univer office 全瘫** | 🔴 Blocker | 依赖打包 / 二进制 ABI | Sheet/Doc/Base/Board 全部内容读写 + xlsx/docx 导入导出 | `dsh-univer-office` + 上游 `@univerjs-pro/*` |
| B2 | computer-use / speech MCP 原生二进制要 glibc≥2.30/2.32 → 加载失败 | 🟠 High | 依赖打包 / 二进制 ABI | `dsh-experimental-computer-use-*`、`dsh-experimental-speech-to-text-sensevoice` | 上游 `@trycua/*`、`sherpa-onnx-node` |
| **C1** | cordis.patch.yml 有指向"未安装插件"的孤儿 patch 行，每次启动报 `not found`，且真实浏览器被错配成 `browser360ent` | 🟠 High | 配置生成（seed-profile.sh） | browser-use MCP 配置不生效；用的是 Deepin 浏览器而非声明的 360 | 配置层（seed-profile.sh） |
| C2 | seed-profile.sh 的 `dsh-offline` 标记块错位，会误包 `better-workspace` 行 | 🟡 Medium | 配置生成（seed-profile.sh） | 下次维护可能覆盖用户 workspace 配色 | 配置层（seed-profile.sh） |
| C3 | remote-mobile 的对外监听前提在该 build 无法满足（底座拒绝 `0.0.0.0`） | 🟡 Medium | 功能不兼容 / 文档 | `@yezack/dsh-remote-mobile` 的核心诉求 | 底座 `dsh-host-webserver` 设计 |
| C4 | `dsh-client-runtime` 在核心中缺失，被 2 个插件引用 | 🟡 Medium | 依赖缺失 | dream-skin（已禁用）、remote-mobile 客户端 | 核心发布 / 插件声明 |
| C5 | `@huanlin/dsh-plugin-better-locale` 未安装（better-sidebar 可选 peer） | 🔵 Low | 可选依赖缺失 | better-sidebar 语言增强静默降级 | 配置 / 插件 |
| C6 | patch 文件内事实性注释错误 | 🔵 Low | 文档 | 误导维护者 | 配置层 |
| C7 | `@linxin666/dsh-client-ui-git-graph` 把 `engines.dsh` 放在非规范位置 | 🔵 Low | 清单规范 | 恰好有 peer 兜底，当前无害 | 第三方插件 |
| E1 | `npm` 命令 shim 相对路径解析失败（需完整路径调用） | 🔵 Low | 环境 | 插件安装/更新 | 环境/打包 |
| E2 | `pnpm` 未安装（plugin-manager 用它 list/install） | 🔵 Low | 环境 | 插件管理 | 环境/打包 |
| E3 | dshmarket 抓目录失败 | ⚪ Info | 环境 | 离线特性，非缺陷 | 环境 |

---

## 1. 🔴 B1 — univer 原生二进制 glibc 不兼容（核心阻断）

### 现象
对**任意** univer 内容操作（哪怕对新建的空 Base Unit 做只读 `univer_inspect`）都抛：

```
UNIT_CONTENT_WORKER_INVALID_RESPONSE: Unit content worker returned invalid JSON.
  .../dsh-univer-office/artifacts/unit-content-worker.mjs
Error: Failed to load native formula engine binding.
  platform=linux arch=x64 expected npm package=@univerjs-pro/engine-formula-rust-binding
  - @univerjs-pro/engine-formula-rust-binding:
    /lib/x86_64-linux-gnu/libm.so.6: version `GLIBC_2.29' not found
    (required by .../engine-formula-rust-binding-linux-x64-gnu/univer-formula.linux-x64-gnu.node)
    at RustFormulaEngineSession.initialize (...unit-content-worker.mjs:253894)
    at RustCalculateFormulaService.execute (...unit-content-worker.mjs:255474)
    at CalculateController2._calculate (...unit-content-worker.mjs:61230)
```

`univer_execute` / `univer_inspect` 全崩；**仅 `univer_new` / `univer_unit` / `univer_status`（元数据操作）可用**。因为公式引擎在内容 worker 启动即加载，一次失败会污染该 worker，后续普通读写也一并失败。

### 根因
`dsh-univer-office@0.3.7` 的两个原生依赖**要求比本机更高的 glibc**：

| 原生包（dsh-univer-office 直接依赖，锁 1.0.1） | 最低 glibc | 本机 2.28 |
|---|---|---|
| `@univerjs-pro/engine-formula-rust-binding-linux-x64-gnu` | **2.29** | ✗ |
| `@univerjs-pro/exchange-node-binding-linux-x64-gnu`（xlsx/docx 导入导出） | **2.29** | ✗ |

`libsql`（同样被 univer 依赖，走 `@libsql/linux-x64-gnu`）**实测 dlopen 成功**，不是问题源。

### 修复方案（择一）
1. **首选**：让 `@univerjs-pro/{engine-formula-rust-binding,exchange-node-binding}` 提供 **glibc 2.28 基线构建**（Rust `cargo` 侧设 `CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU` 的 `gnu.2.28` / mingw 交叉基线，或提供 musl 变体）。这是唯一不动用户系统的修法。
2. 若上游无法降基线：在 univer-office 里对绑定加载做 **try/catch → 纯 JS 公式回退**（若 Univer 有 `@univerjs/engine-formula` 的 JS 实现），至少让"无公式/无导入导出"的读写不被拖垮。
3. 运维临时绕过：升级到 glibc ≥ 2.29 的系统镜像。

### 复现
```bash
cd /deepseek-harness/app/node_modules
node -e "require('@univerjs-pro/engine-formula-rust-binding')"   # GLIBC_2.29 not found
node -e "require('@univerjs-pro/exchange-node-binding')"          # GLIBC_2.29 not found
node -e "require('libsql'); console.log('ok')"                    # ok
strings /lib/x86_64-linux-gnu/libm.so.6 | grep -o '^GLIBC_2\.[0-9]*' | sort -V | tail -1  # GLIBC_2.28
```

---

## 2. 🟠 B2 — computer-use / speech MCP 原生二进制 glibc 不兼容

同类 ABI 问题，来自未在主会话暴露的可选实验 bundle（一旦启用即加载失败）：

| 包（glibc 需求） | 引入它的上游 bundle |
|---|---|
| `@trycua/cua-driver-linux-x64-gnu/cua_driver_node_runtime.node`（**GLIBC_2.30**）；该包又拉入 `@ubjs/node-linux-x64-gnu`（**GLIBC_2.30**） | `@deepseek-ai/dsh-experimental-computer-use-cua-driver-native` |
| `sherpa-onnx-linux-x64/sherpa-onnx.node`（**GLIBC_2.32**） | `@deepseek-ai/dsh-experimental-speech-to-text-sensevoice` |

> 更正：`@ubjs/node` 由 `@trycua/cua-driver`（computer-use）引入，**不属于 univer**。

**修复**：同 B1，上游把 `@trycua/cua-driver`、`sherpa-onnx-node` 换成 glibc-2.28 兼容构建；或在 bundle 层对加载失败做优雅降级并明确提示"平台不支持"。

```bash
node -e "import('@trycua/cua-driver').catch(e=>console.log(e.message))"  # GLIBC_2.30 not found
node -e "require('sherpa-onnx-node')"                                     # 找不到/加载失败
```

---

## 3. 🟠 C1 — cordis.patch.yml 指向"未安装插件"的孤儿 patch 行

### 现象
每次启动日志（最新一份，本次已复核仍存在）都有一条 warn：
```
root warn: patch: entry "experimental-browser-use-chrome-devtools-mcp" not found
```

### 根因（机制，非版本不匹配）
`~/.dsh/profiles/web/cordis.patch.yml:36-42` 有一行用 `name:` 定位插件：
```yaml
- id: experimental-browser-use-chrome-devtools-mcp
  name: "@deepseek-ai/dsh-experimental-browser-use-chrome-devtools-mcp"
  config: { mode: launch, headless: false, isolated: true, executablePath: /usr/bin/browser360ent-cn-stable }
```
但：
- 该包 `dsh.bundle.patch` 为 `undefined`（它不是会自带插入行的 bundle 层）；
- 遍历所有已启用 bundle 的 patch/insert，**没有任何一处插入 `id: experimental-browser-use-chrome-devtools-mcp` 的实例行**；
- 真正生效的是 `@deepseek-ai/dsh-web-app/cordis.patch.yml:640` 插入的 **`mcp-chrome-devtools`** 行（`@deepseek-ai/dsh-mcp-client`）。

⇒ 该 patch 行定位不到目标，`isolated/headless/executablePath` 全部静默丢弃。

### 连锁真实影响（重要）
生效的 `mcp-chrome-devtools` 行用：
```yaml
executablePath: !!js "process.env.DSH_CHROME_PATH ?? '/usr/bin/browser'"
```
本机 `DSH_CHROME_PATH` **未设** → browser MCP 实际用 **Deepin 浏览器 `/usr/bin/browser`**，**不是** 孤儿行里写的 360。且 patch 注释自述 360 在 UOS20 会 `trap int3` abort（所以"删孤儿行"反而更安全，注册它会引入会崩的浏览器）。

### 修复
- **推荐**：删除 `cordis.patch.yml:36-42` 整段孤儿 config（MCP 已用 dsh-web-app 默认值正常工作）。
- 或：把 `@deepseek-ai/dsh-experimental-browser-use-chrome-devtools-mcp` 加进 `package.json → dsh.profile.bundles`（但需确认 360 浏览器不会 abort）。

### 判定证据
- 日志 warn 仍在最新启动记录中；同一份记录里 webserver 曾因 `host:"0.0.0.0"` 崩溃（该值现已不在文件里），说明 127.0.0.1 修复与这条孤儿行是同一份配置同时产出 → 警告确属当前配置。

---

## 4. 🟡 C2 — seed-profile.sh 维护块错位（会误覆盖用户配置）

`~/.dsh/profiles/web/cordis.patch.yml`：
- L86 `# >>> dsh-offline: render browser`
- L89-91 `- id: univer` 的 `browserExecutablePath` 行（正常，应被本块管理）
- **L92-101 `- id: better-workspace … styling` 被误包进本块**
- L103 `# <<< dsh-offline: render browser`

后果：seed-profile.sh 下次重写"render browser"块时，会把用户自己的 `better-workspace.styling`（工作区配色/glow/stroke/icon 等）一并覆盖或搬移。

另注：L87 注释"univer 的渲染浏览器，与 chrome-devtools MCP 同一个"与实际不符（univer 用 `DSH_CHROME_PATH??/usr/bin/browser`，browser MCP 走另一行，见 C1）。

**修复**：把"render browser"结束标记 `# <<<` 移到 univer 行之后（L92 之前），别让 better-workspace 落入维护块。

---

## 5. 🟡 C3 — remote-mobile 对外监听前提无法满足

`@yezack/dsh-remote-mobile` 的前置假设是"对外监听"。但底座 `dsh-host-webserver` **按设计拒绝 `0.0.0.0`**（避免向网络暴露 RCE，见 `dsh-host-webserver/lib/index.js:255`），schema 只接受具体 IP。⇒ remote-mobile 的核心诉求在该 build 上**无法实现**。

**修复方向（需上游确认设计意图）**：
- 若确需 LAN 访问：明确支持"绑定某个具体网卡 IP + token 校验"作为受支持路径（而非 0.0.0.0），并在 remote-mobile 文档里改成此写法；
- remote-mobile 的 patch 注释「schema 仅接受 '127.0.0.1'/'0.0.0.0' 两个字面量」**是错的**（schema 是 `z.transform(z.string(),…)`，接受任意具体 IP）。

---

## 6. 🟡 C4 — `@deepseek-ai/dsh-client-runtime` 核心缺失

核心 `node_modules/@deepseek-ai/` 下**没有** `dsh-client-runtime`（已确认非改名：仅有 `dsh-client-test-runtime`、`dsh-ptc-runtime`、`dsh-experimental-*-runtime`）。被 3 处引用：

| 引用方 | 方式 | 状态 |
|---|---|---|
| `dsh-dream-skin` | `peerDependencies`（真实 peer） | 该插件**已禁用**，风险被冻结 |
| `@yezack/dsh-remote-mobile` | `dsh.client.inject[0]`（**已启用**） | host 侧无 `@deepseek-ai` import，node 启动安全；仅客户端 bundle 合成期有风险（静态判断，未触发实崩） |
| `dshmarket` | devDependency | 构建期，无害 |

**修复**：随核心发布 `@deepseek-ai/dsh-client-runtime`（满足 `>=0.1.0-rc.6 <0.3.0-0`），或让上述插件改引用现存的运行时包。

---

## 7. 🔵 C5 / C6 / C7 — 低危卫生问题

- **C5**：`@huanlin/dsh-plugin-better-locale@^0.1.0` 未安装（`node_modules/@huanlin` 不存在），是 `dsh-better-sidebar` 的可选 peer；不在兼容闸门内，无启动影响，仅语言增强静默降级。
- **C6**：patch 文件多处事实性错误注释：`0.0.0.0` 的拒绝原因、"schema 仅两个值"、"univer 与 chrome-devtools 同一浏览器"。建议据本文件 §3/§4/§5 更正，避免误导。
- **C7**：`@linxin666/dsh-client-ui-git-graph` 把 dsh 引擎约束写在 `dsh.engines.dsh`（非规范），顶层 `engines` 只有 `node`。加载器只读顶层 `engines`，此处恰好另有 peer `@deepseek-ai/dsh: ">=0.2.1-rc.2"` 兜底才通过。建议该插件把约束移到顶层 `engines.dsh`。

---

## 8. ⚪ 环境项（非插件缺陷，影响插件管理）

- **E1 npm shim 坏**：`/var/tmp/dsh-node/bin/npm` 是 `require('../lib/cli.js')(process)` 的相对路径 shim，node 解析的是 `bin/../lib/cli.js`（不存在）而非真实包路径。**完整路径可正常工作**：
  ```bash
  node /var/tmp/dsh-node/lib/node_modules/npm/bin/npm-cli.js --version   # 10.9.8 ✅
  ```
  修复：把 shim 改为绝对 `require('/var/tmp/dsh-node/lib/node_modules/npm/lib/cli.js')`，或用官方 npm 的 wrapper。
- **E2 pnpm 未安装**：plugin-manager 报 `spawn pnpm ENOENT`（`.plugin-manager/logs/operation-*/pnpm.log`）。离线镜像需预置 pnpm 才能装/更新插件。
- **E3 dshmarket 抓目录失败**：`awesome-dsh-plugin.com/plugins.json fetch failed`，离线环境特性，非缺陷。

---

## 9. ✅ 已验证通过的项（无需修复，作为基线留档）

- **插件兼容 12/12**：按 DSH 真实闸门（`dsh-app-boot/lib/index.js:276-299`：`includePrerelease:true`；有 `engines.dsh` 则只看它，否则只校验 `@deepseek-ai/dsh*` peer）判定，全部 `compatible`。npm **strict** 模式会把 8/12 报成 peer 不满足，属假阳性，不代表加载失败。
- **engines.node**：全部满足（最紧 `^22.19.0 || >=24`）。
- **react/react-dom**：磁盘上确实没有，但由 `dsh-client-web/lib/index.js:211 getStaticModules()` 作为冻结浏览器平台模块注入（react、react/jsx-runtime、react-dom、react-dom/client），客户端插件运行时满足，属设计。
- **MCP chrome-devtools 端到端可用**：launch + `--isolated`，Deepin/360 二进制在桌面会话下正常；导航/snapshot/screenshot/lighthouse 实测通过。
- **视觉（read_image）可用**：本会话实测 2×2 PNG 经 `read_image` 正常读回并被模型接收；历史 `does not declare image input` 早于 `input:[text,image]` 配置，现已不成立。
- **dsh 核心原生模块**：libsql、node-pty、sharp、lightningcss、koffi、rolldown、`@deepseek-ai/node-addon-system` 全部 dlopen 成功。
- **已自愈**：webserver `0.0.0.0` 崩溃已由 `host:'127.0.0.1'` 修复并生效（127.0.0.1:3080 / HTTP 200）。

---

## 10. 附：本次体检用的可复现校验片段

```bash
# 原生 ABI 逐个 dlopen
for f in $(find /deepseek-harness/app/node_modules -name '*.node' | grep -E 'linux-x64|linux_x64'|grep -v musl|grep -v arm64); do
  node -e "try{process.dlopen({exports:{}},'$f');console.log('OK')}catch(e){console.log('FAIL '+e.message.split('\n')[0])}" \
    | sed "s#^#$f  #"
done
# 版本闸门（对单个插件）
node -e "const s=require('/deepseek-harness/app/node_modules/semver');const j=require('<plugin>/package.json');const v='0.2.1-rc.2';const e=(j.engines||{}).dsh;if(e){console.log('engines.dsh',e,s.satisfies(v,e,{includePrerelease:true}))}"
```

> 本报告基于实机运行验证；`/home/uos/.dsh` 未做任何修改，临时产物已清理。
