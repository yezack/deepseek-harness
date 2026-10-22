================================================================
  DeepSeek Harness - UOS 离线安装包
================================================================
  dsh 0.2.1-rc.2  |  Node.js 22.23.2 (linux-x64)
================================================================

包内容
  install.sh     安装脚本（需 root）
  node.zip       Node.js v22.23.2 linux-x64
  app.zip        DeepSeek Harness + 全部依赖（约 1.3GB 解压后）
  browser/       （可选）org.deepin.browser 升级 deb，见"系统浏览器升级"
  enable-lan.sh  局域网访问脚本（root，加 DNAT 转发），见 remote-mobile 一节
  doctor.sh      部署自检（glibc/原生模块/插件版本/浏览器/端口/配置）
  collect-logs.sh 一键打包诊断信息
  maintain-profile.mjs 启动时维护 cordis.patch.yml（删孤儿行、整理标记块、YAML 预检）
  tools/pnpm-*.tgz （可选）内置 pnpm，供 plugin-manager 使用
  tools/glibc*.tar.gz （可选）项目级兼容运行时：新 glibc，供需要高版本 glibc 的插件

环境要求
  - UOS Desktop 20 (x86_64)，glibc 2.28 即可
  - root 权限（安装到 /deepseek-harness 与 /var/tmp/dsh-node）
  - 浏览器：内核低于 Chrome 119 时由内置兼容层自动补齐（见下）
  - univer（Office）的原生绑定实际需要 **glibc ≥ 2.35**（实测缺
    2.29/2.30/2.32/2.33/2.34/2.35 的符号），而 UOS 20 是 2.28。本包通过
    **兼容运行时**（见下节）让 univer 正常工作，无需升级系统。

