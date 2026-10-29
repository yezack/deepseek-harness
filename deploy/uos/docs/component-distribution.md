# 组件化离线分发的目标设计（v5）

本文是 UOS 离线部署包的**目标态设计**。当前 `deploy/uos` 里已实现的是它的前身
（`manifest.json` format 2 的组件分发）。本文定了接下来要落地的形态；实现完成前，
以本文为验收基准。

决策前提（已定）：

- **纯离线**：项目只生成离线部署介质，不设计在线安装/更新通道；没有更新服务器、
  没有 `latest.json`、没有网络下载。
- **交付形态**：一个目录 + `install.sh`（U 盘/共享目录整目录拷贝），不打包成单归档。
- **浏览器**：不再随包携带或升级浏览器 deb。界面用 Electron 壳；MCP 仍用系统浏览器，
  安装时探测、找不到只告警。
- **旧布局不保留退路**：检测到旧布局（插件混在 `$DEST/app/node_modules`）直接拒绝并
  要求用新介质重装，不提供自动迁移。
- **不拆卷**：单文件最大是 `core` 组件（约 840 MB），介质按普通文件系统准备即可。

## 1. 分发目录

```
dsh-offline-<distribution.version>/
  install.sh                 介质自检（SHA256SUMS）→ sudo ./installer.sh apply --dist .
  installer.sh               唯一入口：apply / status / verify / rollback / remove / seed / doctor
  distribution.json          format 3 组件清单（见 §3）
  SHA256SUMS                 覆盖 distribution.json 与全部组件
  VERSION                    distribution.version
  components/
    core-<ver>.tar.gz            dsh 应用树 + Node 运行时
    shell-<ver>.tar.gz           Electron 壳 + electron 运行时
    scripts-<ver>.tar.gz         installer/seed/doctor/maintain/preflight/README
    tools-<ver>.tar.gz           pnpm、glibc 兼容运行时
    <plugin>-<pkgver>.tar.gz     每个插件一个（自包含依赖树）
```

介质校验：`install.sh` 先按 `SHA256SUMS` 全量校验，失败即中止，不进入安装。

## 2. 组件约定

每个组件包内部结构一致，可单独安装：

```
package/component.json
package/install.sh
package/payload/...
```

`component.json` 字段：

| 字段 | 含义 |
|---|---|
| `name` / `kind` / `version` | 组件身份：`kind ∈ core, shell, scripts, tools, plugin` |
| `requires` | `{ dsh?: "x.y.z", core?: "<core 版本>" }`：安装期校验（dsh 比 major.minor，core 精确匹配） |
| `policy` | `{ defaultEnabled: bool, enforced: bool }`，取代旧的 `disabled`/`alwaysLast` 兼任 |
| `layerOrder` / `last` | 只影响 profile 里的层序，不影响启用策略 |

安装位置：

| kind | 位置 |
|---|---|
| `core` | `$DSH_DEST/app`（dsh + 官方依赖）+ `$DSH_DEST/node` |
| `shell` | `$DSH_DEST/desktop`（Electron 壳）+ `/var/tmp/dsh-electron` 运行时 |
| `scripts` | `$DSH_DEST/{installer.sh,seed-profile.sh,doctor.sh,…}` |
| `tools` | `$DSH_DEST/tools`、`/var/tmp/dsh-glibc` |
| `plugin` | `$DSH_DEST/plugins/<包名>`，树内 `node_modules/@deepseek-ai` 软链回 core，保证单实例 |

浏览器：安装时按 `$DSH_CHROME_PATH` → `/usr/bin/browser`（deepin）→
`/usr/bin/browser360ent-cn-stable`（360）顺序探测，写进 `start-web.sh` 的
`DSH_CHROME_PATH`；都找不到时 doctor 报 WARN，MCP 不可用，不阻塞安装。

## 3. 清单格式（`distribution.json`，format 3）

