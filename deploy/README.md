# DeepSeek Harness 离线部署方案（统信 UOS 20）

在**内网、无外网**环境下，把 DeepSeek Harness 部署到**统信 UOS 20**。

做成「**解压即用**」的单一离线包，目标机不需要联网、不需要 Docker、不需要编译器。

---

## 交付物

| 平台 | 文件 | dsh 版本 | 大小 | sha256 |
|---|---|---|---|---|
| UOS 20 (x86_64) | `dsh-uos-offline-0.2.0-rc.2.tar.gz` | 0.2.0-rc.2 | 558 MB | `e3efd7b71d3767c7e8c22066d891810d884533d9e2d1bd6079e0816cd5d036e4` |

包含：对应版本的 `dsh` + `Node.js 22.23.2` + 全部依赖树（约 1.5 GB 解压后）+ 安装/启动/卸载脚本 + 说明。

---

## 一、前提：为什么需要这些变通

两条硬约束决定了方案形态：

1. **Node 版本门槛**：DSH 要求 `^22.19.0 || >=24`，而 UOS 20 自带的 Node 只有 10.24。因此必须自带 Node 22。
2. **执行路径白名单**：UOS 20 的 `deepin-elf-verify` 只允许白名单目录中的可执行文件运行，而 Node 22 的二进制与原生模块默认都不在白名单里（见下）。

---

## 二、统信 UOS 20

### 2.1 核心障碍：deepin-elf-verify 执行白名单

UOS 20 有一个自研服务负责校验可执行文件：

```
deepin-elf-verify.service   (ExecStart=/usr/sbin/deepin-elf-verify)
白名单: /etc/deepin-elf-verify/whitelist
```

**不在白名单目录中的可执行文件（含 `.node` 原生模块）会被拦截**，表现为段错误（SIGSEGV）或 `failed to map segment from shared object`。

判定实验（同一个最小 C 程序，只换目录）：

| 目录 | 结果 |
|---|---|
| `/tmp` | 段错误 |
| `/home/uos` | 段错误 |
| `/usr/bin` | 段错误 |
| **`/var/tmp`** | **正常运行** |

白名单里**唯一的用户可写目录就是 `/var/tmp/`**。

> 重要澄清：这**与 glibc 无关**。官方 Node 22 要求 glibc ≥2.28，UOS 20 正好是 2.28，二进制本身完全兼容。所有段错误都是白名单造成的。

### 2.2 三处适配

| # | 问题 | 根因 | 解法 |
|---|---|---|---|
| 1 | Node 22 段错误 | 二进制不在白名单路径 | Node 安装到 `/var/tmp/dsh-node/` |
| 2 | 原生模块 `failed to map segment` | 加载器 `node-addon-native-custom-loader` 默认把缓存放到 **`/tmp`**（被拦） | 设 `NARB_NATIVE_CACHE_DIR=/var/tmp/dsh-native-cache`。该加载器**原生支持此环境变量**，无需改代码 |
| 3 | `koffi` 加载失败 | 它的 `.node` 位于应用目录（非白名单） | 预编译包 `@koromix/koffi-linux-x64` 放 `/var/tmp`，再从应用内 `koffi/build/koffi/linux_x64` **软链接**过去（命中 koffi 的 fallback 解析路径） |

此外，「`EACCES: mkdir .../home/profiles/web`」是因为安装脚本以 root 运行、`DSH_HOME` 落在 root 属主目录 —— 已把 `DSH_HOME` 默认改为用户可写的 `~/.dsh`。

### 2.3 构建期的坑（对重新打包有用）

**物化依赖树时**

| 问题 | 根因 | 解法 |
|---|---|---|
| `koffi` 源码编译失败 | 它硬编码 `-march=x86-64-v2`（`cnoke.cjs:320`），需要 **GCC 11+**，而 UOS 20 自带 GCC 8.3 | 改用**官方预编译包** `@koromix/koffi-linux-x64`，完全不编译 |
| npm 崩溃 `Cannot read properties of null (reading 'edgesOut')` | 大量 `file:` 依赖触发 npm/arborist 缺陷（`build-ideal-tree.js:1289` 的 `#loadPeerSet` 对 `node.parent` 缺 null 检查） | 用 `--legacy-peer-deps --ignore-scripts` 安装 |
| `npm` 报 `/usr/bin/env: "node": 没有那个文件或目录` | `node_modules/.bin/npm` 是 `#!/usr/bin/env node` 脚本，依赖 PATH 解析 | 直接用 `node <node>/lib/node_modules/npm/bin/npm-cli.js` 调用 |
| npm 报 `ENOENT ... uv_cwd` | 当前工作目录已被删除，`process.cwd()` 失败 | 运行前先 `cd` 到确实存在的目录 |

**编译源码时（0.2.0-rc.2 新增）**

| 问题 | 根因 | 解法 |
|---|---|---|
| `tsc` 报 `micromark-util-types` 出现 2.0.2 与 2.0.3 两个版本导致类型冲突 | 用 `pnpm install`（非 frozen）会**改写 `pnpm-lock.yaml`**，使依赖解析漂移 | 必须用 `pnpm install --frozen-lockfile` |
| 清干净锁文件后 `tsc -b` 仍报同类冲突 | 旧版本遗留的 362 个 `.tsbuildinfo` 与 314 个 `lib/` 让增量编译拿着旧声明文件比对 | 先 `pnpm run clean` 再 `build:official` |

