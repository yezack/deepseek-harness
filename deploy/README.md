# DeepSeek Harness 离线部署方案

在**内网、无外网**环境下，把 DeepSeek Harness 部署到 **Windows 7** 与 **统信 UOS** 两个平台。

两个平台都做成「**解压即用**」的单一离线包，目标机不需要联网、不需要 Docker。

---

## 交付物

| 平台 | 文件 | dsh 版本 | 大小 | sha256 |
|---|---|---|---|---|
| Windows 7 (x64) | `dsh-win7-offline.zip` | 0.1.7-rc.1 | 688 MB | `23161641b36b58b12e7d045a4f0b9ab09310cd8b18eaab13a86a7493d0da0043` |
| UOS 20 (x86_64) | `dsh-uos-offline-0.2.0-rc.2.tar.gz` | 0.2.0-rc.2 | 558 MB | `e3efd7b71d3767c7e8c22066d891810d884533d9e2d1bd6079e0816cd5d036e4` |

包内统一包含：对应版本的 `dsh` + `Node.js 22.23.2` + 全部依赖树（约 1.3–1.5 GB 解压后）+ 安装/启动/卸载脚本 + 说明。

> Windows 7 包目前仍是 0.1.7-rc.1；VxKex 方案与版本无关，但需要用 0.2.0-rc.2 的源码重新走一遍打包流程才能在 Win7 上升级。

---

## 一、共同前提：为什么需要这些变通

两条硬约束决定了方案形态：

1. **Node 版本门槛**：DSH 要求 `^22.19.0 || >=24`，而两个目标机自带的 Node 都远达不到（Win7 无 Node，UOS 只有 10.24）。因此必须自带 Node 22。
2. **Node 22 面向新系统编译**：
   - Win7 上的障碍是一个**缺失的 API**（见下）。
   - UOS 上的障碍是**执行路径白名单**（见下）。

---

## 二、Windows 7

### 2.1 唯一的技术障碍

`node.exe -v` 直接崩溃，退出码 `0xC0000139`（`STATUS_ENTRYPOINT_NOT_FOUND`）。

对 `node.exe` 做 PE 导入/导出对账后，结论是**整个二进制只缺一个导出**：

```
ADVAPI32!EventSetInformation      （Windows 8 才引入，Win7 的 advapi32 里没有）
```

`KERNEL32` 的 297 个、`dbghelp` 的 13 个导入全部满足。

### 2.2 解决：VxKex

