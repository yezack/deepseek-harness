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
  离线包已内置以下三个插件，首次启动即生效，无需联网安装：

    dsh-capability-panel            1.4.0     能力面板
    @michengai/dsh-archive-manager  1.0.15    压缩包管理
    @lemoncat7/dsh-ssh              1.11.1    SSH 连接

  它们被写进 web profile 的 bundle 模板，包体在 app/node_modules 里，
  因此目标机不需要 npm registry。某个包缺失时 DSH 会跳过并记录，不会启动失败。

  chrome-devtools MCP 同样内置（chrome-devtools-mcp 1.10.1）。它不再使用
  `npx -y chrome-devtools-mcp@latest`（每次启动都要访问 registry）：
    - 服务端脚本取自安装目录
    - 浏览器默认 /usr/bin/browser（系统自带 Chromium）
    - 以 headless + 临时 profile 运行，不触碰用户真实浏览器数据

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
