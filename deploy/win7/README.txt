================================================================
  DeepSeek Harness - Windows 7 Offline Installer
================================================================
  dsh 0.1.7-rc.1  |  Node 22.23.2 (Win7 build)  |  VxKex 1.2.1.2229
================================================================

CONTENTS
  install.cmd    installer
  elevate.ps1    elevation helper used by install.cmd
  start-web.cmd  start the web UI after install
  uninstall.cmd  remove the installation
  7za.exe        7-Zip command line (used for extraction)
  KexSetup.exe   VxKex (required for Node 22 on Windows 7)
  node.zip       Node.js v22.23.2, Windows 7 build
  app.zip        DeepSeek Harness + all dependencies

REQUIREMENTS
  - Windows 7 SP1 (x64)
  - Administrator rights
  - A modern browser: Firefox ESR 115 or Chrome 109 recommended.
    The built-in IE11 cannot render the web UI.

INSTALL
  1. Extract this whole folder to a short path, for example C:\dsh
     (avoid C:\Program Files - its spaces and permissions cause trouble)
  2. Run install.cmd.
     - Normally just double-click it: the installer checks whether it is
       elevated, and asks Windows for elevation itself (a UAC prompt
       appears). Approve it and setup continues in the elevated window.
     - If you prefer, right-click install.cmd and choose
       "Run as administrator" - that works too.
  3. The installer asks where to install:
       - Press ENTER for the default: C:\dsh-win7
       - Or type your own absolute path, e.g. D:\apps\dsh
     A short path without spaces is recommended. VxKex is configured
     for the Node binary at whichever path you choose.
  4. Wait several minutes. app.zip holds 35,435 files.
     Re-running is safe: already-extracted steps are skipped.
  5. Success looks like this at the end:
       v22.23.2
       0.1.7-rc.1
  Full detail goes to install-log.txt next to install.cmd.

UNATTENDED INSTALL (optional)
  For scripted deployment, run install.cmd --yes with DSH_DEST set:
    set DSH_DEST=D:\apps\dsh
    install.cmd --yes
  This skips both prompts. Elevation is still requested if needed.

START THE WEB UI
  Double-click start-web.cmd - it lives inside your install directory
  (for example C:\dsh-win7\start-web.cmd).
  It prints a line like:
    dsh web: http://127.0.0.1:3080/?token=XXXXXXXX
  Open that exact URL (the token is required for authentication).
  The service listens on 127.0.0.1 only; closing the window stops it.

WHAT GETS INSTALLED
  <your path>\            application + node runtime + launchers
  <your path>\home\       DSH_HOME (sessions, settings)
  C:\Program Files\VxKex\ VxKex runtime
  C:\Windows\System32\kexdll.dll  (required by VxKex)

WHY VxKex IS REQUIRED
  Node.js 22 imports ADVAPI32!EventSetInformation, an API introduced
  in Windows 8 that does not exist on Windows 7. Without VxKex,
  node.exe fails immediately with 0xC0000139
  (STATUS_ENTRYPOINT_NOT_FOUND). VxKex supplies the missing API at
  process startup, so it is a hard requirement, not optional.
  Installing VxKex needs elevation; an "access denied" error at that
  step means the installer was not running as Administrator.

UNINSTALL
  Run uninstall.cmd from inside your install directory, as Administrator.
  It clears the Node VxKex configuration, removes the install directory,
  and optionally uninstalls VxKex itself when you answer "y".

VERIFIED ON A CLEAN WINDOWS 7 SP1 x64 VM
  default path C:\dsh-win7   -> [OK] Setup complete
  custom path  C:\MYDSH      -> [OK] Setup complete
  node.exe -v                -> v22.23.2
  dsh --version              -> 0.1.7-rc.1
  dsh web                    -> LISTENING on 127.0.0.1:3080
================================================================