```jsonc
{
  "format": 3,                         // 清单文件：distribution.json（manifest.json 为兼容别名）
  "distribution": {
    "version": "20261029.0100",          // 单调构建版本（YYYYMMDD.HHMM）
    "dshVersion": "0.2.1-rc.4",
    "minInstalledVersion": "20261020.0000", // 低于此版本必须先装中间版本
    "lockstep": false                    // true：distribution 变则所有组件都换
  },
  "installer": { "version": "3.0.0", "minSupported": "3.0.0", "file": "installer.sh" },
  "components": [
    {
      "name": "@yezack/dsh-remote-mobile", "kind": "plugin", "version": "1.10.0",
      "requires": { "dsh": "0.2.1-rc.4", "core": "20261029.0430" },
      "policy": { "defaultEnabled": true, "enforced": false },
      "layerOrder": 130, "last": false,
      "file": "components/yezack-dsh-remote-mobile-1.10.0.tar.gz",
      "sha256": "…", "size": 187435
    }
  ],
  "aliases": { "dsh-univer-office": "@yezack/dsh-univer-office" },
  "retired": ["@michengai/dsh-archive-manager"]
}
```

- 不签名：离线场景的完整性由 `SHA256SUMS` 保证；需要防人为替换时再加签名，默认不做。
- `aliases` / `retired`：处理包改名与退役；旧目录在 apply 时清理并记 tombstone。

## 4. 安装与升级（事务）

```
apply --dist <介质目录>
  1. flock $DSH_DEST/.installer.lock          # 防并发（壳与人工同时操作）
  2. 介质校验（SHA256SUMS）+ 清单格式与 installer.minSupported 检查
  3. plan = diff(state, distribution)         # install/upgrade/replace/remove
  4. 兼容校验（`requires.dsh` 比 major.minor、`requires.core` 精确匹配）+ 磁盘预检
  5. 打印计划；--dry-run 在此返回
  6. 写 journal（txn id、plan、起始 generation）
  7. 逐组件：解到 <target>.new → rename 换入（旧目录留 .bak-<gen>）→ journal 记 done
  8. seed profile（§5 三段式）
  9. post-verify：关键文件、peer 解析、客户端模块可达、Electron 壳可启动
 10. commit：generation++ → 删 journal → 清理旧 .bak（保留 2 代）→ 清缓存
  中断/失败：按 journal 逆序回滚，state 不变；再次 apply 支持 --resume
```

旧布局检测：若发现 `$DSH_DEST/app/node_modules/<插件>` 或 profile 软链指向该路径，
installer 直接 `ERROR` 并提示用新介质重装（不做自动迁移）。

其他命令：

| 命令 | 用途 |
|---|---|
| `status [--json]` | generation、每组件已装版本、清单版本、未完成事务 |
| `verify` | 目录/软链/宿主包链接/profile 一致性自检 |
| `rollback [--to <gen>]` | 回退到上一代（或指定代） |
| `remove <插件>…` | 卸载插件并清理 profile 条目 |
| `seed` | 只重播 profile |
| `doctor` | 调用已安装的 doctor.sh |

桌面壳不提供任何升级入口：升级 = 换介质后运行 `./install.sh`（离线介质本身就是升级器），
壳只负责界面、托盘与守护服务进程。


## 5. 配置分层（profile patch 三段式）

`~/.dsh/profiles/web/cordis.patch.yml` 固定三段，工具只改标记块内字节：

```yaml
# ==== MANAGED:DEFAULT-OFF (generated) ====
- id: dsh-market
  disabled: true            # 默认关，操作员可在下面用户区覆盖
# ==== /MANAGED:DEFAULT-OFF ====

... 用户区：工具只读，绝不删除或移动 ...

# ==== MANAGED:ENFORCED (generated) ====
- id: ga-controller
  disabled: false           # enforced 组件：位于末尾，覆盖用户区
# ==== /MANAGED:ENFORCED ====
```

规则：

- `policy.defaultEnabled: false` → 只写 DEFAULT-OFF 块；用户启用后不会被下次 apply 覆盖。
- `policy.enforced: true` → 只写 ENFORCED 块；用户无法关闭，但工具不删用户的行。
- `layerOrder` / `last` → 只决定 GENERATED 块内 bundles 顺序（ga-controller 排最后）。
- 块外内容（操作员手写、历史遗留）一律保留；只提示可疑行，不自动删除。

补充（实测确认的 DSH 语义）：

- 用户区要**启用**一个默认关的插件，必须显式写 `disabled: false`；只写 `- id: x`（不带
  `disabled`）不会覆盖 DEFAULT-OFF 块，插件仍然不加载。
- `policy.enforced: true` 的插件由 ENFORCED 块（位于文件末尾）保证启用；用户在用户区
  写 `disabled: true` 不会生效，`maintain-profile.mjs` 只打印冲突提示、不删除用户行。
