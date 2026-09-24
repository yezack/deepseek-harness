@echo off
setlocal
set "DEST=%~dp0"
if "%DEST:~-1%"=="\" set "DEST=%DEST:~0,-1%"

echo ============================================
echo   DeepSeek Harness - Uninstall
echo ============================================
echo   Installation: %DEST%
echo.
set /p "CONFIRM=Remove this installation? (y/N): "
if /i not "%CONFIRM%"=="y" goto :cancel

echo.
echo [1/3] Clearing the VxKex configuration for Node...
if exist "%ProgramFiles%\VxKex\KexCfg.exe" (
  if exist "%DEST%\node\node.exe" "%ProgramFiles%\VxKex\KexCfg.exe" /EXE:"%DEST%\node\node.exe" /ENABLE:FALSE >nul 2>&1
) else (
  echo   [WARN] VxKex KexCfg.exe not found - skipping.
)

echo [2/3] Removing the installation directory...
cd /d "%TEMP%"
rmdir /S /Q "%DEST%" 2>nul

echo [3/3] Done.
echo.
set /p "REMOVEKEX=Also uninstall VxKex itself? (y/N): "
if /i not "%REMOVEKEX%"=="y" goto :end
if exist "%ProgramFiles%\VxKex\KexSetup.exe" (
  echo   Uninstalling VxKex...
  "%ProgramFiles%\VxKex\KexSetup.exe" /UNINSTALL /SILENTUNATTEND >nul 2>&1
  echo   VxKex removed.
) else (
  echo   [WARN] VxKex setup not found - nothing to uninstall.
)
goto :end

:cancel
echo Cancelled.
goto :end

:end
echo.
pause
endlocal
