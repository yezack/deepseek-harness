================================================================
  DeepSeek Harness - UOS 离线安装包
================================================================
  dsh 0.2.0-rc.2  |  Node.js 22.23.2 (linux-x64)
================================================================

包内容
  install.sh     安装脚本（需 root）
  node.zip       Node.js v22.23.2 linux-x64
  app.zip        DeepSeek Harness + 全部依赖（约 1.3GB 解压后）

环境要求
  - UOS Desktop 20 (x86_64)，glibc 2.28 即可
  - root 权限（安装到 /deepseek-harness 与 /var/tmp/dsh-node）
  - 浏览器：内核低于 Chrome 119 时由内置兼容层自动补齐（见下）

安装
  tar xzf dsh-uos-offline.tar.gz
  cd package
  sudo ./install.sh
  自定义安装位置：
    sudo DSH_DEST=/opt/dsh ./install.sh

启动
  /deepseek-harness/start-web.sh
  它会在控制台打印一行带 token 的地址，例如：
    dsh web: http://127.0.0.1:3080/?token=XXXXXXXX
  用浏览器打开该完整地址（token 是鉴权凭据，必需）。
  默认只监听 127.0.0.1；关闭该窗口即停止服务。

  必须以桌面登录用户运行，不要用 sudo。安装需要 root，但启动不需要：
  Chrome 拒绝以 root 启动，root 也拿不到桌面会话的 X 授权，
  chrome-devtools MCP 会因此报 "Chrome failed to start"。

浏览器兼容层（dsh-host-web-compat）
  服务端会在每个页面的 <head> 开头注入一段脚本，它是文档里的第一个
  script，对老内核补齐以下能力，对已支持的内核什么都不做：

    Promise.withResolvers   Chrome 119
    AbortSignal.any         Chrome 116
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
  离线包已内置以下六个插件，首次启动即生效，无需联网安装：

    dsh-capability-panel            1.4.0     能力面板
    @michengai/dsh-archive-manager  1.0.15    压缩包管理
    @lemoncat7/dsh-ssh              1.11.1    SSH 连接
    dsh-remote-mobile               1.9.0     远程与移动端接入（扫码配对）
    dsh-rewind-plugin               0.15.1    会话回退
    dshmarket                       1.66.11   插件管理（启停 / 配置）

  dshmarket 的离线边界：**插件的启停、配置、profile 编辑读的是本地状态，
  可以正常用**；但它的"从市场安装新插件"和"检查更新"需要访问 npm registry，
  离线环境下会失败 —— 这不是故障，是预期行为。要装新插件请用新的离线包。

  dsh-remote-mobile 需要额外一步才能对外服务：它把 DSH 开放给手机和其他
  局域网设备，而 DSH 默认只监听 127.0.0.1。要让手机连得上，必须在
  ~/.dsh/profiles/web/cordis.patch.yml 里放开监听：

      - id: webserver
        config:
          host: 0.0.0.0
          port: 3080

  安装脚本**故意不写这条** —— 它把 DSH 的 Web 控制台（含终端与工作区能力）
  暴露给整个网络。装好插件后进"设置 -> 远程与移动端"扫码配对即可，插件自带
  访问控制、RSA 加密与防爆破锁定。仅在隔离内网使用。

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

  它们被写进 web profile 的 bundle 模板，包体在 app/node_modules 里，
  因此目标机不需要 npm registry。某个包缺失时 DSH 会跳过并记录，不会启动失败。

  chrome-devtools MCP 用的是 @yezack/chrome-devtools-mcp-108 1.10.1 —— 一份
  chrome-devtools-mcp 1.10.1 的 fork，修掉了 Chrome 108-110 上的目标发现：

    Chrome 111+ 把上游那个 filter（[{type:'page',exclude:true},{}]）理解为
    "挂 tab 目标、不挂 page 目标"；而 108-110 的 Target.TargetFilter 是早期
    白名单语义，末尾那个不带 type 的条目**不会**把前面排除掉的类型重新包含
    回来。结果是页目标一个都挂不上，browser.pages() 恒为空，所有页面工具都
    失败（list_pages 返回空数组，navigate_page 报 pageId undefined）。
    fork 在那一处调用外包一层，按 Browser.getVersion 探测主版本，<111 时
    去掉 filter，111+ 原样透传。

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
    - 浏览器默认 /usr/bin/browser（系统自带 Chromium）
    - 以临时 profile 运行，不触碰用户真实浏览器数据
    - 不使用 headless：UOS 的 deepin 浏览器 headless 必崩（trap int3），
      只能跑在桌面会话里。MCP 因此会打开一个可见窗口，
      start-web.sh 已导出 DISPLAY（默认 :0）

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
  /deepseek-harness/uninstall.sh           卸载脚本
  /var/tmp/dsh-node/              Node 运行时（白名单路径）
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
