# 本体与插件拆成两个安装单元

UOS 离线包原来把 dsh 本体和 15 个预装插件装进同一棵 `app/node_modules`，
整包升级必须重下、重装约 1.8 GB 解压体积。本方案把两者拆成**两个发布单元、
两个目录**，各自升级；本文件记录目录契约、依赖解析依据和升级流程。

## 目录

| 单元 | 安装位置 | 版本标记 | 分发包 |
|---|---|---|---|
| 本体 | `$DSH_DEST/app`（+ `node/`、脚本） | `$DSH_DEST/.installed-version` | `dsh-uos-body-<ver>.tar.gz` |
| 插件 | `$DSH_DEST/plugins/app` | `$DSH_DEST/plugins/.installed-version` | `dsh-uos-plugins-<ver>.tar.gz` |

`dsh-uos-offline.tar.gz` 是两者的整包，供新机器一次装完。用户 profile
（`~/.dsh/profiles/web`）里只保留指向插件目录的**逐包软链**，不复制包体。

构建机上两棵树分开物化：`materialize-uos.sh` 生成 `$BUILD/app`（tarball 索引）
与 `$BUILD/plugins-app`（extras 清单）。带 `override` 的 extras 条目
（chrome-devtools-mcp 的 108 fork）属于**本体树**：消费它的
`@deepseek-ai/dsh-experimental-browser-use-chrome-devtools-mcp` 在本体树里按包名解析。

## 为什么拆开后仍是单实例

dsh 的 profile 解析（`packages/boot/app-boot/src/profile-resolution/resolver.ts`）
对 profile 里链接到树外的包（linked root）执行 peer 拦截：插件自己
`package.json` 的 `peerDependencies` 命中运行时解析表（安装闭包）时，该包位置由
**正在运行的那一份**占据。15 个插件都把 `@deepseek-ai/*` 声明为 peer，因此
`cordis`、`dsh-tools`（带 `unique symbol` 的调度器）等仍是同一份实例。

拆树带来两个此前被"同一棵 node_modules"掩盖的前提，这里都做了处理：

1. **未声明 peer 却 import 了本体包的插件**。旧布局里它的祖先链上就是本体树，
   能解析到；拆开后插件树里没有 `@deepseek-ai`，会 `ERR_MODULE_NOT_FOUND`，
   表现是插件静默 `failed to import`。
   → `install-plugins.sh` 在插件树里创建
   `node_modules/@deepseek-ai -> $DSH_DEST/app/node_modules/@deepseek-ai`。
   软链指向本体的真实目录，模块缓存按 realpath 命中，不会产生第二份实例。
   → `verify-plugins.mjs` 出包前扫描插件代码里的 `@deepseek-ai/*` 导入，逐条
   要求能在本体树里找到，并在插件树里发现本体包副本时直接拒绝出包。
2. **插件目录必须在 profile 之外**才算 linked root（`profile.ts` 的
   `linkedProfileRoots`），否则 peer 拦截不生效。`$DSH_DEST/plugins` 满足。

`seed-profile.sh` 迁移逻辑：profile 里已有软链但目标不是插件目录时（旧布局指向
`$DSH_DEST/app/node_modules/<name>`）重新指向；实目录（用户自己 pnpm 装的）保持不动。

## 升级流程

- 插件：`install-plugins.sh --upgrade` 解 `plugins.zip` 到 `$DSH_DEST/.plugins-new`，
  挂 `@deepseek-ai` 软链、处理 koffi，再原子换 `$DSH_DEST/plugins`（旧的留作
  `plugins.bak`，校验 BUNDLES 齐全后删除；失败回滚），最后 `install.sh --seed-only`
  重播 profile。不碰本体。
- 本体：`install.sh --upgrade` 只替换 `$DSH_DEST/app`、`node` 与脚本，**不碰
  `$DSH_DEST/plugins`**；`seed-profile.sh` 的软链目标路径不变，无需重建。
- 桌面壳：`updater.js` 读 `latest.json` 的 `units.body` / `units.plugins`，各自比较
  `.installed-version`，只下载变化的单元。body 单元安装前把 `plugins` 暂存到
  `/var/tmp/dsh-update-plugins-keep`，装完搬回；失败回滚两者。
- 没有 `units` 的旧清单按整包处理，老客户端与新客户端都能升级。

## 版本闸门（`verify-plugins.mjs`）

出包前检查：插件版本与 `seed-profile.sh` 的 `BUNDLES` 一致、dsh 兼容判定
（`engines.dsh` 优先，否则看 `@deepseek-ai/dsh*` peer）、插件树里无本体包副本、
代码里导入的本体包都在本体树里、客户端插件入口（`dsh.client.platform` +
`exports["./client"]`）存在。

## 实测体积（UOS 20 / dsh 0.2.1-rc.2 配方）

| 项 | 体积 |
|---|---|
| 原整棵树 `node_modules` | 1828 MB（插件可达闭包 649 MB / 本体 1179 MB） |
| 拆后本体树 | 由 `materialize-uos.sh` 打印 |
| 拆后插件树 | 同上 |

插件升级包只含插件树 + 脚本，约为整包的四分之一。