兼容运行时（项目级，新 glibc）
  随包带一份 Debian 12 的 libc6（glibc 2.36），安装到白名单路径
  /var/tmp/dsh-glibc，并提供 wrapper：

      /var/tmp/dsh-node/bin/node-glibc
      = /var/tmp/dsh-glibc/ld-linux-x86-64.so.2 --library-path <glibc>:<node/lib> node "$@"

  宿主 DSH 仍用系统 glibc（2.28）启动，只有**显式使用 wrapper 的子进程**走新
  glibc。这样做的理由：换掉整个运行时会影响 NSS/DNS、系统库混用和调试路径；
  而需要新 glibc 的插件（univer、computer-use、speech 等）本来就是**子进程**
  （Gateway / Content Worker / MCP server），逐个切换风险可控。

  start-web.sh 自动导出两个变量：
      UNIVER_NODE_BINARY=<wrapper>   @yezack/dsh-univer-office >=0.3.8 认这个
      DSH_NODE_GLIBC=<wrapper>       通用变量，其他插件子进程可复用

  新插件遇到同类问题时：让它 spawn 时用 $DSH_NODE_GLIBC（或对应插件的
  等价变量）即可，不需要再改系统。
  doctor.sh 第 8 项会验证：loader 版本、wrapper 可运行、univer 两个绑定可加载、
  兼容运行时下 DNS 正常。

  刷新/更新这份 glibc（构建机有网时）：
      curl -O https://mirrors.aliyun.com/debian/pool/main/g/glibc/libc6_2.36-9+deb12u14_amd64.deb
      dpkg-deb -x libc6_*.deb root
      mkdir -p dsh-glibc && cp -aL root/lib/x86_64-linux-gnu/*.so* dsh-glibc/
      rm -f dsh-glibc/ld-linux-x86-64.so.2
      cp root/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 dsh-glibc/
      tar czf tools/glibc236.tar.gz dsh-glibc
  注意：Debian/Ubuntu 22.04 的 deb 用 zstd 压缩，UOS 的 dpkg-deb 1.19 解不开；
  Debian 12（xz 压缩）可以直接解。

安装
  tar xzf dsh-uos-offline.tar.gz
  cd package
  sudo ./install.sh
  自定义安装位置：
    sudo DSH_DEST=/opt/dsh ./install.sh

系统浏览器升级（可选）
  包内若带 browser/org.deepin.browser_*_amd64.deb，安装脚本会先检测系统自带
  的 org.deepin.browser：版本低于包内版本时询问是否升级（默认跳过，回答
  y 才执行 dpkg -i）。未安装该浏览器的机器不会被新装。
  当前携带的是 UOS 官方仓库的 7.4.1100.59-1，内核 Chromium 126——老版本
  6.3.9 只有 Chrome 93 内核。web-compat 兼容层（见下）已能让 93 内核正常
  工作，升级只是为了摆脱对兼容层的依赖。
  重新获取该 deb： apt-get download org.deepin.browser

构建输入清单（deploy/uos 自带的与需自取的）
  随仓库携带（保证可重建）：
    extras/yezack-chrome-devtools-mcp-108-1.10.4.tgz   MCP fork
    extras/yezack-dsh-remote-mobile-1.9.2.tgz          remote-mobile fork
    tools/pnpm-12.14.0.tgz                             内置 pnpm
  需要自己拉（体积大，未入库）：
    extras/yezack-dsh-univer-office-0.3.8.tgz   npm pack @yezack/dsh-univer-office@0.3.8   (~47MB)
    tools/glibc236.tar.gz                       按"兼容运行时"一节的命令从 Debian 12 libc6 生成 (~2MB)
  dsh 的 tarball 索引由本地 build:official → release:pack → gen-index.ps1 →
  assemble-bundle.ps1 生成（产物 _stage/dsh-tarballs.tar.gz），不随仓库提交。

启动
  /deepseek-harness/start-web.sh
  它会在控制台打印一行带 token 的地址，例如：
    dsh web: http://127.0.0.1:3080/?token=XXXXXXXX
  用浏览器打开该完整地址（token 是鉴权凭据，必需）。
  默认只监听 127.0.0.1；关闭该窗口即停止服务。

  必须以桌面登录用户运行，不要用 sudo。安装需要 root，但启动不需要：
  Chrome 拒绝以 root 启动，root 也拿不到桌面会话的 X 授权，
  chrome-devtools MCP 会因此报 "Chrome failed to start"。

  启动脚本会先跑 seed-profile.sh（幂等地维护 profile），再打印"实际驱动
  MCP/univer 的浏览器路径"——这一行是排查浏览器相关问题的第一现场。

部署自检与日志
  doctor.sh          逐项体检：glibc、原生模块 dlopen、12 个插件版本与清单是否
                     一致、系统/360 浏览器、DSH_CHROME_PATH、端口监听、DNAT
                     规则、profile 标记块与孤儿行、YAML 语法。
                     输出 [PASS]/[WARN]/[FAIL]，有 FAIL 时退出码 1。
                     用法： ./doctor.sh             # 检查 /deepseek-harness
                            ./doctor.sh /opt/dsh     # 指定安装目录
  collect-logs.sh    把 system/doctor/日志/配置打成一个 tar.gz，排查时直接发给
                     开发侧。用法： ./collect-logs.sh   → ~/dsh-logs-<时间戳>.tar.gz

  建议每次换机器或排障前先跑一次 doctor.sh，它的输出就是"当前环境是否偏离
  已知兼容基线"的证据。

升级与备份
  升级流程：停服务 → 把旧目录改名成 /deepseek-harness.bak-<时间戳> → 解压新包
            → sudo ./install.sh → 启动。
  install.sh 启动时会清理旧备份，**只保留最近 2 份** /deepseek-harness.bak-*，
  避免 / 被历史副本吃满。回滚：把当前目录改名，再把目标 .bak 改回来。

离线边界（重要）
  - dshmarket 的"从市场安装新插件/检查更新"需要 npm registry，离线不可用；
    插件启停、配置、profile 编辑读本地状态，正常工作。
  - plugin-manager 的 list/install 依赖 pnpm 与 npm。本包已修好 npm shim 并内置
    pnpm（install.sh 打印 pnpm 版本），但"真正从网上下载包"仍然需要网络。
  - 任何"下载浏览器 / 下载模型 / 访问外网"的行为都不是本包的设计目标。

浏览器兼容层（dsh-host-web-compat）
  服务端会在每个页面的 <head> 开头注入一段脚本，它是文档里的第一个
  script，对老内核补齐以下能力，对已支持的内核什么都不做：

    Promise.withResolvers   Chrome 119
    AbortSignal.any         Chrome 116
    AbortSignal.throwIfAborted / .reason   Chrome 96 / 98（缺失时网关 RPC
                            必炸，客户端无限"重新连接中"，实测于 Chrome 93）
    Array.prototype.toSorted / toReversed / toSpliced / with
    Array.fromAsync         Chrome 121
    Object.groupBy / Map.groupBy
    Set 的并/交/差等 7 个方法
    Iterator 及其 map/filter/take/drop/flatMap/toArray 等 helper
    color-mix()             Chrome 111（按 CSS Color 5 在运行时求值）

  为什么必须这么做：页面尾部固定执行
    (globalThis.__DSH_BOOT_READY__ ??= Promise.withResolvers()).resolve()
  内核没有 Promise.withResolvers 时这个 Promise 永远不 settle，客户端插件树
  不会启动，控制台报 "Promise.withResolvers is not a function"。
  设计令牌里的 color-mix() 是第二个独立故障：内核不支持时整条声明失效，
  而它的操作数几乎都是主题变量，构建期无法求值。

  兼容层是幂等的，对现代浏览器只增加约 28KB 页面体积。

预装插件与 chrome-devtools MCP
  离线包已内置以下十二个插件，无需联网安装。这份清单与参考桌面 profile 的插件集
  一致（remote-mobile 用的是自维护 fork），版本取各包在镜像上的最新发布：

    dsh-capability-panel                    1.4.2     能力面板
    @lemoncat7/dsh-ssh                      1.11.5    SSH 连接
    dsh-rewind-plugin                       0.18.0    会话回退
    dsh-dream-skin                          10.21.2   主题皮肤（默认关闭，见下）
    dsh-better-sidebar                      0.28.0    侧栏增强
    @linxin666/dsh-client-ui-git-graph      0.4.8     Git 图
    dsh-session-manager                     0.7.4     会话管理
    dsh-better-workspace                    0.35.1    工作区增强
    @yezack/dsh-univer-office               0.3.8     Office 文档（Univer，自维护 fork，见 glibc 限制）
    @yezack/dsh-temp-workspace              0.2.4     临时工作区（自维护 fork）
    @yezack/dsh-remote-mobile               1.9.2     远程与移动端接入（扫码配对，自维护 fork）
    dshmarket                               1.66.47   插件管理（启停 / 配置）

  另外随包安装一个可选的语言增强包（不是 bundle，不单独启用，只补
  dsh-better-sidebar 的可选 peer）：
    @huanlin/dsh-plugin-better-locale      0.4.3

  dsh-dream-skin 预装但**默认关闭**：它会替换整个外观，首次部署先保持 DSH 内置
  外观。关闭是通过 profile 的 cordis.patch.yml 里一段标记块实现的，由
  seed-profile.sh 维护：

      # >>> dsh-offline: default-disabled plugins
      - id: dream-skin
        disabled: true
      # <<< dsh-offline: default-disabled plugins

  要用的时候把这一段（或其中那一项）删掉再重启即可，不需要重装。该块是幂等的，
  每次启动只替换自己那一段，文件里其他内容（比如手工加的 webserver 覆盖）原样保留。

  dsh-better-workspace 的「工作区分组」默认改为**仅名称**（只按标题里的 / 分组，
  不理会磁盘目录嵌套）。该设置不在插件的 cordis Config 里（Row Config 只有
  compactChains / statusPulse / styling / appearance），保存在浏览器端持久 store
  且持久值优先，所以是构建期改客户端代码的初始默认值（patch-better-workspace.mjs，
  锚点缺失即失败，不静默跳过）。只影响从未动过这个设置的浏览器；改过的保持原样。

  注：旧版本包里的 @michengai/dsh-archive-manager 已不在清单内。profile 是持久的，
  升级安装时它会由 seed-profile.sh 从 bundles / dependencies / node_modules 三处
  一起摘掉，不需要手工清理。

  dshmarket 的离线边界：**插件的启停、配置、profile 编辑读的是本地状态，
  可以正常用**；但它的"从市场安装新插件"和"检查更新"需要访问 npm registry，
  离线环境下会失败 —— 这不是故障，是预期行为。要装新插件请用新的离线包。

  @yezack/dsh-remote-mobile 需要额外一步才能对外服务：它把 DSH 开放给手机和其他
  局域网设备，而 DSH 默认只监听 127.0.0.1。

  ⚠️ 0.2.1 起 webserver **不再接受 0.0.0.0**：通配绑定会被明确拒绝并让启动失败
    （错误：host "0.0.0.0" is an unspecified (wildcard) address），只能绑一个
    具体地址。旧部署里那条 host: 0.0.0.0 的覆盖会让升级后的 DSH 起不来 ——
    seed-profile.sh 每次启动前会自动把它改成 127.0.0.1 并打印一行提示。

  推荐做法：保持默认的 127.0.0.1，然后用包里的 enable-lan.sh（root）加转发规则，
  回环与局域网同时可用，源地址仍是真实客户端 IP，配对门禁照常工作：

      sudo /deepseek-harness/enable-lan.sh          # 默认端口 3080

  只想要局域网、不需要本机回环的，也可以把 patch 里的 host 改成机器的具体 IP：

      - id: webserver
        config:
          host: 192.168.1.50        # ← 改成这台机器自己的局域网地址
          port: 3080

  安装脚本**故意不自动执行 enable-lan.sh** —— 它把 DSH 的 Web 控制台（含终端与
  工作区能力）暴露给整个网络。装好插件后进"设置 -> 远程与移动端"扫码配对即可，
  插件自带访问控制、RSA 加密与防爆破锁定。仅在隔离内网使用。

  ⚠️ 装上这个插件后，**从局域网 IP 访问会先被插件的授权门禁拦下**，跳转到
     /auth 要求输入 6 位配对码 —— 这是插件的工作方式，不是故障。回环地址
     127.0.0.1 无条件放行，所以操作流程是：

       1. 在 UOS 本机的浏览器打开  http://127.0.0.1:3080/?token=<启动时打印的 token>
       2. 设置 -> 远程与移动端 -> 生成 6 位配对码（或设置长期访问密码）
       3. 手机 / 其他机器访问  http://<UOS 的 IP>:3080/ ，输入该配对码完成授权

     授权结果保存在 ~/.dsh/remote-mobile/devices.json，重启后仍然有效。

  这个包已经把设置页里的"Tailscale 虚拟私网接入 (推荐)"整块隐藏了：目标环境是
  隔离局域网，没有 Tailscale，留着那个入口只会误导操作员。做法是构建期改插件
  打包好的客户端代码（插件没提供隐藏开关），补丁脚本是 patch-remote-mobile.mjs，
  锚点找不到时会直接让构建失败，不会静默跳过。局域网与扫码配对部分不受影响。

  同一个补丁脚本还会纠正两处"改名重新发布"时容易漏掉的失配：

  【1】cordis.patch.yml 里 row 的 name 必须等于包名。client-modules 用 row 名做
      require.resolve('<name>/package.json')，profile 里只有新包名时旧名字解析
      不到，插件就 failed to import 并静默停用。

  【2】lib/client.js 开头是 window.__ModuleLoader__.load({ id: "<打包时的包名>" })，
      而模块表的键就是包名。两边失配时那个 id 永远拿不到 factory，浏览器里 import
      失败，WebUI 启动页会把它列进 "Failed to load plugins" —— 这一条在服务端日志里
      完全看不到，只能从浏览器 console 判断。

  1.9.2 起该 fork 自己已经修好了这两处（脚本会检测到一致并跳过，只留作兜底：万一
  以后又改包名，脚本按 package.json 的实际包名改写，锚点找不到时让构建失败）。

  该 fork 的 tarball 不在 npmmirror 上（npmjs 有），所以以 tarball 形式随包分发；
  其余插件都在镜像上，按 name@version 从 registry 物化后冻结进 app.zip。

  它们被写进 web profile 的 bundle 模板，包体在 app/node_modules 里，
  因此目标机不需要 npm registry。某个包缺失时 DSH 会跳过并记录，不会启动失败。

  chrome-devtools MCP 用的是 @yezack/chrome-devtools-mcp-108 1.10.4 —— 一份
  chrome-devtools-mcp 的 fork，三处改动：

  【1】Chrome 108-110 的目标发现

    Chrome 111+ 把上游那个 filter（[{type:'page',exclude:true},{}]）理解为
    "挂 tab 目标、不挂 page 目标"；而 108-110 的 Target.TargetFilter 是早期
    白名单语义，末尾那个不带 type 的条目**不会**把前面排除掉的类型重新包含
    回来。结果是页目标一个都挂不上，browser.pages() 恒为空，所有页面工具都
    失败（list_pages 返回空数组，navigate_page 报 pageId undefined）。
    fork 在那一处调用外包一层，按 Browser.getVersion 探测主版本，<111 时
    去掉 filter，111+ 原样透传。

  【2】浏览器 profile 默认放到临时目录（1.10.3 起）

    上游的默认 user-data-dir 是 $HOME/.cache/chrome-devtools-mcp/chrome-profile。
    /home 在加固过的机器上可能是只读挂载，那条 mkdir 会直接失败、MCP 起不来。
    1.10.3 把 isolated 的默认值改成 true，profile 建在系统临时目录并在浏览器
    关闭时清理；要回到持久 profile 得显式传 --no-isolated 或 --user-data-dir。

    本包仍然在 MCP 行里显式传 --isolated：行为不依赖包的默认值，将来换版本也
    不会因为上游改默认而变。

  【3】版本检查缓存也避开只读 home（1.10.4 起）

    版本检查原本固定写 $HOME/.cache/chrome-devtools-mcp/latest.json（20 字节），
    不受 profile 设置影响，所以只读 home 每次启动仍会吃一次写失败。1.10.4 改成
    在 $HOME/.cache/chrome-devtools-mcp 与 $TMPDIR/chrome-devtools-mcp 之间取
    第一个可写目录：正常机器沿用上游位置，只读 home 退到临时目录。
    CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS=1 可完全跳过这次检查。

  只读 /home 的实际表现已在 UOS 上验证：把 ~/.cache/chrome-devtools-mcp 设为
  555 后不带 --isolated 启动，页面工具正常，/home 下没有 chrome-profile。

  **整个安装只有这一份 chrome-devtools MCP，全部用它。** 做法是构建期用 npm
  overrides 把 fork 装到上游那个包名下：

      "overrides": { "chrome-devtools-mcp": "file:extras/…108….tgz" }

  这样 node_modules/chrome-devtools-mcp 的内容就是 fork，于是三处按包名解析的
  消费者同时拿到它：本 MCP 行、start-web.sh 导出的路径，以及 DSH 自带的
  @deepseek-ai/dsh-experimental-browser-use-chrome-devtools-mcp —— 后者用
  import.meta.resolve('chrome-devtools-mcp/...') 定位服务端，只有包名相同才
  用得上修复。结果是 15 MB 一份，没有第二份副本。

  fork 的 tarball 不在任何镜像上（npmjs 有，本构建用的 npmmirror 没有），所以
  以 tarball 形式随包分发，实体在 extras/ 目录。

  它不再使用 `npx -y chrome-devtools-mcp@latest`（每次启动都要访问 registry）：
    - 服务端脚本取自安装目录
    - 浏览器：安装时从下列候选里选第一个存在的（**固定 360 优先**）
        1. $DSH_CHROME_PATH（显式指定优先）
        2. /usr/bin/browser360ent-cn-stable   360 企业浏览器（Chrome/108.0.5359.95）
        3. /usr/bin/browser                   系统自带浏览器（版本随镜像，可能很旧）

      两个浏览器角色是分开的，不要混：
        · 跑 DSH UI 的是**系统浏览器** /usr/share/browser（/usr/bin/browser）；
          老镜像上只有 Chrome 93，由 web-compat 兼容层兜底（兼容基线是 Chrome 108，
          不假设它被升级过）。
        · DSH 使用中**拉起**的浏览器固定用 360 的 108：那是 chrome-devtools-mcp-108
          fork 明确适配的内核（108-110 目标发现修复）。即使系统浏览器被 browser/
          里的 deb 升到 126，也不改用 126 来驱动 MCP —— 那是两套路径。
    - 以临时 profile 运行，不触碰用户真实浏览器数据
    - 不使用 headless：UOS 的 deepin 浏览器 headless 必崩（trap int3），
      只能跑在桌面会话里。MCP 因此会打开一个可见窗口，
      start-web.sh 已导出 DISPLAY（默认 :0）

  ⚠️ 浏览器子进程需要一个**可写的 $HOME**，这与 profile 隔离是两件事。

     360 企业版即使收到 --user-data-dir，仍固定往 $HOME/.config/browser360ent
     写 crashpad 数据库、着色器缓存、Variations。$HOME 不可写时
     chrome_crashpad_handler 拿不到 --database（日志只有一行
     "chrome_crashpad_handler: --database is required"），浏览器的 CDP 端点起
     不来，puppeteer 最终只报 "Protocol error ... Target closed" —— 而
     --isolated 和 --user-data-dir 都救不了，因为崩的不是 Chromium profile。

     所以 MCP 行给子进程注入了 HOME：

         env:
           HOME: process.env.DSH_CHROME_HOME ?? '/var/tmp/dsh-chrome-home'

     start-web.sh 会导出 DSH_CHROME_HOME 并保证该目录存在（安装时创建，
     权限 1777）。$HOME 只读的机器靠这一条即可正常驱动浏览器，不需要动
     /home 挂载。

  可用环境变量覆盖，start-web.sh 已按实际安装目录导出：
    DSH_CHROME_PATH          浏览器可执行文件
    DSH_CHROME_DEVTOOLS_MCP  MCP 服务端脚本

  这三个 bundle 由 seed-profile.sh 在每次启动前就位。原因：Loader 是从 profile
  目录用原生 Node 解析导入 bundle 条目的（不是从安装目录），profile 下没有
  node_modules 时插件会被静默停用，只在启动日志里留一行
  "N entries did not activate"。脚本幂等，已存在的 manifest 只补 dependencies，
  不会覆盖你自己的 profile 配置。

自检：确认兼容层已注入
  U=$(grep -oE 'http://127\.0\.0\.1:3080/[^ ]*' 启动日志 | head -1)
  curl -sL "$U" | grep -c 'data-dsh-web-compat'      # 应为 1
  若为 0，说明 web-app bundle 未挂载该行，检查 app 内是否存在
  node_modules/@deepseek-ai/dsh-host-web-compat

为什么需要写到 /var/tmp
  UOS 20 有自研的 deepin-elf-verify 服务（/etc/deepin-elf-verify/whitelist），
  不在白名单目录中的可执行文件（含 .node 原生模块）会被拦截，
  表现为段错误 SIGSEGV 或 "failed to map segment from shared object"。
  白名单里唯一的用户可写目录是 /var/tmp/。因此：
    - node 二进制安装在 /var/tmp/dsh-node/
    - 原生模块缓存指向 /var/tmp/dsh-native-cache/
        （由环境变量 NARB_NATIVE_CACHE_DIR 指定，
          否则默认缓存到 /tmp 会被拦截）
  注意 /var/tmp 可能被系统清理；若 node 丢失，重新执行 sudo ./install.sh 即可。

安装后的目录
  /deepseek-harness/app                    应用与全部依赖（1.3GB）
  /deepseek-harness/start-web.sh           启动脚本
  /deepseek-harness/seed-profile.sh        预置 web profile（启动脚本调用）
  /deepseek-harness/maintain-profile.mjs   profile 维护（孤儿行/标记块/YAML 预检）
  /deepseek-harness/doctor.sh              部署自检
  /deepseek-harness/collect-logs.sh        诊断信息打包
  /deepseek-harness/uninstall.sh           卸载脚本
  /deepseek-harness/enable-lan.sh          局域网访问（DNAT 转发，需 root）
  /var/tmp/dsh-node/              Node 运行时（白名单路径，含内置 pnpm）
  /var/tmp/dsh-native-cache/      原生模块缓存（白名单路径）
  ~/.dsh/                         DSH_HOME（会话与设置）

卸载
  /deepseek-harness/uninstall.sh

已实测（UOS Desktop 20 Professional / glibc 2.28 / x86_64）
  install.sh                  -> 安装完成
  node -v                     -> v22.23.2
  dsh --version               -> 0.2.0-rc.2
  start-web.sh                -> LISTEN 127.0.0.1:3080
  无 token 访问               -> 401
  带 token 访问               -> 303（换取 cookie 后进 SPA）
  页面注入检查                -> data-dsh-web-compat 出现 1 次，
                                 且是文档内第一个 <script>（偏移 57，
                                 早于偏移 28838 的 head 注入行与
                                 偏移 33284 的 parser-blocking bundle）
================================================================
