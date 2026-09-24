@echo off
setlocal
cd /d "%~dp0"
set "LOG=%~dp0install-log.txt"
set "SRC=%~dp0"
set "SZ=%SRC%7za.exe"
set "VXKEXCFG=%ProgramFiles%\VxKex\KexCfg.exe"
set "VXKEXSETUP=%SRC%KexSetup.exe"
set "DEFAULTDEST=C:\dsh-win7"

echo ============================================
echo   DeepSeek Harness - Windows 7 Offline Setup
echo   dsh 0.1.7-rc.1 / Node 22.23.2 / VxKex 1.2.1.2229
echo ============================================
echo.

echo === setup start %DATE% %TIME% === > "%LOG%"

if /i "%~1"=="--elevated" goto :elevated

echo   Checking administrator rights...
powershell -NoProfile -ExecutionPolicy Bypass -File "%SRC%elevate.ps1" -ScriptPath "%~f0"
set "ELRC=%ERRORLEVEL%"
if "%ELRC%"=="0" goto :elevated
if "%ELRC%"=="10" goto :relaunched
echo   [ERROR] Administrator rights are required.
echo           Right-click install.cmd and choose "Run as administrator".
echo elevation failed >> "%LOG%"
pause
exit /b 1

:relaunched
echo.
echo   An elevated window was opened - continue the setup there.
echo   This window can be closed.
echo elevation relaunched >> "%LOG%"
pause
exit /b 0

:elevated
echo elevation: OK >> "%LOG%"
echo   [OK] Running elevated.
echo.
goto :askpath

:askpath
if defined DSH_DEST goto :dest_from_env
if /i "%~1"=="--yes" goto :interactiveonly
goto :askpath_interactive

:dest_from_env
set "DEST=%DSH_DEST%"
echo DEST=%DEST% (from DSH_DEST) >> "%LOG%"
goto :go

:askpath_interactive
echo   Install location
echo     - Press ENTER to accept the default: %DEFAULTDEST%
echo     - Or type another absolute path, e.g. D:\apps\dsh
echo     - A short path without spaces is recommended
echo.
set "DEST="
set /p "DEST=  Install to [%DEFAULTDEST%]: "
if not defined DEST set "DEST=%DEFAULTDEST%"
echo.
echo   Selected: %DEST%
echo DEST=%DEST% >> "%LOG%"
echo.
echo   Press ENTER to start, or Ctrl+C to abort.
pause >nul
goto :go

:interactiveonly
if defined DSH_DEST (set "DEST=%DSH_DEST%") else (set "DEST=%DEFAULTDEST%")
echo DEST=%DEST% (non-interactive) >> "%LOG%"
goto :go

:go
if exist "%DEST%\node\node.exe" goto :node
echo [1/5] Extracting Node 22 (Windows 7 build)...
echo step1 node extract: running >> "%LOG%"
"%SZ%" x "%SRC%node.zip" "-o%DEST%\node" -y >> "%LOG%" 2>&1
if not exist "%DEST%\node\node.exe" goto :node_fail
echo step1 node extract: OK >> "%LOG%"
goto :app

:node
echo   [1/5] Node already extracted - skipped.
echo step1 node extract: skipped >> "%LOG%"
goto :app

:node_fail
echo   [ERROR] Node extraction failed. See install-log.txt
echo step1 node extract: FAILED >> "%LOG%"
pause
exit /b 1

:app
if exist "%DEST%\app\node_modules\@deepseek-ai\dsh\lib\bin.js" goto :app_skip
echo [2/5] Extracting DeepSeek Harness application (about 1.4 GB, several minutes)...
echo step2 app extract: running >> "%LOG%"
"%SZ%" x "%SRC%app.zip" "-o%DEST%\app" -y >> "%LOG%" 2>&1
if not exist "%DEST%\app\node_modules\@deepseek-ai\dsh\lib\bin.js" goto :app_fail
echo step2 app extract: OK >> "%LOG%"
goto :kex

:app_skip
echo   [2/5] Application already extracted - skipped.
echo step2 app extract: skipped >> "%LOG%"
goto :kex

:app_fail
echo   [ERROR] Application extraction failed. See install-log.txt
echo step2 app extract: FAILED >> "%LOG%"
pause
exit /b 1

:kex
if exist "%VXKEXCFG%" goto :kex_skip
echo [3/5] Installing VxKex (required for Node 22 on Windows 7)...
echo step3 vxkex install: running >> "%LOG%"
"%VXKEXSETUP%" /SILENTUNATTEND /KEXDIR:"%ProgramFiles%\VxKex" >> "%LOG%" 2>&1
if not exist "%VXKEXCFG%" goto :kex_fail
echo step3 vxkex install: OK >> "%LOG%"
goto :enable

:kex_skip
echo   [3/5] VxKex already installed - skipped.
echo step3 vxkex install: skipped >> "%LOG%"
goto :enable

:kex_fail
echo   [ERROR] VxKex installation failed (access denied usually means not elevated).
echo           Right-click install.cmd and choose "Run as administrator".
echo step3 vxkex install: FAILED >> "%LOG%"
pause
exit /b 1

:enable
echo [4/5] Enabling VxKex for Node at %DEST%\node\node.exe ...
echo step4 vxkex enable: running >> "%LOG%"
"%VXKEXCFG%" /EXE:"%DEST%\node\node.exe" /ENABLE:TRUE >> "%LOG%" 2>&1
echo step4 vxkex enable: done rc=%ERRORLEVEL% >> "%LOG%"

echo [5/5] Placing launchers and verifying...
copy /Y "%SRC%start-web.cmd" "%DEST%\start-web.cmd" >nul 2>&1
copy /Y "%SRC%uninstall.cmd" "%DEST%\uninstall.cmd" >nul 2>&1
copy /Y "%SRC%README.txt" "%DEST%\README.txt" >nul 2>&1
echo step5 launchers copied >> "%LOG%"

"%DEST%\node\node.exe" -v >> "%LOG%" 2>&1
if errorlevel 1 goto :node_run_fail
"%DEST%\node\node.exe" "%DEST%\app\node_modules\@deepseek-ai\dsh\lib\bin.js" --version >> "%LOG%" 2>&1
if errorlevel 1 goto :dsh_fail

echo [OK] Setup complete at %DEST% >> "%LOG%"
echo.
echo ============================================
echo   Setup complete
echo   Installed to : %DEST%
echo   Start web UI : %DEST%\start-web.cmd
echo   Browser      : http://127.0.0.1:3080/
echo ============================================
pause
exit /b 0

:node_run_fail
echo   [ERROR] Node cannot run - VxKex may not be active. See install-log.txt
echo [ERROR] node.exe failed >> "%LOG%"
pause
exit /b 1

:dsh_fail
echo   [ERROR] DSH cannot run. See install-log.txt
echo [ERROR] dsh failed >> "%LOG%"
pause
exit /b 1
