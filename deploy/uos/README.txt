================================================================
  DeepSeek Harness - UOS 离线安装包
================================================================
  dsh 0.1.7-rc.1  |  Node.js 22.23.2 (linux-x64)
================================================================

包内容
  install.sh     安装脚本（需 root）
  node.zip       Node.js v22.23.2 linux-x64
  app.zip        DeepSeek Harness + 全部依赖（约 1.3GB 解压后）

环境要求
  - UOS Desktop 20 (x86_64)，glibc 2.28 即可
  - root 权限（安装到 /dsh-uos 与 /var/tmp/dsh-node）
  - 浏览器：现代 Chromium/Firefox 内核

安装
  tar xzf dsh-uos-offline.tar.gz
  cd dsh-uos-offline
  sudo ./install.sh
  自定义安装位置：
    sudo DSH_DEST=/opt/dsh ./install.sh

启动
  /dsh-uos/start-web.sh
  它会在控制台打印一行带 token 的地址，例如：
    dsh web: http://127.0.0.1:3080/?token=XXXXXXXX
  用浏览器打开该完整地址（token 是鉴权凭据，必需）。
  默认只监听 127.0.0.1；关闭该窗口即停止服务。

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
  /dsh-uos/app                    应用与全部依赖（1.3GB）
  /dsh-uos/start-web.sh           启动脚本
  /dsh-uos/uninstall.sh           卸载脚本
  /var/tmp/dsh-node/              Node 运行时（白名单路径）
  /var/tmp/dsh-native-cache/      原生模块缓存（白名单路径）
  ~/.dsh/                         DSH_HOME（会话与设置）

卸载
  /dsh-uos/uninstall.sh

已实测（UOS Desktop 20 Professional / glibc 2.28 / x86_64）
  install.sh                  -> 安装完成
  node -v                     -> v22.23.2
  dsh --version               -> 0.1.7-rc.1
  start-web.sh                -> LISTEN 127.0.0.1:3080
  无 token 访问               -> 401
  带 token 访问               -> 303（换取 cookie 后进 SPA）
================================================================
