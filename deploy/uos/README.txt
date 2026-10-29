================================================================
DeepSeek Harness - UOS 离线部署（组件分发）
================================================================
dsh 0.2.1-rc.4 · Node.js 22.23.2 (linux-x64) · Electron 桌面壳
================================================================

一、这是什么
================================================================
一个**纯离线**的组件化部署介质。没有更新服务器，没有网络下载：把整个
`dsh-offline-<版本>/` 目录拷到 U 盘/共享目录，插到目标机，运行 `install.sh`
即可完成全新安装或升级。

主体三部分：
  - 本体：dsh 应用树 + Node 运行时，装在 /deepseek-harness/app、/deepseek-harness/node
  - 桌面壳：Electron 托盘 + 主窗口，装在 /var/tmp/dsh-electron
  - 插件：每个插件一棵自包含依赖树，装在 /deepseek-harness/plugins/<包名>

二、介质目录
================================================================
  install.sh          安装入口：先做介质自检（SHA256SUMS），再交给 installer
  installer.sh        统一管理：apply / status / verify / rollback / remove / seed / doctor
  manifest.json       组件清单（format 3：组件版本、sha256、policy、requires）
  SHA256SUMS          介质完整性清单（组件 + 清单 + VERSION）
  VERSION             分发版本（YYYYMMDD.HHMM）
  components/         每个组件一个 tar.gz（本体 + 每个插件各一个）

三、安装 / 升级（同一个入口）
================================================================
  # 全新安装或升级：自动判定
  sudo ./install.sh

  # 只看计划，不动磁盘
  sudo ./install.sh --dry-run

  # 非交互
  sudo ./install.sh --yes

installer 的行为（组件分发 + 事务）：
  1. 介质自检（SHA256SUMS），失败即中止；
  2. 对比本机已安装组件与清单，打印计划（安装 / 升级 / 跳过）；
  3. 获取安装锁（flock），防止桌面壳与人工同时操作；
  4. 逐个组件：升级前把旧目录挪到 <目标>.bak-<generation>，再解包新版本；
  5. 全部成功后 generation+1、保留最近两代备份；任一步失败自动按 journal
     逆序回滚，本机保持升级前的状态；
  6. 重播 profile（插件清单、默认禁用/强制启用块），并把 manifest 留存在
     /deepseek-harness/manifest.json。

常用命令：
  /deepseek-harness/installer.sh status [--json]   本机组件 vs 清单
  /deepseek-harness/installer.sh verify            目录/软链/宿主包链接自检
  /deepseek-harness/installer.sh rollback [<gen>]  回退到上一代（默认最近备份）
  /deepseek-harness/installer.sh remove <插件名>   卸载插件
  /deepseek-harness/installer.sh seed              只重播 profile
  /deepseek-harness/installer.sh doctor            调用部署自检

升级 = 换介质后重新运行 install.sh；桌面壳不提供任何升级入口，只负责界面和
守护服务进程。

四、profile 配置（自动管理）
================================================================
~/.dsh/profiles/web/cordis.patch.yml 由安装器维护三段：

  # >>> dsh-offline: default-disabled plugins   ← 默认关的插件（置顶，可被覆盖）
  # (用户区：操作员手写内容，工具只读、不删不改)
  # >>> dsh-offline: enforced plugins           ← 强制启用（置底，覆盖用户区）

要点：
  - 想启用一个默认关的插件（如 dshmarket），在用户区写
        - id: dsh-market
          disabled: false
    只写 `- id: dsh-market` 不够（不会覆盖默认禁用）。
  - 强制启用的插件（如 ga-controller）无法通过 profile 关闭；写了
    `disabled: true` 也只会得到一条提示，仍保持启用。
  - 每次安装/升级/`seed` 只重写这两个标记块内部的字节，用户区内容原样保留。

五、系统浏览器
================================================================
界面是 Electron 壳，不随包携带或升级浏览器 deb。MCP / 浏览器类插件使用系统
浏览器：安装时按下面的顺序探测，并写进 start-web.sh 的 DSH_CHROME_PATH：

  $DSH_CHROME_PATH → /usr/bin/browser（deepin）→ /usr/bin/browser360ent-cn-stable（360）
  → /usr/bin/chromium → /usr/bin/google-chrome

都找不到时安装继续，doctor 报 WARN，MCP/浏览器类插件不可用。

六、桌面壳
================================================================
  /deepseek-harness/desktop.sh                    启动壳（会自动拉起服务）
  /var/tmp/dsh-electron/app/                      壳代码
  ~/.local/share/applications/dsh-desktop.desktop 桌面入口
  ~/.dsh-desktop.log                              壳日志

托盘菜单：打开 Agent / 在浏览器打开 / 重启服务 / 当前版本 / 退出。
关闭窗口只是隐藏到托盘；退出托盘菜单会结束整个服务进程组。

七、局域网访问
================================================================
  sudo /deepseek-harness/enable-lan.sh     加 DNAT 转发（root）
非回环访问由 dsh-remote-mobile 的配对网关接管，见 start-web.sh 打印的 LAN 地址。

八、兼容运行时
================================================================
宿主 glibc 偏旧（UOS 20 为 2.28）时，univer 等插件的原生绑定通过项目级兼容
运行时加载：
  /var/tmp/dsh-glibc/                 Debian 12 的 glibc 2.36
  /var/tmp/dsh-node/bin/node-glibc    带兼容运行时的 node wrapper
doctor 第 8 项会用 node-glibc 实测 univer 两个绑定是否可加载。

九、自检与排障
================================================================
  /deepseek-harness/doctor.sh                部署自检（PASS/WARN/FAIL）
  /deepseek-harness/collect-logs.sh          一键打包诊断信息
  /deepseek-harness/installer.sh verify      组件目录/软链/宿主包链接
  journal 残留：/deepseek-harness/.state/journal（下次 apply 会自动续做/回滚）
  备份目录：/deepseek-harness/app.bak-<gen>、/deepseek-harness/plugins/<包名>.bak-<gen>

常见现象：
  doctor 出现 FAIL        → 按提示处理，或 collect-logs.sh 打包日志；
  介质校验失败            → 拷贝损坏，重新复制介质（不要跳过）；
  "另一个安装/升级进程"    → 等桌面壳/另一个终端结束，或确认无进程后重试。

十、离线环境注意事项
================================================================
  - dshmarket 的"从市场安装新插件"、部分插件的"检查更新"需要 npm registry，
    离线不可用；已预装的插件功能不受影响。
  - 本介质不包含任何更新服务器配置（update.json / latest.json 均不再使用）。

================================================================