- `manifest.json` 已升到 format 3，每个组件带 `policy: { defaultEnabled, enforced }`，
  `component.json` 同样写入 policy；旧 `disabled` / `alwaysLast` 字段保留兼容。

## 6. 兼容性与版本策略

- 两层版本：`distribution.version`（整批）+ 组件自身 `version`（semver）。
- 组件"是否需要更新"按自身版本比较；`lockstep: true` 时改为整批替换。
- apply 前用目标 `dshVersion` 校验每个组件的 `requires.dsh`，不满足即失败并列出冲突，
  不落盘。
- 不允许降级：`distribution.version` 低于本机已装且未显式 `--allow-downgrade` 时拒绝。
- `minInstalledVersion`：跨不兼容代时要求先装中间分发版本。

## 7. 与当前实现的差异（落地清单）

| 项 | 现状（format 2） | 目标（v5） |
|---|---|---|
| 清单 | `manifest.json`，无 `policy`/`requires` | `distribution.json` format 3 |
| 本体 | 一个 body 组件（含 app/node/scripts/shell/tools） | 拆 `core`/`shell`/`scripts`/`tools` |
| 浏览器 | 携带 deb、安装时询问升级 | 不携带，只探测系统浏览器 |
| 在线更新 | `installer --server`、`latest.json`、updater 网络逻辑、强制更新窗口 | 全部删除，只保留本地介质 apply |
| 升级 | 逐组件安装，无事务 | journal + generation + 回滚 + resume + 锁 + 磁盘预检 |
| 状态 | `installed.json` + `.installed-version` + 目录三处 | `$DSH_DEST/.state/state.json` 唯一权威 |
| 配置 | seed 重写 + 维护脚本删行 | 三段式 managed 块 + 用户区只读 |
| 旧布局 | 告警 | 拒绝并提示重装 |
| 介质 | 单整包 tar.gz | 目录 + `install.sh` + `SHA256SUMS` |

## 8. 验收用例

1. 新装：空 HOME + 沙箱 DEST，`./install.sh` 后 core/shell/scripts/tools/13 插件齐全，
   服务可启动，日志无 `did not activate`。
2. 只升插件：仅替换目标插件组件，其余组件目录 mtime 不变。
3. 只升 core：插件树保留，`@deepseek-ai` 软链重建，profile 软链仍有效。
4. 强制启用：profile 写 `- id: ga-controller / disabled: true`，apply 后 ENFORCED 块覆盖，
   插件仍加载。
5. 默认关可覆盖：操作员启用 dshmarket 后再 apply，不被改回 disabled。
6. 中断恢复：apply 中途 kill，再次执行可 resume 或回滚到原 generation。
7. 回滚：`rollback --to <gen>` 后版本与功能恢复。
8. 介质自检：篡改任一组件字节，`./install.sh` 拒绝执行。
9. 无网络：断网全流程不受影响（无外部连接）。
10. 浏览器：只有 deepin 浏览器时 MCP 可用；都无时 doctor 报 WARN。

## 9. 已废弃文档

- `docs/unit-split.md`：两单元（body + plugins）方案，已被本文取代。
- `docs/test-unit-split.sh`、`docs/test-upgrade-units.sh`：针对旧两单元布局，待替换为
  `test-components.sh`。

## 10. 实现进度

| 阶段 | 内容 | 状态 |
|---|---|---|
| P0 | install.sh 介质自检（SHA256SUMS）+ installer apply/--dry-run + flock + 磁盘/误装防护 | 已完成 |
| P1a | generation + journal + 备份/回滚 + resume + ollback 命令 | 已完成 |
| P1b | policy 字段 + 两段式 managed 块（DEFAULT-OFF 置顶、ENFORCED 置底、用户区只读） | 已完成 |
| P1c | 纯离线：删 --server/curl；桌面壳删 updater/preload/forced/progress 与"检查更新" | 已完成 |
| P2 | body 拆成 core(order 0) / 	ools(1) / scripts(2) / shell(3)；scripts 版本取脚本内容哈希，只有脚本变化才重装；installer 以 installed.json 为权威状态并清理清单外条目 | 已完成 |
| P3 | equires（body↔插件兼容矩阵）、清单文件改名 distribution.json | 待做 |

组件版本约定：
  - core / 	ools / shell = 分发版本（重建即刷新，下载主体仍是大头）；
  - scripts = 脚本内容哈希（前 12 位）——只改脚本时不重下本体；
  - 插件 = 包自身 semver。