另外两点：

- **`pnpm install` 的自我 rename 冲突**：仓库把 `pnpm` 自己也列在 `devDependencies`，某些组合下会报 `ERR_PNPM_EPERM: rename '...pnpm_tmp_*' -> '...pnpm'`。用 `packageManager` 指定的 **11.7.0** 版本（`corepack prepare pnpm@11.7.0 --activate`）可正常安装；若仍失败，临时从 `devDependencies` 移除该声明（**不要提交这个改动**）。
- **不要用 `pnpm run build` 产打包用的构建记录**，用 `build:official`；随后 `release:pack` 会校验构建产物。

### 2.4 用法

```
tar xzf dsh-uos-offline-0.2.0-rc.2.tar.gz
cd package
sudo ./install.sh                      # 可 DSH_DEST=/opt/dsh 自定义位置
/dsh-uos/start-web.sh                  # 普通用户运行
```

启动脚本会打印带 token 的地址，例如：

```
dsh web: http://127.0.0.1:3080/?token=XXXXXXXX
```

### 2.5 安装后的目录

```
/dsh-uos/app                   应用与全部依赖
/dsh-uos/start-web.sh          启动脚本
/dsh-uos/uninstall.sh          卸载脚本
/var/tmp/dsh-node/             Node 运行时（白名单路径）
/var/tmp/dsh-native-cache/     原生模块缓存 + koffi（白名单路径）
~/.dsh/                        DSH_HOME
```

> `/var/tmp` 可能被系统清理。若 node 丢失，重新执行 `sudo ./install.sh` 即可。

### 2.6 为什么不能打包成单文件 AppImage

AppImage 在这里**做得出但跑不起来**，原因是上面的白名单机制：

| 层 | 事实 | 结论 |
|---|---|---|
| 运行时依赖 | `libfuse2` 已安装（`/lib/x86_64-linux-gnu/libfuse.so.2`），`/dev/fuse` 存在 | 具备 |
| 打包工具 | `appimagetool` 未安装 | 可补 |
| **执行路径** | AppImage 把 squashfs 挂载到 `/tmp/.mount_<名>/`，其中的 `node` 二进制就从该路径执行 | **被白名单拦截** |

白名单共 31 条，含 `/tmp` 的只有三条特定路径（`/tmp/.org.chromium.Chromium`、`/tmp/mono-bundle-`、`/tmp/.abcwltcodec`），**没有 `/tmp` 的通配规则**。实测同一个原生模块文件：

```
/var/tmp/p.node  -> OK
/tmp/p.node      -> failed to map segment from shared object
```

`--appimage-extract-and-run` 同样解压到 `/tmp`，无法规避。此外 AppImage 文件自身也要放在 `/var/tmp` 才能被执行。

**单文件可执行的可行替代**：自解压安装器（makeself 风格）——一个 `.run` 文件内含 `tar.gz`，运行时解压到 `/var/tmp` 与安装目录再启动。执行路径落在白名单内，因此可用。本质是当前 tar.gz 去掉手动解压那一步。

---

## 三、验证结果

在**还原后的干净镜像**上做过端到端验证（包版本 0.2.0-rc.2）。

```
install.sh                 -> 安装完成
node -v                    -> v22.23.2
dsh --version              -> 0.2.0-rc.2
koffi 原生模块             -> KOFFI_OK function
node-addon-require-builtin -> NARB_OK
start-web.sh               -> LISTEN 127.0.0.1:3080
无 token 访问              -> 401
带 token 访问              -> 303（换 cookie 后进入 SPA）
首页                       -> 200，34846 字节
SPA 主包 ./assets/index-5SrrfWpU.js -> 200，633282 字节
/api/session/list          -> 200
```

自足性同时得到验证：`sha256` 与构建端一致，且解压前该镜像上不存在任何构建残留（`/dsh-uos`、`/var/tmp/dsh-node`、`/var/tmp/dsh-native-cache` 全部为安装脚本新建）。

### 3.1 旧浏览器兼容层（dsh-host-web-compat）

上面那轮验证只用了 curl，所以没有覆盖前端在旧内核上的失败。页面尾部固定执行 `(globalThis.__DSH_BOOT_READY__ ??= Promise.withResolvers()).resolve()`，内核没有 `Promise.withResolvers`（Chrome 119 才有）时这个 Promise 永不 settle，客户端插件树不启动，控制台报 `Promise.withResolvers is not a function`。设计令牌里的 `color-mix()`（Chrome 111 才有）是第二个独立故障：内核不支持时整条声明失效，而它的操作数几乎都是主题变量，构建期无法求值。

