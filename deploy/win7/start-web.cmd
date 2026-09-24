@echo off
setlocal
set "DEST=%~dp0"
set "NODE=%DEST%node\node.exe"
set "APP=%DEST%app\node_modules\@deepseek-ai\dsh\lib\bin.js"
if not exist "%NODE%" (
  echo [ERROR] Node not found: %NODE%
  echo         Run install.cmd as Administrator first.
  pause
  exit /b 1
)
if not exist "%APP%" (
  echo [ERROR] Application not found: %APP%
  echo         Run install.cmd as Administrator first.
  pause
  exit /b 1
)
set "DSH_HOME=%DEST%home"
if not exist "%DSH_HOME%" mkdir "%DSH_HOME%"
echo ============================================
echo   DeepSeek Harness - Web service
echo ============================================
echo   Open the URL printed below in your browser.
echo   The token in the URL is required.
echo   Closing this window stops the service.
echo ============================================
echo.
"%NODE%" "%APP%" web --port 3080
echo.
echo Service stopped.
pause
endlocal