[`i486/VxKex`](https://github.com/i486/VxKex) 是 Windows 7 的 API 扩展层，其 `KxAdvapi` 恰好导出 `EventSetInformation`：

```
kxadvapi.def:  EventSetInformation = KexDll.EtwEventSetInformation
```

原理：通过 IFEO（`Image File Execution Options`）的 `VerifierDlls` 在**进程启动时**注入 `kexdll.dll`，由它把缺失 API 补齐并改写导入表。

**安装方式**（安装脚本自动执行）：

```
KexSetup.exe /SILENTUNATTEND /KEXDIR:"C:\Program Files\VxKex"
"%ProgramFiles%\VxKex\KexCfg.exe" /EXE:"<安装路径>\node\node.exe" /ENABLE:TRUE
```

> `/SILENTUNATTEND` 是从 `KexSetup/cmdline.c` 源码里查到的正确开关（`/S`、`/VERSILENT` 都不对）。

### 2.3 为什么不能把 VxKex「便携化」

实测过，结论是**做不到**，且原因是机制性的：

| 实验 | 结果 | 含义 |
|---|---|---|
| `VerifierDlls` 写**绝对路径** | `0x80000003` 被拒 | 加载器**只接受裸 DLL 名** |
| 裸名 + `kexdll.dll` 与 `node.exe` 同目录 | `0xC0000139` → `0xC0000142` | 加载**发生了**（exe 目录优先），但初始化失败 |
| 用 `VxKexLdr.exe` 便携启动器拉起 | 启动器 `rc=0`，目标进程未运行 | 无法替代安装 |

`KexDll.dll` 只依赖 `ntdll.dll`，所以不是依赖缺失 —— 是它**自检系统安装状态**后主动拒绝加载。绕开需要逐个复刻安装器写入的内部状态，属于脆弱 hack，不做。

**结论：VxKex 是系统级组件，必须安装。** 但它已被打进离线包，安装脚本自动静默安装，用户无需单独处理。

### 2.4 其他已解决的坑

| 问题 | 根因 | 解法 |
|---|---|---|
| `System.IO.Compression.FileSystem` 找不到 | 目标机是 **PowerShell 2.0**（缺 .NET 4.5+） | 打包内置 `7za.exe`（独立、无 .NET 依赖） |
| 脚本在 `[3/5]` 静默停住 | cmd 的**跨行括号块**里嵌 `pause`/`exit /b` 解析错乱 | 全部改为 `goto` 标签 |
| 中文在 cmd 里乱码/解析错位 | 批处理编码与 OEM 代码页不一致 | 所有 `.cmd` **纯 ASCII** |
| `start-web.cmd` 找不到 node/app | 用 `%~dp0` 定位，必须在安装目录内 | 安装脚本把它复制进安装目录 |
| 卸载清不掉自定义路径的配置 | `uninstall.cmd` 硬编码了默认路径 | 改为 `%~dp0` 动态定位 |
| 误报「管理权限已通过」 | 用 `fsutil dirty query` + 找 `"denied"` 判断不可靠 | 改用 `.NET WindowsPrincipal.IsInRole(Administrator)`，**未提权时自动弹 UAC 重新以管理员启动** |

### 2.5 用法

```
1. 解压 dsh-win7-offline.zip 到短路径，例如 C:\dsh
   （避免 C:\Program Files —— 空格与权限会引入问题）
2. 运行 install.cmd
   - 双击即可：脚本自检提权并自动请求 UAC
   - 也可右键「以管理员身份运行」
3. 交互中选择安装位置
   - 回车用默认 C:\dsh-win7
   - 或输入自定义绝对路径，例如 D:\apps\dsh
4. 等待（app.zip 有 35,435 个文件），结尾应看到：
     v22.23.2
     0.2.0-rc.2
   完整过程写入 install-log.txt
5. 双击 <安装路径>\start-web.cmd
   浏览器打开它打印的带 token 的 URL
```

无人值守：`set DSH_DEST=D:\apps\dsh` 后执行 `install.cmd --yes`。

**浏览器要求**：Firefox ESR 115 或 Chrome 109。IE11 打不开该前端。

**注意**：请使用启动脚本打印的 `127.0.0.1` 地址，**不要用 `localhost`** —— 该机 `localhost` 优先解析到 IPv6 `::1`，而服务默认只绑 IPv4 回环，会导致 WebSocket 连不上（页面左下角一直显示「重新连接中」）。

---

## 三、统信 UOS 20

### 3.1 核心障碍：deepin-elf-verify 执行白名单

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

> 重要澄清：这**与 glibc 无关**。官方 Node 22 要求 glibc ≥2.28，UOS 20 正好是 2.28，二进制本身完全兼容。此前所有段错误都是白名单造成的。

### 3.2 三处适配

| # | 问题 | 根因 | 解法 |
|---|---|---|---|
| 1 | Node 22 段错误 | 二进制不在白名单路径 | Node 安装到 `/var/tmp/dsh-node/` |
| 2 | 原生模块 `failed to map segment` | 加载器 `node-addon-native-custom-loader` 默认把缓存放到 **`/tmp`**（被拦） | 设 `NARB_NATIVE_CACHE_DIR=/var/tmp/dsh-native-cache`。该加载器**原生支持此环境变量**，无需改代码 |
| 3 | `koffi` 加载失败 | 它的 `.node` 位于应用目录（非白名单） | 预编译包 `@koromix/koffi-linux-x64` 放 `/var/tmp`，再从应用内 `koffi/build/koffi/linux_x64` **软链接**过去（命中 koffi 的 fallback 解析路径） |

此外，「`EACCES: mkdir .../home/profiles/web`」是因为安装脚本以 root 运行、`DSH_HOME` 落在 root 属主目录 —— 已把 `DSH_HOME` 默认改为用户可写的 `~/.dsh`。

### 3.3 构建期的坑（对重新打包有用）

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

> `--patch` 之后 `--trusted-host` 之类的应用参数位置也很关键，见第五节。

### 3.4 用法

```
tar xzf dsh-uos-offline.tar.gz
cd package
sudo ./install.sh                      # 可 DSH_DEST=/opt/dsh 自定义位置
/dsh-uos/start-web.sh                  # 普通用户运行
```

启动脚本会打印带 token 的地址，例如：

```
dsh web: http://127.0.0.1:3080/?token=XXXXXXXX
```

### 3.5 安装后的目录

```
/dsh-uos/app                   应用与全部依赖
/dsh-uos/start-web.sh          启动脚本
/dsh-uos/uninstall.sh          卸载脚本
/var/tmp/dsh-node/             Node 运行时（白名单路径）
/var/tmp/dsh-native-cache/     原生模块缓存 + koffi（白名单路径）
~/.dsh/                        DSH_HOME
```

> `/var/tmp` 可能被系统清理。若 node 丢失，重新执行 `sudo ./install.sh` 即可。

### 3.6 为什么不能打包成单文件 AppImage

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

## 四、验证结果

两个平台都在**还原后的干净虚拟机**上做过端到端验证。

**Windows 7 SP1 x64**（包版本 0.1.7-rc.1）

```
install.cmd            -> INSTALL_EXITCODE=0 / [OK] Setup complete
node.exe -v            -> v22.23.2
dsh --version          -> 0.1.7-rc.1
dsh web                -> LISTENING 127.0.0.1:3080
IFEO 校验              -> FilterFullPath=<安装路径>\node\node.exe
                          VerifierDlls=kexdll.dll  GlobalFlag=0x100
自定义路径 C:\MYDSH    -> 同样通过（FilterFullPath 自动跟随）
```

**UOS 20 Professional (x86_64, glibc 2.28)**（包版本 0.2.0-rc.2，在还原后的干净镜像上验证）

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

---

## 五、让 DSH Web 可被其他机器访问（可选）

`dsh web` 出于安全**默认只绑回环**，且命令行**明确拒绝** `--host 0.0.0.0`。

命令 `--host 0.0.0.0` 的报错原文：

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

Windows 上 CLI `--patch` 实测有效：

```bat
node "...\dsh\lib\bin.js" --profile web --patch C:\dsh-win7\hostpatch.yml --no-open --trusted-host 192.168.17.132:3080
```

`hostpatch.yml`：

```yaml
- id: webserver
  config:
    host: 0.0.0.0
    port: 3080
```

> ⚠️ 绑 `0.0.0.0` 会把本机的 DSH 能力暴露给网络。DSH 自身不带 TLS 与来源策略，仅靠启动令牌与 Host 信任栅栏保护。仅在隔离内网使用。

---

## 六、源码与分支

上游仓库 [`deepseek-ai/deepseek-harness`](https://github.com/deepseek-ai/deepseek-harness)（pnpm monorepo）。

Fork：`yezack/deepseek-harness`，基线 commit `46a7f68b`（`rel/dsh-0.2.0-rc.2`）。

| 分支 | 用途 |
|---|---|
| `master` | 与上游一致的干净基线 |
| `win7` | Windows 7 部署脚本与适配 |
| `uos` | UOS 部署脚本与适配 |

### 构建流程（官方链路）

```sh
git clone <fork> && cd deepseek-harness
corepack prepare pnpm@11.7.0 --activate
pnpm install
pnpm run build:official          # 生成 .dsh-build 构建记录
pnpm run release:pack --family dsh       # -> dist/npm/*.tgz（309 个）
pnpm run release:pack --family vendor --out dist/npm-vendor   # -> 9 个
```

打包产物是 npm tarball；离线包里的 `app.zip` 就是把这些 tarball 连同外部依赖一起物化后的完整 `node_modules`。

> 构建注意：仓库把 `pnpm` 自己也列为 devDependency，`pnpm install` 会因自我 rename 冲突报 `ERR_PNPM_EPERM`；移除该声明后可正常安装。另 `pnpm run build` 若要产出可打包的完整记录，应使用 `build:official`。

---

## 七、目录结构（本仓库）

```
deploy/
├── README.md                本方案
├── win7/                    Windows 7 安装脚本（源码形式）
│   ├── install.cmd
│   ├── start-web.cmd
│   ├── uninstall.cmd
│   ├── elevate.ps1
│   └── README.txt
└── uos/                     UOS 安装脚本（源码形式）
    ├── install.sh
    └── README.txt
```

> 离线包（688 MB / 450 MB）体积过大，不放进仓库；请按本文档的构建流程自行生成，或从已有的交付物复制。