`packages/host/web-compat` 提供这两层补丁。它用 `webServer.tapIndex` 把一段 classic script 插在 `<head>` 之后——用 tap 而不是 `webserver/index-inject` 行，是因为注入行按注册顺序渲染，而行无法保证排在别的插件之前，而 head 里的 bootstrap bundle 是 parser-blocking 的，必须更早。脚本幂等且自禁用：每个 polyfill 只在缺失时安装，`color-mix` 回退只在 `CSS.supports` 报不支持时运行。挂载点是 `packages/bundle/web-app/cordis.patch.yml` 的一行 `insert`，所以安装期不需要改 profile。

验证分三层，都是在真实产物上做的：

```
JS  polyfill（Node 中先删除被测 API 再执行脚本）  -> 55/55
Host 注入（插件接口 + 位置 + 内容 + 退化路径）    -> 18/18
CSS  差分（浏览器先取引擎原生 color-mix 结果，
      再强制走回退并比对，13 个探针覆盖 var() 令牌、
      var() 链、自定义属性持有 mix、嵌套 mix、
      border 简写、半透明操作数、省略百分比、
      总和 >100% / <100% / =0）                    -> 13/13
```

CSS 那层用差分而不是断言固定色值：同一个探针先由引擎自己算一遍作为基准，再强制回退重算，两者数值相等才算通过。三个引擎行为只有这样才能发现——简写携带 `var()` 时是 pending-substitution value，长属性枚举读不到原文；计算色经过现代色彩函数后序列化为 `color(srgb …)` 而非 `rgb()`；嵌套 `color-mix` 的操作数必须先塌缩成字面量。

部署后在真实页面上确认了注入位置（包版本 0.2.0-rc.2，UOS 20 全新安装）：

```
首页                        -> 200，63430 字节
data-dsh-web-compat         -> 1 处，字节偏移 57
该脚本是文档内第一个 <script>；下一个 <script> 在偏移 28838，
parser-blocking 的 client-modules bundle 在 33284，
boot 尾脚本在 63319
页面体积增量 28584 字节 = 注入脚本大小
```

---

## 四、让 DSH Web 可被其他机器访问（可选）

`dsh web` 出于安全**默认只绑回环**，且命令行**明确拒绝** `--host 0.0.0.0`：

> `--host 0.0.0.0 is intentionally not supported yet for safety: it would expose remote code execution to the network; use 127.0.0.1 instead`

要开放需通过配置覆盖。注意两个参数位置的坑：

1. **profile 的 `cordis.patch.yml` 在部分模板下不会被自动加载**（`--dump-config` 里完全不出现 `cordis.patch` 标记）；
2. 可靠方式是 **CLI 的 `--patch`**，且：
   - `--patch` 是**启动器级**选项，必须在 `web`/`--profile` **之前**；
   - 一旦用了 `--patch`，**必须显式写 `--profile web`**，不能再用 `dsh web` 简写。

UOS 上可直接用 profile patch（实测有效）：

```yaml
# /home/<user>/.dsh/profiles/web/cordis.patch.yml
- id: webserver
  config:
    host: 0.0.0.0
    port: 3080
```

> ⚠️ 绑 `0.0.0.0` 会把本机的 DSH 能力暴露给网络。DSH 自身不带 TLS 与来源策略，仅靠启动令牌与 Host 信任栅栏保护。仅在隔离内网使用。
>
> ⚠️ 另外，**设置功能（模型提供商 / API Key）只对回环浏览器开放**。判据在客户端 `dsh-client-connection/lib/client.js`：`isLoopback: ... || isLoopbackHostname(pageLocation.hostname)`，而 `isLoopbackHostname` 只认 `localhost`、`[::1]` 与 `127.0.0.0/8`。用局域网 IP 访问会让 settings 进入 memory 模式，提供商目录报 `settings are unavailable in this browser`。需要远程访问时，用 SSH 隧道把端口映射到本机 `127.0.0.1`，而不是绑 `0.0.0.0`。

---

## 五、源码与分支

上游仓库 [`deepseek-ai/deepseek-harness`](https://github.com/deepseek-ai/deepseek-harness)（pnpm monorepo）。

Fork：`yezack/deepseek-harness`，基线 tag `dsh-v0.2.0-rc.2`（commit `639ed015`）。

| 分支 | 用途 |
|---|---|
| `master` | 与上游一致的干净基线 |
| `uos` | UOS 部署脚本与适配 |

### 构建流程（官方链路）

```sh
git clone <fork> && cd deepseek-harness
corepack prepare pnpm@11.7.0 --activate
pnpm install --frozen-lockfile
pnpm run clean                   # 清掉上一版本的增量编译缓存
pnpm run build:official          # 生成 .dsh-build 构建记录
pnpm run release:pack --family dsh       # -> dist/npm/*.tgz（318 个）
pnpm run release:pack --family vendor --out dist/npm-vendor   # -> 9 个
```

打包产物是 npm tarball；离线包里的 `app.zip` 就是把这些 tarball 连同外部依赖一起物化后的完整 `node_modules`。

---

## 六、目录结构（本仓库）

```
deploy/
├── README.md                本方案
└── uos/                     UOS 安装脚本（源码形式）
    ├── install.sh
    └── README.txt
```

> 离线包（558 MB）体积过大，不放进仓库；请按本文档的构建流程自行生成，或从已有的交付物复制。
