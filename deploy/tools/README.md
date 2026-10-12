# deploy/tools

离线镜像的构建与验证工具。`../uos/` 是从构建机带过去的脚本，这里是从**开发机**
驱动和验证整个流程的工具。

## 构建顺序

```powershell
# 1. 出 release 产物（319 个 dsh tarball + 9 个 vendor tarball）
pnpm run build:official
pnpm run release:pack --family dsh
pnpm run release:pack --family vendor --out dist/npm-vendor

# 2. 生成索引：读每个 tarball 真实的 name/version，供离线装机消费
pwsh -File deploy/tools/gen-index.ps1 -Repo . -Out _stage\uos\tarball-index.json

# 3. 组装传输包（release 产物 + deploy\uos\* + extras\*.tgz → 单个 tar.gz）
pwsh -File deploy/tools/assemble-bundle.ps1
```

第 3 步的产物 `_stage/dsh-tarballs.tar.gz` 上传到构建机，在那里跑
`../uos/materialize-uos.sh` → `../uos/make-package.sh` 得到最终离线包。

> 顺序不能颠倒：`release:pack` 会校验 `DSH_CLIENT_COMMIT_HASH`，**改完源码必须
> 重新 `build:official` 再打包**，否则 pack 直接失败。

## 验证工具

| 工具 | 检查什么 | 怎么跑 |
|---|---|---|
| `check-template.mjs` | compat 脚本模板里不能出现反引号（会提前终止模板字符串） | `node deploy/tools/check-template.mjs packages/host/web-compat/src/compat-script.ts` |
| `test-compat.mjs` | 旧浏览器兼容层的 JS 行为回归（55 项） | `node deploy/tools/test-compat.mjs` |
| `test-injection.mjs` | compat 脚本注入到 HTML 的位置与顺序（18 项） | `node deploy/tools/test-injection.mjs` |
| `check-mcp-row.mjs` | web-app patch 里 chrome-devtools MCP 行的路径、参数 | 见文件头的参数说明 |
| `find-tailscale-block.mjs` | 定位 dsh-remote-mobile 客户端 bundle 里 Tailscale 块的精确边界 | `node deploy/tools/find-tailscale-block.mjs <client.js>` |
| `test-hide-tailscale.mjs` | 在副本上验证隐藏补丁：删对了块、语法通过、相邻块完好、幂等 | `node deploy/tools/test-hide-tailscale.mjs` |

### 浏览器侧

`css-test.html` 与 `mutation-test.html` 需要在浏览器里跑，并加载同目录的
`compat-standalone.js`（生成产物，不进仓库）：

```sh
node --import tsx/esm deploy/tools/gen-compat-standalone.mjs _stage
```

- `css-test.html` —— `color-mix` 回退与真实解析的差分对比（强制
  `CSS.supports('color','color-mix(...)')` 返回 false，模拟 Chrome 108）
- `mutation-test.html` —— 兼容层的调度开销。它制造 120 帧的 class 抖动，读
  `window.__DSH_WEB_COMPAT_STATS__` 看这期间跑了几轮。修复前是 119 轮，修复后
  是 0 轮；把 `attributeFilter` 换回含 `class` 的旧版即可复现对照组。

### cdp-lite-mcp.js

一个不依赖 puppeteer、直接用内置 fetch + WebSocket 讲 CDP 的 MCP 服务端。它是
排查期的产物：某些厂商 Chromium 上 puppeteer 系的 MCP 能初始化、能列出工具，
却完不成任何真实操作，而同一个浏览器用它就正常。

**它没有接进离线镜像**，镜像用的是 `@yezack/chrome-devtools-mcp-108`。留着是作为
那条路径再次出问题时的退路。
